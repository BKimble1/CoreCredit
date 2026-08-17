//
//  TextRecognizing.swift
//  CoreCredit
//
//  Capture layer — the vocabulary shared by the OCR pipeline.
//
//  **Vision is only ever a suggestion engine in this app.** Nothing produced here is written to a
//  record. Recognised lines become `OCRFieldSuggestion` values, the UI puts those into editable
//  confirmation fields, and only a human tap commits anything. A misread invoice must never turn
//  into a wrong number in a shop's ledger.
//

import Foundation

/// One line of text recognised in an image.
///
/// Equality intentionally ignores `id` — the identifier exists so SwiftUI can list lines, while
/// two lines with the same text and confidence are the same recognition for comparison purposes.
struct RecognizedLine: Equatable, Sendable, Identifiable {

    /// Per-instance identity for SwiftUI. Not part of equality.
    var id: UUID

    /// The recognised text, trimmed of surrounding whitespace but otherwise untouched.
    var text: String

    /// Vision's confidence for the winning candidate, 0…1.
    var confidence: Double

    init(id: UUID = UUID(), text: String, confidence: Double) {
        self.id = id
        self.text = text
        self.confidence = confidence
    }

    static func == (lhs: RecognizedLine, rhs: RecognizedLine) -> Bool {
        lhs.text == rhs.text && lhs.confidence == rhs.confidence
    }
}

/// A field the OCR layer knows how to guess at.
///
/// Kept separate from `CoreItemField` because OCR only ever guesses at this subset; `coreItemField`
/// maps a suggestion onto the editor control that should receive it.
enum OCRField: String, CaseIterable, Sendable, Identifiable {
    case partNumber
    case invoiceReference
    case repairOrderReference
    case amount
    case vendorName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .partNumber: return "Part number"
        case .invoiceReference: return "Invoice"
        case .repairOrderReference: return "Repair order"
        case .amount: return "Core charge"
        case .vendorName: return "Vendor"
        }
    }

    /// The editor field a confirmed suggestion is written into.
    var coreItemField: CoreItemField {
        switch self {
        case .partNumber: return .partNumber
        case .invoiceReference: return .invoiceReference
        case .repairOrderReference: return .repairOrderReference
        case .amount: return .expectedCredit
        case .vendorName: return .vendor
        }
    }
}

/// A single guess for a single field, shown to the user as a pre-filled but editable value.
///
/// `confidence` is the extractor's own 0…1 score for how strong the textual evidence was — it is
/// **not** Vision's character confidence. The UI uses it only to order and de-emphasise guesses;
/// a low score never hides a suggestion and a high score never auto-applies one.
///
/// Equality ignores `id` so unit tests can compare expected suggestions literally.
struct OCRFieldSuggestion: Equatable, Sendable, Identifiable {

    /// Per-instance identity for SwiftUI. Not part of equality.
    var id: UUID

    var field: OCRField

    /// The suggested text, ready to drop into the editor field unchanged.
    var value: String

    /// How strong the match was, 0…1, clamped on construction.
    var confidence: Double

    init(field: OCRField, value: String, confidence: Double) {
        self.id = UUID()
        self.field = field
        self.value = value
        self.confidence = OCRFieldSuggestion.clamped(confidence)
    }

    static func == (lhs: OCRFieldSuggestion, rhs: OCRFieldSuggestion) -> Bool {
        lhs.field == rhs.field && lhs.value == rhs.value && lhs.confidence == rhs.confidence
    }

    /// Keeps confidence inside 0…1 even if a caller (or a future heuristic) overshoots.
    /// A non-finite value collapses to 0 rather than propagating a NaN into the UI.
    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Reads text and codes out of a still image.
///
/// Abstracted so the app can run — and be tested — with no camera and no Vision framework work:
/// `StubTextRecognizer` returns fixtures, `VisionTextRecognizer` does the real thing.
protocol TextRecognizing: Sendable {

    /// Recognised text lines, in Vision's reading order.
    /// Throws `RecognitionError.noTextFound` when the image contains no readable text.
    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine]

    /// Barcodes found in a still image. Returns an empty array when the image simply has no
    /// codes in it — that is a normal outcome for a photo of an invoice, not an error.
    func recognizeBarcodes(in imageData: Data) async throws -> [ScanResult]
}

/// Everything that can go wrong while reading an image, as a presentable state.
enum RecognitionError: LocalizedError, Equatable {

    /// The data is empty, truncated, or not an image format the system can decode.
    case invalidImage

    /// Vision reported a failure; the payload is the underlying description, for the log and the
    /// error banner's detail line.
    case recognitionFailed(String)

    /// The image decoded fine but nothing readable was in it.
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That photo couldn't be read. Take another one, or type the details in."
        case .recognitionFailed(let detail):
            return detail.isEmpty
                ? "Reading the photo didn't work. Type the details in instead."
                : "Reading the photo didn't work: \(detail)"
        case .noTextFound:
            return "No text was found in that photo. Try again in better light, or type the details in."
        }
    }
}
