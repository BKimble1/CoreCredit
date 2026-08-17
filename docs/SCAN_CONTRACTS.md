# CoreCredit — scan/capture API contract (addendum to CONTRACTS.md)

**Normative.** This file governs the scan, OCR, and scan-confirmation layer. Where it conflicts
with `docs/CONTRACTS.md`, this file wins for the types it names; everything else in
`CONTRACTS.md` still applies unchanged.

## Non-negotiable rules

1. **A scan never writes a record.** Candidates flow into the in-memory `CoreItemDraft` only, and
   only after the user selects them. The only persistence path remains the existing Save action
   through `CoreItemService`.
2. **Nothing is auto-applied.** A candidate below `.high` confidence must never start selected.
3. **`rawValue` is sacred.** The exact recognized string is preserved forever. Cleanup produces a
   *separate* `normalizedValue`. Never mutate `rawValue`.
4. **Identifiers are strings, never numbers.** Leading zeros, hyphens, slashes, and letters survive.
   No `Int`/`Double` conversion is ever applied to an identifier.
5. **Money is `Int64` cents via `Decimal`.** No `Double` or `Float` may appear in any money path,
   including scan parsing and ranking.
6. **Confidence never decides money.** It orders and bands candidates; the user confirms.
7. **Offline only.** No network call, no API key, no telemetry upload, anywhere in this layer.
8. **New SwiftData properties must be optional or defaulted**, and require a real `SchemaV2` plus a
   lightweight migration stage — never a silent redefinition of V1.

---

## 1. `CoreCredit/Domain/ScanCandidate.swift` (pure Foundation)

```swift
enum ScanCandidateKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case partNumber, barcode, invoiceNumber, repairOrder, vendorName,
         coreAmount, date, returnReference, unknown
    var id: String { rawValue }
    var displayName: String { get }        // "Part number", "Barcode value", "Invoice number", …
    var symbolName: String { get }
    /// The intake field this candidate can fill. `nil` for kinds with no direct field
    /// (`.barcode`, `.date`, `.unknown`) — those are informational until the user retargets them.
    var coreItemField: CoreItemField? { get }
}

enum ScanSource: String, Codable, Sendable, Identifiable {
    case liveBarcode, liveText, documentOCR, photoOCR
    var id: String { rawValue }
    var displayName: String { get }
}

/// Shown to the user instead of a misleading percentage.
enum ScanConfidenceBand: String, Codable, Sendable, Comparable, CaseIterable {
    case low, medium, high
    var displayName: String { get }        // "Low" / "Medium" / "High"
    /// < 0.50 -> .low ; < 0.80 -> .medium ; else .high. NaN -> .low.
    static func band(for score: Double) -> ScanConfidenceBand
    static func < (lhs: ScanConfidenceBand, rhs: ScanConfidenceBand) -> Bool
}

/// Normalized (0…1) Vision rectangle. Origin is bottom-left, as Vision reports it.
struct ScanBoundingBox: Equatable, Codable, Sendable {
    var x: Double, y: Double, width: Double, height: Double
    init(x: Double, y: Double, width: Double, height: Double)
    var midY: Double { get }
}

struct ScanCandidate: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var kind: ScanCandidateKind
    /// Exactly what was recognized. Never altered.
    var rawValue: String
    /// Cleaned for use. May equal `rawValue`.
    var normalizedValue: String
    var confidence: Double                 // clamped 0…1; NaN -> 0
    var source: ScanSource
    var barcodeSymbology: String?
    var page: Int?
    var boundingBox: ScanBoundingBox?
    /// Human-readable justification, e.g. "Follows the label \"CORE CHARGE\"".
    var reason: String
    /// Character-confusion variants (O/0, I/1, S/5). Offered, never auto-applied.
    var alternatives: [String]

    init(kind: ScanCandidateKind, rawValue: String, normalizedValue: String? = nil,
         confidence: Double, source: ScanSource, reason: String,
         barcodeSymbology: String? = nil, page: Int? = nil,
         boundingBox: ScanBoundingBox? = nil, alternatives: [String] = [],
         id: UUID = UUID())

    var band: ScanConfidenceBand { get }
    /// Exact cents for `.coreAmount`; nil for every other kind. Never returns a Double.
    var money: Money? { get }
    /// True only for `.high`. Drives initial selection in the review sheet.
    var isSafeToPreselect: Bool { get }
}
```

## 2. `CoreCredit/Domain/ScanTextNormalizer.swift` (pure Foundation)

```swift
enum ScanTextNormalizer {
    /// C0/C1 controls plus the GS1 separators scanners emit (GS 0x1D, RS 0x1E, US 0x1F, EOT 0x04).
    static let scannerControlCharacters: CharacterSet

    /// Removes control characters and trims edges. Inner spaces, hyphens, slashes,
    /// letters and leading zeros are preserved exactly.
    static func stripControlCharacters(_ value: String) -> String

    /// Uppercases, collapses runs of whitespace to one space, trims.
    /// MUST NOT remove leading zeros, hyphens, or slashes.
    static func normalizedIdentifier(_ value: String) -> String

    /// O<->0, I<->1, S<->5 single-substitution variants, deterministic order,
    /// excluding the input itself. Capped at `limit`.
    static func confusionAlternatives(for value: String, limit: Int = 4) -> [String]

    static func isAllDigits(_ value: String) -> Bool
    /// Contains at least one digit and at least one letter or separator.
    static func looksLikeIdentifier(_ value: String) -> Bool
}
```

## 3. `CoreCredit/Domain/BarcodePayloadClassifier.swift` (pure Foundation)

```swift
struct BarcodeScanInput: Equatable, Sendable {
    var payload: String
    var symbology: String                  // VNBarcodeSymbology.rawValue
    var source: ScanSource
    init(payload: String, symbology: String, source: ScanSource = .liveBarcode)
}

enum BarcodeSymbologyClass: String, Sendable {
    case linearNumeric        // UPC-A/E, EAN-8/13, ITF-14 — a product code, NOT a part number
    case linearAlphanumeric   // Code 39, Code 128 — may carry a part number
    case twoDimensional       // QR, DataMatrix, PDF417, Aztec
    case unknown
    /// Matches on `VNBarcodeSymbology.rawValue`, case-insensitively.
    static func classify(_ symbologyRawValue: String) -> BarcodeSymbologyClass
    var displayName: String { get }
}

struct GS1Element: Equatable, Sendable {
    var applicationIdentifier: String
    var value: String
}

enum GS1Parser {
    /// Parses ONLY when the structure is unambiguous: either explicit FNC1/GS separators are
    /// present, or every element uses a known fixed-length AI and the payload is fully consumed.
    /// Returns nil rather than guessing. MUST NOT strip a prefix merely because it resembles an AI.
    static func parse(_ payload: String) -> [GS1Element]?
    static let fixedLengthAIs: [String: Int]   // "00":18, "01":14, "11":6, "17":6, …
}

enum BarcodePayloadClassifier {
    /// Always emits a `.barcode` candidate carrying the raw payload.
    /// Emits an additional `.partNumber` candidate ONLY when the symbology is
    /// `.linearAlphanumeric` (or a GS1 AI 240/241 is unambiguously present) — a numeric
    /// UPC/EAN must never be presented as a part number.
    /// Ranked by `confidence`, highest first.
    static func candidates(for input: BarcodeScanInput) -> [ScanCandidate]
}
```

## 4. `CoreCredit/Domain/ScanMoneyParser.swift` (pure Foundation)

```swift
// `Error` is mandatory: this is the `Failure` half of `Result<Money, ScanMoneyRejection>`, and
// the standard library constrains `Result.Failure` to `Error`. Omitting it makes the generic
// unformable and yields the misleading "cannot infer contextual base in reference to member".
enum ScanMoneyRejection: String, Error, Equatable, Sendable {
    case notMoney, ambiguousSeparator, tooManyFractionDigits, outOfRange
    var explanation: String { get }
}

enum ScanMoneyParser {
    /// Exact `Int64` cents through `Money`/`Decimal`. Never constructs a Double.
    /// Accepts "$86.50", "86.50", "1,234.56", and "86,50" when the locale uses a comma decimal.
    /// Rejects "1.234" as `.ambiguousSeparator` (thousands vs decimal cannot be resolved)
    /// unless a currency symbol plus exactly two fraction digits disambiguates it.
    /// Rejects "86.500", "12-34", "" and non-money text.
    static func parse(_ token: String, locale: Locale) -> Result<Money, ScanMoneyRejection>
    /// Money-shaped substrings in reading order. Does not parse them.
    static func moneyTokens(in line: String) -> [String]
}
```

## 5. `CoreCredit/Domain/ScanSessionDeduplicator.swift` (pure Foundation)

```swift
struct ScanAcceptance: Equatable, Sendable {
    var payload: String
    var symbology: String
    var acceptedAt: Date
}

/// Value type so it is trivially testable with an injected clock. Held by the scanner coordinator.
struct ScanSessionDeduplicator: Equatable, Sendable {
    static let defaultCooldown: TimeInterval = 1.25
    init(cooldown: TimeInterval = ScanSessionDeduplicator.defaultCooldown)
    var cooldown: TimeInterval { get }
    private(set) var lastAcceptance: ScanAcceptance?
    private(set) var acceptedPayloads: Set<String>

    /// Returns true and records when the scan is new AND the cooldown has elapsed.
    /// Returns false for a repeat of any payload accepted this session, or inside the cooldown.
    mutating func accept(payload: String, symbology: String, now: Date) -> Bool
    mutating func reset()
}
```

## 6. Ranking — extend `CoreCredit/Services/OCRSuggestionExtractor.swift`

**Do not rewrite it and do not change `suggestions(from:)`** — existing unit tests pin its exact
confidences and ordering. Add alongside, reusing the existing private scoring helpers:

```swift
extension OCRSuggestionExtractor {
    /// Ranked candidates with reasons, highest confidence first.
    /// Label proximity and page position both contribute.
    static func candidates(from lines: [RecognizedLine], source: ScanSource) -> [ScanCandidate]
}
```

Ranking requirements:
- Recognized labels: `Core`, `Core Charge`, `Core Deposit`, `Core Value`, `Part`, `Part Number`,
  `P/N`, `Invoice`, `Invoice Number`, `RO`, `Repair Order`, `Return`, `RMA`, `Credit`, `Amount`,
  `Total`.
- An amount on a line mentioning core charge / core deposit / core value **outranks** any other
  amount, including the invoice total.
- **Negative keywords never selected as the core credit:** `total`, `subtotal`, `grand total`,
  `balance`, `amount due`, `tax`, `sales tax`, `vat`, `gst`, `freight`, `shipping`, `handling`,
  `delivery`, `misc`, `environmental`, `disposal`, `fee`, `labor`, `discount`.
  These may still appear as candidates, but ranked below any core-labelled amount and never
  `.high`.
- When `boundingBox` is available, a candidate physically near its label ranks above a
  same-scoring candidate that is not.
- Every candidate carries a `reason` naming what drove it.

## 7. Recognition layer — `CoreCredit/Services/TextRecognizing.swift`

`RecognizedLine` gains three **defaulted** members so every existing call site still compiles:

```swift
struct RecognizedLine: Equatable, Sendable, Identifiable {
    var id: UUID
    var text: String
    var confidence: Double
    var boundingBox: ScanBoundingBox?      // NEW, default nil
    var alternatives: [String]             // NEW, default []
    var page: Int                          // NEW, default 0
    init(id: UUID = UUID(), text: String, confidence: Double,
         boundingBox: ScanBoundingBox? = nil, alternatives: [String] = [], page: Int = 0)
}
```

`TextRecognizing` gains one requirement **with a protocol-extension default**, so existing
conformers keep compiling:

```swift
protocol TextRecognizing: Sendable {
    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine]
    func recognizeBarcodes(in imageData: Data) async throws -> [ScanResult]
    func recognizePages(_ pages: [Data]) async throws -> [RecognizedLine]   // NEW
}
extension TextRecognizing {
    /// Default: maps `recognizeLines` over each page, stamping `page`.
    func recognizePages(_ pages: [Data]) async throws -> [RecognizedLine]
}
```

`VisionTextRecognizer` must additionally: keep `usesLanguageCorrection = false` and
`.accurate`, capture `observation.boundingBox` into `ScanBoundingBox`, and read
`topCandidates(3)` so the 2nd/3rd strings become `alternatives` (never a silent replacement).

## 8. Diagnostics — `CoreCredit/Services/ScanDiagnostics.swift`

Local-only. **Never uploads. Never stores image bytes. Never records credentials.**

```swift
struct ScanDiagnosticsBarcode: Codable, Equatable, Sendable, Identifiable {
    var id: UUID; var payload: String; var symbology: String
    var accepted: Bool; var reason: String
}
struct ScanDiagnosticsLine: Codable, Equatable, Sendable, Identifiable {
    var id: UUID; var text: String; var confidence: Double; var page: Int
}
struct ScanDiagnosticsCandidate: Codable, Equatable, Sendable, Identifiable {
    var id: UUID; var kind: String; var rawValue: String; var normalizedValue: String
    var band: String; var reason: String; var symbology: String?
}
struct ScanDiagnosticsSession: Codable, Equatable, Sendable {
    var startedAt: Date
    var source: String
    var availability: String
    var barcodes: [ScanDiagnosticsBarcode]
    var lines: [ScanDiagnosticsLine]
    var candidates: [ScanDiagnosticsCandidate]
    var failures: [String]
    var notes: [String]
    var isEmpty: Bool { get }
}

@MainActor @Observable final class ScanDiagnosticsRecorder {
    init(dateProvider: any DateProvider)
    /// Only the most recent session is retained.
    private(set) var session: ScanDiagnosticsSession?
    func begin(source: ScanSource, availability: ScannerAvailability)
    func recordBarcode(payload: String, symbology: String, accepted: Bool, reason: String)
    func recordLines(_ lines: [RecognizedLine])
    func recordCandidates(_ candidates: [ScanCandidate])
    func recordFailure(_ message: String)
    func note(_ message: String)
    func clear()
    /// Pretty-printed, ISO-8601 dates, sorted keys. nil when there is no session.
    func jsonReport() -> String?
}
```

## 9. UI — `CoreCredit/Features/Capture/ScanReviewSheet.swift`

```swift
struct ScanReviewSession: Equatable, Sendable, Identifiable {
    var id: UUID
    var source: ScanSource
    var candidates: [ScanCandidate]
    var rawLines: [String]
    /// Preview only; held in memory for the life of the sheet and never persisted.
    var previewImageData: Data?
    init(id: UUID = UUID(), source: ScanSource, candidates: [ScanCandidate],
         rawLines: [String] = [], previewImageData: Data? = nil)
}

@MainActor struct ScanReviewSheet: View {
    init(session: ScanReviewSession,
         onApply: @escaping ([ScanCandidate]) -> Void,
         onRetake: @escaping () -> Void)
}
```

Required content: preview image when present; ranked candidate rows each showing kind, the
editable value, the band (`High`/`Medium`/`Low` — never a percentage), the `reason`, the raw
recognized value, and any `alternatives` as tappable chips; a per-row selection toggle; a field
picker so the user can retarget a candidate; **Apply Selected Suggestions**, **Retake**, **Cancel**.
Only `.high` candidates start selected.

## 10. Live scanning — `CoreCredit/Services/BarcodeScannerView.swift`

```swift
@MainActor struct BarcodeScannerView: UIViewControllerRepresentable {
    init(isPaused: Bool,
         onScan: @escaping (ScanResult) -> Void,
         onError: @escaping (String) -> Void)
    /// Exactly these, passed explicitly to `recognizedDataTypes: [.barcode(symbologies:)]`.
    static let symbologies: [VNBarcodeSymbology]   // code128, code39, code39Checksum,
        // code39FullASCII, qr, dataMatrix, upce, ean8, ean13, itf14, pdf417, aztec
}
```

`ScanSheet` changes shape — it must no longer apply-and-dismiss in one step:

```swift
@MainActor struct ScanSheet: View {
    init(onCandidates: @escaping (ScanReviewSession) -> Void)
}
```

Behaviour: on an accepted scan the preview **freezes**, a single `.success` haptic fires, and the
frozen value plus its candidates are shown with **Use these details**, **Resume scanning**, and
**Cancel**. Duplicate suppression and the cooldown run through `ScanSessionDeduplicator` fed by
`AppEnvironment.dateProvider`. Cancelling must leave the intake draft untouched.

## 11. Routing and entry points

- `CoreEditorModel.Route` gains `case scanReview(ScanReviewSession)` and `case documentScan`.
  `Route.id` must be **unique per associated value** (the existing `.readPhoto` returns a constant
  id, which prevents re-presentation — do not repeat that mistake).
- `CoreEditorView` gains `init(mode: CoreEditorMode, initialRoute: CoreEditorModel.Route? = nil)`
  so the Dashboard quick action opens the scanner **without duplicating the intake form**.
- `DashboardModel.Route` gains `case scanCore`, surfaced as a "Scan core" action using
  `A11y.Dashboard.scanCore`.
- Settings gains a Scanner Diagnostics row → `ScannerDiagnosticsView`.

New `A11y` members (add to the app enum **and** the hand-maintained mirror in
`CoreCreditUITests/UITestSupport.swift` in the same change):

```swift
A11y.Dashboard.scanCore          = "dashboard.scanCore"
A11y.Scan.root                   = "scan.root"
A11y.Scan.manualEntry            = "scan.manualEntry"
A11y.Scan.useManual              = "scan.useManual"
A11y.Scan.resume                 = "scan.resume"
A11y.Scan.cancel                 = "scan.cancel"
A11y.ScanReview.root             = "scanReview.root"
A11y.ScanReview.apply            = "scanReview.apply"
A11y.ScanReview.retake           = "scanReview.retake"
A11y.ScanReview.cancel           = "scanReview.cancel"
A11y.ScanReview.row(_ id: UUID)  = "scanReview.row." + id.uuidString
A11y.Settings.diagnostics        = "settings.diagnostics"
A11y.Diagnostics.root            = "diagnostics.root"
A11y.Diagnostics.clear           = "diagnostics.clear"
```

## 12. Persistence — raw barcode kept apart from the confirmed part number

`CoreItem` gains two **optional** properties (lightweight-safe):

```swift
var scannedBarcodeValue: String?        // exact raw payload, never normalized
var scannedBarcodeSymbology: String?
```

> **Known limitation, recorded honestly.** `CoreCreditSchemaV1.models` returns the *live*
> `CoreItem.self`, which now carries the two new attributes — so V1 and V2 describe identical
> entities and the `.lightweight` stage is a structural no-op. Existing TestFlight stores still
> open, because SwiftData infers this purely-additive change from the store's own entity hashes.
> But the plan does not *pin* the shipped 1.0 shape, so it could not express a future
> **non-additive** change (a rename, a retype, a required attribute). Doing that properly needs
> frozen model copies nested inside each `VersionedSchema` — a seven-model refactor that is not
> worth the risk while every change so far is additive. Freeze V1's models before the first
> non-additive migration.

This requires a real `CoreCreditSchemaV2` listing the same models, with
`CoreCreditMigrationPlan.schemas == [CoreCreditSchemaV1.self, CoreCreditSchemaV2.self]` and
`stages == [.lightweight(fromVersion: CoreCreditSchemaV1.self, toVersion: CoreCreditSchemaV2.self)]`,
and `ModelContainerFactory` building `Schema(versionedSchema: CoreCreditSchemaV2.self)`.
Existing TestFlight stores must open unchanged. `CoreItemDraft` gains matching optional fields;
`CoreItemService.createItem`/`update` persist them. The confirmed part number stays in
`partNumber` — the raw payload must never overwrite it.
