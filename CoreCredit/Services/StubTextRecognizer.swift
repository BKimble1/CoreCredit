//
//  StubTextRecognizer.swift
//  CoreCredit
//
//  Capture layer — the deterministic recogniser used by previews, unit tests, and UI tests.
//
//  This is what makes the whole capture flow demoable with no camera and no fixture images:
//  the caller supplies exactly the lines and codes it wants "recognised", and the failure path
//  is reproduced by handing in an error.
//

import Foundation

/// A `TextRecognizing` that returns caller-supplied fixtures instead of touching Vision.
///
/// Behaviour mirrors `VisionTextRecognizer` so a test that passes here means something:
/// - a configured error is thrown from every entry point;
/// - an empty line fixture throws `RecognitionError.noTextFound`, exactly as an unreadable photo
///   would;
/// - an empty barcode fixture returns an empty array, because "no barcode in this photo" is a
///   normal outcome rather than a failure.
///
/// The image data is ignored entirely — callers may pass
/// `ImageProcessor.placeholderJPEGData(width:height:hue:)` or even empty `Data`.
///
/// ## Optional geometry, alternatives, and pages
///
/// Everything past `error` is optional and defaults to "the recogniser reported none of this", so
/// the original `init(lines:barcodes:error:)` still means exactly what it always meant. A test that
/// needs richer input supplies it positionally:
///
/// - `boundingBoxes` and `alternatives` are **parallel to `lines`** and are matched by the index of
///   the line in the array the caller passed, *before* blanks are dropped. That way inserting a
///   fixture line does not silently re-key the geometry of the ones after it.
/// - `pageLines` drives `recognizePages(_:)`: one inner array per page, each line stamped with its
///   page index. When it is empty the stub falls back to repeating `lines` for every page of data
///   it was handed, which is exactly what the protocol's default implementation would have done.
final class StubTextRecognizer: TextRecognizing {

    /// Boxes the caller's error so this class can vouch for its own thread safety: the value is
    /// written once at initialisation and only ever read afterwards, but an arbitrary `any Error`
    /// carries no `Sendable` guarantee of its own.
    private struct ErrorBox: @unchecked Sendable {
        let error: (any Error)?
    }

    private let lines: [String]
    private let barcodes: [String]
    private let failure: ErrorBox
    private let boundingBoxes: [ScanBoundingBox?]
    private let alternatives: [[String]]
    private let pageLines: [[String]]

    /// Symbology reported for every stubbed barcode. Matches Vision's raw value for a QR code, so
    /// UI that switches on symbology behaves the same in tests as on device.
    private static let stubSymbology = "VNBarcodeSymbologyQR"

    /// Confidence reported for every stubbed line. Deliberately certain: a stub is not modelling
    /// bad light, it is modelling "these are the words on the page".
    private static let stubConfidence = 1.0

    init(lines: [String] = [],
         barcodes: [String] = [],
         error: (any Error)? = nil,
         boundingBoxes: [ScanBoundingBox?] = [],
         alternatives: [[String]] = [],
         pageLines: [[String]] = []) {
        self.lines = lines
        self.barcodes = barcodes
        self.failure = ErrorBox(error: error)
        self.boundingBoxes = boundingBoxes
        self.alternatives = alternatives
        self.pageLines = pageLines
    }

    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine] {
        if let error = failure.error { throw error }
        let recognized = StubTextRecognizer.recognizedLines(from: lines,
                                                            boundingBoxes: boundingBoxes,
                                                            alternatives: alternatives,
                                                            page: 0)
        guard !recognized.isEmpty else { throw RecognitionError.noTextFound }
        return recognized
    }

    func recognizeBarcodes(in imageData: Data) async throws -> [ScanResult] {
        if let error = failure.error { throw error }
        return barcodes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ScanResult(payload: $0, symbology: StubTextRecognizer.stubSymbology) }
    }

    /// Multi-page fixtures, page-stamped.
    ///
    /// With `pageLines` configured the supplied pages of image data are ignored, exactly as a single
    /// image's bytes are: the fixture *is* the document. Without it, each page of data yields the
    /// `lines` fixture stamped with that page's index, so a two-page scan still exercises the
    /// page-stamping path with no extra setup.
    func recognizePages(_ pages: [Data]) async throws -> [RecognizedLine] {
        if let error = failure.error { throw error }

        var results: [RecognizedLine] = []
        if pageLines.isEmpty {
            for index in pages.indices {
                results.append(contentsOf: StubTextRecognizer.recognizedLines(from: lines,
                                                                              boundingBoxes: boundingBoxes,
                                                                              alternatives: alternatives,
                                                                              page: index))
            }
        } else {
            for (index, page) in pageLines.enumerated() {
                results.append(contentsOf: StubTextRecognizer.recognizedLines(from: page,
                                                                              boundingBoxes: [],
                                                                              alternatives: [],
                                                                              page: index))
            }
        }

        guard !results.isEmpty else { throw RecognitionError.noTextFound }
        return results
    }

    // MARK: - Private

    /// Turns one page of fixture strings into recognised lines.
    ///
    /// Blank strings are dropped — an empty line is not a recognition — but the *original* index is
    /// what looks up the parallel geometry and alternatives, so dropping one does not shift the
    /// others. Every lookup is bounds-checked, so a short parallel array simply means "no geometry
    /// for the rest".
    private static func recognizedLines(from texts: [String],
                                        boundingBoxes: [ScanBoundingBox?],
                                        alternatives: [[String]],
                                        page: Int) -> [RecognizedLine] {
        var results: [RecognizedLine] = []

        for (index, rawText) in texts.enumerated() {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let box = boundingBoxes.indices.contains(index) ? boundingBoxes[index] : nil
            let variants = alternatives.indices.contains(index) ? alternatives[index] : []

            results.append(RecognizedLine(text: text,
                                          confidence: stubConfidence,
                                          boundingBox: box,
                                          alternatives: variants,
                                          page: page))
        }

        return results
    }
}
