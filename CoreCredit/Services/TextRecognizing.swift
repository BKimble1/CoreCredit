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
/// Equality intentionally ignores `id` — the identifier exists so SwiftUI can list lines — and
/// compares everything else, which is the same rule `ScanCandidate`, `ScanResult` and
/// `OCRFieldSuggestion` follow. Two lines read off different pages, or in different places on the
/// page, are not the same recognition.
///
/// `boundingBox`, `alternatives` and `page` are **defaulted** so every call site that predates them
/// still compiles unchanged: a recogniser that knows nothing about geometry keeps returning
/// `RecognizedLine(text:confidence:)`.
struct RecognizedLine: Equatable, Sendable, Identifiable {

    /// Per-instance identity for SwiftUI. Not part of equality.
    var id: UUID

    /// The recognised text, trimmed of surrounding whitespace but otherwise untouched.
    var text: String

    /// Vision's confidence for the winning candidate, 0…1.
    var confidence: Double

    /// Where the line sits in the image, in Vision's normalised bottom-left space. `nil` when the
    /// recogniser did not report geometry — a stub fixture, or a caller that never needed it.
    ///
    /// The ranking layer uses it to prefer a value printed next to its label over an equally-scored
    /// value from somewhere else on the page.
    var boundingBox: ScanBoundingBox?

    /// Lower-ranked readings of the *same* line, strongest first.
    ///
    /// These exist so a misread can be corrected by tapping instead of retyping. They are offered,
    /// never substituted: `text` is always the winning candidate, and nothing in this app quietly
    /// swaps an alternative in.
    var alternatives: [String]

    /// Zero-based page index for a multi-page document scan. Single-image recognition leaves it 0.
    var page: Int

    init(id: UUID = UUID(),
         text: String,
         confidence: Double,
         boundingBox: ScanBoundingBox? = nil,
         alternatives: [String] = [],
         page: Int = 0) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.alternatives = alternatives
        self.page = page
    }

    static func == (lhs: RecognizedLine, rhs: RecognizedLine) -> Bool {
        lhs.text == rhs.text
            && lhs.confidence == rhs.confidence
            && lhs.boundingBox == rhs.boundingBox
            && lhs.alternatives == rhs.alternatives
            && lhs.page == rhs.page
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

    /// Recognised text across the pages of one document scan, each line stamped with the page it
    /// came from. Pages are supplied in capture order.
    ///
    /// Throws `RecognitionError.noTextFound` when *no* page yielded readable text; a single blank
    /// page inside a multi-page invoice is not a failure.
    ///
    /// A protocol-extension default is provided, so a conformer that has nothing better to offer
    /// gets correct multi-page behaviour without writing a line of code.
    func recognizePages(_ pages: [Data]) async throws -> [RecognizedLine]
}

extension TextRecognizing {

    /// Default: recognises each page in turn and stamps `page` with its index.
    ///
    /// Pages are processed sequentially rather than concurrently on purpose. Recognition is memory
    /// hungry — a full-page invoice decodes to tens of megabytes — and a five-page scan run in
    /// parallel is exactly how a capture flow gets jetsammed on an older device. Sequential also
    /// keeps the returned order stable, which the ranking layer depends on.
    ///
    /// Only `RecognitionError.noTextFound` is tolerated per page. Anything else — undecodable data,
    /// a Vision failure — propagates, because those mean the caller handed over something broken
    /// rather than something blank.
    func recognizePages(_ pages: [Data]) async throws -> [RecognizedLine] {
        guard !pages.isEmpty else { throw RecognitionError.noTextFound }

        var results: [RecognizedLine] = []
        for (index, pageData) in pages.enumerated() {
            let lines: [RecognizedLine]
            do {
                lines = try await recognizeLines(in: pageData)
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
