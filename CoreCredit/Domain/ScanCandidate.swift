//
//  ScanCandidate.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — no SwiftData, no SwiftUI, no UIKit, no Vision.
//
//  ## What a candidate is, and what it is not
//
//  A `ScanCandidate` is a *proposal*. It is what the scan layer thinks it saw, together with the
//  evidence that led it there. Nothing in this file writes anything anywhere: candidates travel
//  from the recognisers into the review sheet, the user ticks the ones that are right, and only
//  then does an ordinary assignment put a value into `CoreItemDraft`.
//
//  Three invariants are load-bearing:
//
//  1. **`rawValue` is sacred.** It is exactly what was recognised, and it is never rewritten.
//     Cleanup produces a separate `normalizedValue` so the original is still there when a
//     technician asks "what did it actually read?".
//  2. **Identifiers are strings.** A part number, an invoice number, an RMA — none of them are
//     ever converted to a number, so `007`, `03-1887` and `A/12` all survive intact.
//  3. **Money is `Int64` cents.** `money` routes through `Money.parse` and can never be a `Double`.
//     `confidence` *is* a `Double`, but it is a ranking score, not an amount of money.
//

import Foundation

/// What a candidate claims to be.
///
/// The kinds deliberately do not map one-to-one onto `CoreItemField`: some of them (`.barcode`,
/// `.date`, `.unknown`) are informational and have no field to fill until the user retargets them
/// in the review sheet.
enum ScanCandidateKind: String, CaseIterable, Codable, Sendable, Identifiable {

    /// A manufacturer part number, e.g. `03-1887`.
    case partNumber

    /// The raw payload of a scanned symbol, kept verbatim so it can be stored alongside — never
    /// instead of — the confirmed part number.
    case barcode

    /// A vendor invoice number.
    case invoiceNumber

    /// The shop's own repair-order / work-order number.
    case repairOrder

    /// The vendor's trading name, usually read off the invoice masthead.
    case vendorName

    /// The core charge itself. The only kind that carries money.
    case coreAmount

    /// A date printed on the document. Informational: the received date is the app's own clock.
    case date

    /// A return authorisation / RMA number issued by the vendor.
    case returnReference

    /// Recognised text that matched nothing in particular.
    case unknown

    var id: String { rawValue }

    /// Row title in the review sheet. Written for a technician, not for a developer.
    var displayName: String {
        switch self {
        case .partNumber: return "Part number"
        case .barcode: return "Barcode value"
        case .invoiceNumber: return "Invoice number"
        case .repairOrder: return "Repair order"
        case .vendorName: return "Vendor"
        case .coreAmount: return "Core charge"
        case .date: return "Date"
        case .returnReference: return "Return reference"
        case .unknown: return "Recognised text"
        }
    }

    /// SF Symbol shown next to the row.
    var symbolName: String {
        switch self {
        case .partNumber: return "number"
        case .barcode: return "barcode"
        case .invoiceNumber: return "doc.text"
        case .repairOrder: return "wrench.and.screwdriver"
        case .vendorName: return "building.2"
        case .coreAmount: return "dollarsign.circle"
        case .date: return "calendar"
        case .returnReference: return "arrow.uturn.backward"
        case .unknown: return "questionmark.circle"
        }
    }

    /// The intake field this candidate can fill.
    ///
    /// `nil` for kinds with no direct field — `.barcode` (kept apart from the confirmed part
    /// number on purpose), `.date` (the received date comes from the app's clock, not from a
    /// photo), and `.unknown`. Those stay informational until the user retargets them.
    ///
    /// `.returnReference` lands in `.notes`: CoreCredit has no dedicated RMA field, and an RMA is
    /// emphatically *not* an invoice number, so filing it under `.invoiceReference` would put the
    /// wrong kind of number in a field the vendor later reconciles against.
    var coreItemField: CoreItemField? {
        switch self {
        case .partNumber: return .partNumber
        case .barcode: return nil
        case .invoiceNumber: return .invoiceReference
        case .repairOrder: return .repairOrderReference
        case .vendorName: return .vendor
        case .coreAmount: return .expectedCredit
        case .date: return nil
        case .returnReference: return .notes
        case .unknown: return nil
        }
    }
}

/// Where a candidate came from.
///
/// Kept on the candidate so the review sheet can say "read from the camera" versus "read from a
/// photo you picked", and so diagnostics can tell the two capture paths apart.
enum ScanSource: String, Codable, Sendable, Identifiable {

    /// Live camera session, barcode symbol.
    case liveBarcode

    /// Live camera session, recognised text.
    case liveText

    /// Multi-page document scan (VisionKit document camera).
    case documentOCR

    /// A single still image picked from the photo library or taken with the camera.
    case photoOCR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveBarcode: return "Live barcode scan"
        case .liveText: return "Live text scan"
        case .documentOCR: return "Scanned document"
        case .photoOCR: return "Photo"
        }
    }
}

/// How sure the scan layer is, shown to the user as a word instead of a misleading percentage.
///
/// A percentage invites arithmetic ("87% of $86.50"?) and implies a calibration the heuristics do
/// not have. Three bands say what the UI actually needs to say: trust it, check it, or ignore it.
enum ScanConfidenceBand: String, Codable, Sendable, Comparable, CaseIterable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// `< 0.50` is low, `< 0.80` is medium, everything else is high.
    ///
    /// A `NaN` score collapses to `.low` rather than propagating: a comparison against `NaN` is
    /// always false, so without this guard a broken score would silently read as `.high`.
    static func band(for score: Double) -> ScanConfidenceBand {
        if score.isNaN { return .low }
        if score < 0.50 { return .low }
        if score < 0.80 { return .medium }
        return .high
    }

    /// Rank used for ordering. Not part of the public surface — the `Comparable` conformance is.
    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: ScanConfidenceBand, rhs: ScanConfidenceBand) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// A normalised (0…1) rectangle in image space.
///
/// The origin is **bottom-left**, exactly as Vision reports it, so a value copied out of a
/// `VNRecognizedTextObservation` needs no flipping on the way in. Flipping, if any, belongs to the
/// view that draws it.
struct ScanBoundingBox: Equatable, Codable, Sendable {

    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Vertical centre of the rectangle. Used to decide whether a value sits on the same line of
    /// the page as the label that introduces it.
    var midY: Double { y + (height / 2) }
}

/// One proposal produced by the scan layer.
///
/// Equality deliberately ignores `id`, matching `RecognizedLine`, `ScanResult` and
/// `OCRFieldSuggestion` elsewhere in the app: two candidates describing the same recognition are
/// the same candidate, which is what unit tests want to assert. `id` exists so SwiftUI can list
/// them and so a review row can be addressed by identifier.
struct ScanCandidate: Identifiable, Equatable, Sendable, Codable {

    /// Per-instance identity for SwiftUI and for accessibility identifiers. Not part of equality.
    var id: UUID

    var kind: ScanCandidateKind

    /// Exactly what was recognised, byte for byte. **Never altered.**
    var rawValue: String

    /// The cleaned form that is safe to drop into a field. May equal `rawValue`.
    var normalizedValue: String

    /// Ranking score, 0…1. Clamped on construction; a non-finite score collapses to 0.
    ///
    /// This is the extractor's own confidence in its *reasoning*, not a character-recognition
    /// probability, and it never decides anything on its own — it orders rows and picks a band.
    var confidence: Double

    var source: ScanSource

    /// `VNBarcodeSymbology.rawValue` when the candidate came from a symbol, otherwise `nil`.
    var barcodeSymbology: String?

    /// Page index for multi-page document scans, otherwise `nil`.
    var page: Int?

    var boundingBox: ScanBoundingBox?

    /// Human-readable justification, e.g. `Follows the label "CORE CHARGE"`.
    ///
    /// Every candidate carries one. Months from now the only way to debug "why did it suggest
    /// that?" is to be able to read the sentence the rule wrote at the time.
    var reason: String

    /// Character-confusion variants (`O`/`0`, `I`/`1`, `S`/`5`) offered as tappable chips.
    /// **Offered, never auto-applied** — swapping a character on the user's behalf is exactly the
    /// class of silent error this layer exists to avoid.
    var alternatives: [String]

    init(kind: ScanCandidateKind,
         rawValue: String,
         normalizedValue: String? = nil,
         confidence: Double,
         source: ScanSource,
         reason: String,
         barcodeSymbology: String? = nil,
         page: Int? = nil,
         boundingBox: ScanBoundingBox? = nil,
         alternatives: [String] = [],
         id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.rawValue = rawValue
        self.normalizedValue = normalizedValue ?? rawValue
        self.confidence = ScanCandidate.clamped(confidence)
        self.source = source
        self.reason = reason
        self.barcodeSymbology = barcodeSymbology
        self.page = page
        self.boundingBox = boundingBox
        self.alternatives = alternatives
    }

    static func == (lhs: ScanCandidate, rhs: ScanCandidate) -> Bool {
        lhs.kind == rhs.kind
            && lhs.rawValue == rhs.rawValue
            && lhs.normalizedValue == rhs.normalizedValue
            && lhs.confidence == rhs.confidence
            && lhs.source == rhs.source
            && lhs.barcodeSymbology == rhs.barcodeSymbology
            && lhs.page == rhs.page
            && lhs.boundingBox == rhs.boundingBox
            && lhs.reason == rhs.reason
            && lhs.alternatives == rhs.alternatives
    }

    var band: ScanConfidenceBand { ScanConfidenceBand.band(for: confidence) }

    /// Exact cents for `.coreAmount`; `nil` for every other kind.
    ///
    /// Parsing goes through `Money.parse` under a fixed POSIX locale, so a device set to German
    /// and a device set to English turn the same recognised text into the same number of cents.
    /// There is no `Double` anywhere on this path.
    var money: Money? {
        guard kind == .coreAmount else { return nil }
        return Money.parse(normalizedValue, locale: ScanCandidate.moneyParsingLocale)
    }

    /// `true` only for `.high`. Drives which rows start ticked in the review sheet.
    ///
    /// Everything below `.high` starts unticked, which is the whole point: a medium-confidence
    /// guess that nobody looked at must never reach the ledger.
    var isSafeToPreselect: Bool { band == .high }

    // MARK: - Private

    /// Fixed parsing locale, matching `OCRSuggestionExtractor`. POSIX always uses `.` as its
    /// decimal separator, which is what `Money.plainDecimalString` produces.
    private static let moneyParsingLocale = Locale(identifier: "en_US_POSIX")

    /// Keeps `confidence` inside 0…1 so no heuristic can leak an out-of-range score — or a `NaN`,
    /// which would otherwise band as `.high` because every comparison against it is false.
    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
