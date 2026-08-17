//
//  VisionTextRecognizer.swift
//  CoreCredit
//
//  Capture layer — the real OCR implementation, built on the classic Vision request API.
//
//  Reminder for future maintainers: **this is a suggestion engine.** Its output goes to
//  `OCRSuggestionExtractor` and from there into editable confirmation fields. Nothing recognised
//  here is ever written to a `CoreItem` without a human confirming it.
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads text and barcodes out of still image data using Vision.
///
/// All recognition runs on a detached task: a full-page invoice at 2000 px takes hundreds of
/// milliseconds, and the main actor is driving a camera preview and a form at the time.
final class VisionTextRecognizer: TextRecognizing {

    init() {}

    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine] {
        let task = Task.detached(priority: .userInitiated) {
            try VisionTextRecognizer.recognizeLinesSynchronously(in: imageData)
        }
        return try await task.value
    }

    func recognizeBarcodes(in imageData: Data) async throws -> [ScanResult] {
        let task = Task.detached(priority: .userInitiated) {
            try VisionTextRecognizer.recognizeBarcodesSynchronously(in: imageData)
        }
        return try await task.value
    }

    /// Multi-page recognition for a document scan, with every line stamped with its page index.
    ///
    /// The whole document is recognised inside **one** detached task rather than one task per page:
    /// pages are processed in order, so a five-page invoice never has five full-size decodes alive
    /// at once, and the returned order is reproducible.
    func recognizePages(_ pages: [Data]) async throws -> [RecognizedLine] {
        guard !pages.isEmpty else { throw RecognitionError.noTextFound }

        let task = Task.detached(priority: .userInitiated) {
            try VisionTextRecognizer.recognizePagesSynchronously(pages)
        }
        return try await task.value
    }

    // MARK: - Recognition (off the main actor)

    /// Text recognition proper. Runs synchronously; only ever called from a detached task.
    ///
    /// `usesLanguageCorrection` is **off** on purpose: part numbers (`03-1887`), invoice refs
    /// (`INV-55219`), and repair-order numbers are not words, and the language model happily
    /// "corrects" them into something plausible and wrong. `revision` is left at the framework
    /// default so the app follows the OS rather than pinning to a model that may be withdrawn.
    ///
    /// Three candidates are requested instead of one. The winner becomes `text`, exactly as before;
    /// the runners-up become `alternatives`, which the review sheet offers as tappable chips. This
    /// is the *opposite* of language correction: nothing is substituted behind the user's back, the
    /// second reading of `SO5` is simply there to be tapped when the first one is wrong.
    private static func recognizeLinesSynchronously(in imageData: Data) throws -> [RecognizedLine] {
        try validateImageData(imageData)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.recognitionFailed(error.localizedDescription)
        }

        // Typed as `[Any]` so this compiles against both the generic and the untyped spelling of
        // `VNRequest.results`, and so the pattern match below stays the single place that decides
        // which observations matter.
        let observations: [Any] = request.results ?? []
        var lines: [RecognizedLine] = []

        for case let observation as VNRecognizedTextObservation in observations {
            let candidates = observation.topCandidates(maximumCandidateCount)
            guard let winner = candidates.first else { continue }
            let text = winner.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            lines.append(RecognizedLine(text: text,
                                        confidence: Double(winner.confidence),
                                        boundingBox: normalizedBox(from: observation.boundingBox),
                                        alternatives: alternatives(from: candidates, winner: text)))
        }

        guard !lines.isEmpty else { throw RecognitionError.noTextFound }
        return lines
    }

    /// Every page of a document scan, in capture order, each line stamped with its page index.
    ///
    /// A page Vision finds nothing on is skipped rather than fatal: the back of an invoice is often
    /// blank, and losing the four pages that *did* read because of it would be absurd. A page whose
    /// bytes cannot be decoded at all still throws, because that means the caller handed over
    /// something broken. Runs synchronously; only ever called from a detached task.
    private static func recognizePagesSynchronously(_ pages: [Data]) throws -> [RecognizedLine] {
        var results: [RecognizedLine] = []

        for (index, pageData) in pages.enumerated() {
            let lines: [RecognizedLine]
            do {
                lines = try recognizeLinesSynchronously(in: pageData)
            } catch RecognitionError.noTextFound {
                continue
            }
            for line in lines {
                results.append(RecognizedLine(id: line.id,
                                              text: line.text,
                                              confidence: line.confidence,
                                              boundingBox: line.boundingBox,
                                              alternatives: line.alternatives,
                                              page: index))
            }
        }

        guard !results.isEmpty else { throw RecognitionError.noTextFound }
        return results
    }

    /// How many readings of each line to ask Vision for: the winner plus two runners-up.
    private static let maximumCandidateCount = 3

    /// The runners-up, cleaned and deduplicated, strongest first.
    ///
    /// A candidate that trims to nothing, or that equals the winning text, carries no information
    /// and is dropped — offering the user a chip identical to the value already in the field would
    /// just be noise.
    private static func alternatives(from candidates: [VNRecognizedText],
                                     winner: String) -> [String] {
        var results: [String] = []
        for candidate in candidates.dropFirst() {
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != winner, !results.contains(text) else { continue }
            results.append(text)
        }
        return results
    }

    /// Copies Vision's normalised rectangle across unchanged.
    ///
    /// Vision reports a 0…1 rectangle with a **bottom-left** origin and `ScanBoundingBox` is
    /// documented to store exactly that, so there is no flipping here — flipping, if any, belongs
    /// to the view that draws it. A null, infinite, or non-finite rectangle becomes `nil` rather
    /// than a set of coordinates the ranking layer would then have to defend itself against.
    private static func normalizedBox(from rect: CGRect) -> ScanBoundingBox? {
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let x = Double(rect.origin.x)
        let y = Double(rect.origin.y)
        let width = Double(rect.size.width)
        let height = Double(rect.size.height)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        return ScanBoundingBox(x: x, y: y, width: width, height: height)
    }

    /// Barcode detection on a still image — the fallback path when live scanning is unavailable
    /// (simulator, denied camera, or a photo the tech already took).
    ///
    /// An image with no codes in it returns an empty array. That is not an error: most invoice
    /// photos have no barcode, and the caller simply carries on with the text suggestions.
    private static func recognizeBarcodesSynchronously(in imageData: Data) throws -> [ScanResult] {
        try validateImageData(imageData)

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.recognitionFailed(error.localizedDescription)
        }

        let observations: [Any] = request.results ?? []
        var results: [ScanResult] = []
        var seenPayloads: Set<String> = []

        for case let observation as VNBarcodeObservation in observations {
            guard let payload = observation.payloadStringValue else { continue }
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seenPayloads.insert(trimmed).inserted else { continue }
            results.append(ScanResult(payload: trimmed, symbology: observation.symbology.rawValue))
        }

        return results
    }

    // MARK: - Input validation

    /// Rejects data that is not a decodable image before Vision is handed it.
    ///
    /// `VNImageRequestHandler(data:options:)` cannot fail at construction time — it happily
    /// accepts junk and then reports an opaque error when performed. Checking with ImageIO first
    /// lets the UI say "that photo couldn't be read" instead of "Vision error 5".
    private static func validateImageData(_ imageData: Data) throws {
        guard !imageData.isEmpty else { throw RecognitionError.invalidImage }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw RecognitionError.invalidImage
        }
        guard CGImageSourceGetCount(source) > 0 else { throw RecognitionError.invalidImage }
    }
}
