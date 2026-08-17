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

    // MARK: - Recognition (off the main actor)

    /// Text recognition proper. Runs synchronously; only ever called from a detached task.
    ///
    /// `usesLanguageCorrection` is **off** on purpose: part numbers (`03-1887`), invoice refs
    /// (`INV-55219`), and repair-order numbers are not words, and the language model happily
    /// "corrects" them into something plausible and wrong. `revision` is left at the framework
    /// default so the app follows the OS rather than pinning to a model that may be withdrawn.
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
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(RecognizedLine(text: text, confidence: Double(candidate.confidence)))
        }

        guard !lines.isEmpty else { throw RecognitionError.noTextFound }
        return lines
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
