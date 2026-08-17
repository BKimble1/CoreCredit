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
/// - a configured error is thrown from both entry points;
/// - an empty line fixture throws `RecognitionError.noTextFound`, exactly as an unreadable photo
///   would;
/// - an empty barcode fixture returns an empty array, because "no barcode in this photo" is a
///   normal outcome rather than a failure.
///
/// The image data is ignored entirely — callers may pass
/// `ImageProcessor.placeholderJPEGData(width:height:hue:)` or even empty `Data`.
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

    /// Symbology reported for every stubbed barcode. Matches Vision's raw value for a QR code, so
    /// UI that switches on symbology behaves the same in tests as on device.
    private static let stubSymbology = "VNBarcodeSymbologyQR"

    init(lines: [String] = [], barcodes: [String] = [], error: (any Error)? = nil) {
        self.lines = lines
        self.barcodes = barcodes
        self.failure = ErrorBox(error: error)
    }

    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine] {
        if let error = failure.error { throw error }
        let recognized = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { RecognizedLine(text: $0, confidence: 1.0) }
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
}
