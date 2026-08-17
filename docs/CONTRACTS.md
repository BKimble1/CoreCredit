# CoreCredit — Authoritative API Contract

> **The scan/OCR/capture layer has its own addendum: `docs/SCAN_CONTRACTS.md`.**
> Where the two disagree about a scan type, the addendum wins. Everything else here still applies.

**This file is normative.** Every file in the app must compile against exactly these declarations.
If you are implementing a layer, you MUST:

1. Implement the declarations for your layer *verbatim* (same names, same parameter labels, same types).
2. Only *call* symbols that appear here or that you declared yourself.
3. Never rename, re-order labels, or "improve" a signature. If a signature is genuinely wrong,
   implement it as written and note the problem in your report instead of diverging.
4. Add extra private helpers freely — anything `private`/`fileprivate` is yours.

Module is a single app target named `CoreCredit`. There is no framework, no `import CoreCredit`
inside the app target. Unit tests use `@testable import CoreCredit`.

Language mode: **Swift 5** (`SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY = minimal`),
compiler Xcode 16+, deployment target **iOS 18.0**. Do not use Swift 6 language-mode-only syntax.
Do not use `fatalError`, force-unwrap (`!`), force-try, or force-cast anywhere in app code.
(`!` for non-optional Bool negation is obviously fine.)

Concurrency: annotate UI-facing and `ModelContext`-touching types `@MainActor`. Pure value types
and pure `enum` namespaces should be `Sendable` where free.

---

## File ownership map

| Path | Owner phase |
|---|---|
| `CoreCredit/App/*` | Phase 3 (App/Onboarding/Settings agent) |
| `CoreCredit/Models/*` | Phase 1 agent A |
| `CoreCredit/Domain/*` | Phase 1 agent B |
| `CoreCredit/Components/*`, `CoreCredit/Resources/*` | Phase 1 agent C |
| `CoreCredit/Services/Subscription*`, `Features/Paywall/*` | Phase 2 agent D |
| `CoreCredit/Services/Scan*`, `Vision*`, `Image*`, `QR*` | Phase 2 agent E |
| `CoreCredit/Services/Notification*`, `Export*`, `Snapshot*` | Phase 2 agent F |
| `CoreCredit/Services/CoreItemService.swift`, `ReturnBatchService.swift` | Phase 1 agent A |
| `CoreCredit/Features/*` | Phase 3 |
| `CoreCreditTests/*`, `CoreCreditUITests/*` | Phase 4 |

---

## 1. Configuration — `CoreCredit/App/AppConfiguration.swift` (Phase 1 agent C)

```swift
import Foundation

/// Single place to change the working name, identifiers, and placeholder URLs before release.
enum AppConfiguration {
    static let displayName = "CoreCredit"
    static let bundleIdentifier = "com.example.corecredit"

    // MARK: StoreKit — must match StoreKit/CoreCredit.storekit and App Store Connect
    static let monthlyProductID = "com.example.corecredit.pro.monthly"
    static let annualProductID  = "com.example.corecredit.pro.annual"
    static let subscriptionGroupIdentifier = "21500000"
    static var subscriptionProductIDs: [String] { [monthlyProductID, annualProductID] }

    // MARK: Placeholder URLs — owner must replace before submission
    static let supportURLString = "https://example.com/corecredit/support"
    static let privacyURLString = "https://example.com/corecredit/privacy"
    static let termsURLString   = "https://example.com/corecredit/terms"
    static let supportEmail     = "support@example.com"

    static let fallbackURL = URL(fileURLWithPath: "/")
    static var supportURL: URL { URL(string: supportURLString) ?? fallbackURL }
    static var privacyURL: URL { URL(string: privacyURLString) ?? fallbackURL }
    static var termsURL: URL   { URL(string: termsURLString) ?? fallbackURL }

    // MARK: Policy
    static let freeUnresolvedItemLimit = 5
    static let defaultVendorReturnWindowDays = 30
    static let defaultReminderLeadDays = 3
    static let defaultReminderHour = 8
    static let defaultReminderMinute = 0
    static let defaultCurrencyCode = "USD"

    // MARK: Attachments
    static let attachmentMaxDimension: CGFloat = 2000
    static let attachmentJPEGQuality: CGFloat = 0.72
    static let thumbnailMaxDimension: CGFloat = 320

    // MARK: Exports
    static let exportRetention: TimeInterval = 24 * 60 * 60
    static let urlScheme = "corecredit"

    static var appVersion: String   // CFBundleShortVersionString, "1.0" fallback
    static var buildNumber: String  // CFBundleVersion, "1" fallback
    static var versionDisplayString: String  // "1.0 (1)"
}
```

Note: `CGFloat` requires `import CoreFoundation` or `import UIKit`; use `import UIKit`.

---

## 2. Domain — `CoreCredit/Domain/` (Phase 1 agent B)

Domain is **pure**. It may `import Foundation` and `import SwiftUI` only where noted. It must NOT
`import SwiftData`.

### 2.1 `Money.swift`

```swift
struct Money: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    var cents: Int64
    init(cents: Int64)
    init(_ cents: Int64)                       // convenience, same as init(cents:)

    static let zero: Money
    static func dollars(_ value: Int64) -> Money    // whole units helper for tests

    var isZero: Bool { get }
    var isNegative: Bool { get }
    var isPositive: Bool { get }
    var magnitude: Money { get }                    // absolute value
    var decimalValue: Decimal { get }               // cents / 100, exact, never Double

    static func + (lhs: Money, rhs: Money) -> Money
    static func - (lhs: Money, rhs: Money) -> Money
    static func += (lhs: inout Money, rhs: Money)
    static func -= (lhs: inout Money, rhs: Money)
    static prefix func - (value: Money) -> Money
    static func < (lhs: Money, rhs: Money) -> Bool

    var description: String { get }                 // "8650" -> "86.50", debug only

    /// Locale-aware currency string, e.g. "$86.50".
    func formatted(currencyCode: String, locale: Locale = .current) -> String
    /// Plain, unlocalised "86.50" — used by CSV/JSON so exports never carry grouping separators.
    var plainDecimalString: String { get }
    /// "86 dollars and 50 cents"-style spoken form for VoiceOver.
    func accessibilityText(currencyCode: String, locale: Locale = .current) -> String

    /// Parses user input. Accepts "86.50", "$86.50", "86,50" (locale decimal separator),
    /// "1,234.56", " 86.5 ", "86". Returns nil for empty/garbage/negative-with-no-digits.
    /// MUST go through Decimal — never Double.
    static func parse(_ text: String, locale: Locale = .current) -> Money?
}
```

### 2.2 `DateProvider.swift`

```swift
/// Injected clock/calendar so due dates and aging buckets are deterministic in tests.
protocol DateProvider: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

struct SystemDateProvider: DateProvider {
    init(calendar: Calendar = .autoupdatingCurrent)
    var now: Date { get }
    var calendar: Calendar { get }
}

struct FixedDateProvider: DateProvider {
    init(now: Date, calendar: Calendar = FixedDateProvider.utcCalendar)
    static var utcCalendar: Calendar { get }   // gregorian, TimeZone(secondsFromGMT: 0)
    var now: Date
    var calendar: Calendar
    /// Convenience for tests: FixedDateProvider(year:month:day:)
    init(year: Int, month: Int, day: Int, hour: Int = 12, calendar: Calendar = FixedDateProvider.utcCalendar)
}
```

### 2.3 `CoreStatus.swift`

```swift
enum CoreStatus: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case awaitingCore
    case readyToReturn
    case returnedAwaitingCredit
    case credited
    case disputed
    case writtenOff

    var id: String { rawValue }
    var displayName: String { get }   // "Awaiting old core", "Ready to return",
                                      // "Returned — awaiting credit", "Credited",
                                      // "Disputed", "Written off"
    var shortName: String { get }     // "Awaiting", "Ready", "Returned", "Credited",
                                      // "Disputed", "Written off"
    var symbolName: String { get }    // SF Symbol; see Palette section for the agreed set
    var isUnresolved: Bool { get }    // awaitingCore, readyToReturn, returnedAwaitingCredit, disputed
    var isClosed: Bool { get }        // credited, writtenOff  (== !isUnresolved)
    /// Order used for status pickers and dashboard cards.
    var sortIndex: Int { get }
    /// Extra spoken context for VoiceOver, e.g. "Returned to vendor, credit not yet received."
    var accessibilityHint: String { get }

    static var unresolvedCases: [CoreStatus] { get }
    static var closedCases: [CoreStatus] { get }

    /// Safe decoding for values written by a future version. Unknown -> .awaitingCore.
    static func decoded(fromRawValue rawValue: String) -> CoreStatus

    /// Decodable conformance must also fall back to .awaitingCore rather than throwing.
    init(from decoder: any Decoder) throws
}
```

### 2.4 `CoreStatusMachine.swift`

```swift
enum CoreStatusMachine {
    /// Canonical transition table. Same-to-same is NOT allowed.
    /// awaitingCore            -> readyToReturn, writtenOff
    /// readyToReturn           -> returnedAwaitingCredit, awaitingCore, writtenOff
    /// returnedAwaitingCredit  -> credited, disputed, readyToReturn, writtenOff
    /// credited                -> disputed, returnedAwaitingCredit
    /// disputed                -> credited, writtenOff, returnedAwaitingCredit
    /// writtenOff              -> awaitingCore, disputed
    static func allowedTransitions(from status: CoreStatus) -> Set<CoreStatus>
    static func canTransition(from: CoreStatus, to: CoreStatus) -> Bool
    static func validate(from: CoreStatus, to: CoreStatus) throws          // throws DomainError.invalidTransition
    /// Ordered list for menus (allowedTransitions sorted by sortIndex).
    static func userSelectableTransitions(from status: CoreStatus) -> [CoreStatus]
    /// True when the transition undoes a step and is safe to offer as "Undo".
    static func isReversal(from: CoreStatus, to: CoreStatus) -> Bool
}
```

### 2.5 `CoreItemRepresenting.swift`

```swift
/// Everything the domain needs from a core item. `CoreItem` (SwiftData) and
/// `CoreItemExportSnapshot` (Codable value) both conform, so calculators, filters,
/// and exporters are testable without SwiftData or SwiftUI.
protocol CoreItemRepresenting {
    var identifier: UUID { get }
    var partName: String { get }
    var partNumber: String { get }
    var invoiceReference: String { get }
    var repairOrderReference: String { get }
    var creditReference: String { get }
    var notes: String { get }
    var binLabel: String? { get }
    var vendorName: String? { get }
    var vendorIdentifier: UUID? { get }
    var status: CoreStatus { get }
    var expectedCredit: Money { get }
    var actualCredit: Money? { get }
    var receivedDate: Date { get }
    var dueDate: Date? { get }
    var returnedDate: Date? { get }
    var creditedDate: Date? { get }
    var createdAt: Date { get }
}
```

### 2.6 `AgingBucket.swift`

```swift
enum AgingBucket: String, CaseIterable, Identifiable, Sendable, Hashable {
    case zeroToSeven
    case eightToThirty
    case thirtyOnePlus

    var id: String { rawValue }
    var displayName: String { get }        // "0–7 days", "8–30 days", "31+ days" (en dash)
    var shortName: String { get }          // "0–7", "8–30", "31+"
    var lowerBoundDays: Int { get }        // 0, 8, 31
    var upperBoundDays: Int? { get }       // 7, 30, nil

    /// days < 0 clamps to .zeroToSeven.
    static func bucket(forDays days: Int) -> AgingBucket
}
```

### 2.7 `DueDateCalculator.swift`

```swift
enum DueDateCalculator {
    static let minimumWindowDays = 1
    static let maximumWindowDays = 365
    static func clampWindowDays(_ days: Int) -> Int

    /// startOfDay(receivedDate) + clamped(windowDays). Deterministic under the injected calendar.
    static func dueDate(receivedDate: Date, windowDays: Int, calendar: Calendar) -> Date

    /// Whole calendar days from startOfDay(from) to startOfDay(to). Negative when `to` precedes `from`.
    static func dayDifference(from: Date, to: Date, calendar: Calendar) -> Int
}
```

### 2.8 `RiskCalculator.swift`

```swift
struct AgingBucketSummary: Equatable, Sendable, Identifiable {
    var bucket: AgingBucket
    var count: Int
    var amount: Money
    var id: String { bucket.rawValue }
}

struct RiskSummary: Equatable, Sendable {
    var moneyAtRisk: Money
    var overdueAmount: Money
    var overdueCount: Int
    var unresolvedCount: Int
    var statusCounts: [CoreStatus: Int]
    var statusAmounts: [CoreStatus: Money]
    var agingBuckets: [AgingBucketSummary]      // always 3 entries, in AgingBucket.allCases order

    static let empty: RiskSummary
    func count(for status: CoreStatus) -> Int
    func amount(for status: CoreStatus) -> Money
    func aging(_ bucket: AgingBucket) -> AgingBucketSummary
    var hasAnyItems: Bool { get }
}

enum RiskCalculator {
    /// Closed (credited / writtenOff) -> .zero.
    /// Disputed with a recorded actual credit -> max(0, expected - actual).
    /// Everything else -> expected.
    static func remainingExposure(for item: some CoreItemRepresenting) -> Money

    /// expected - actual, or nil when no credit has been recorded. Positive == shortfall.
    static func discrepancy(for item: some CoreItemRepresenting) -> Money?

    /// Unresolved AND dueDate exists AND startOfDay(dueDate) < startOfDay(now).
    /// Due today is NOT overdue.
    static func isOverdue(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> Bool

    /// Whole days until dueDate (negative when past). nil when no due date or item is closed.
    static func daysUntilDue(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> Int?

    /// awaitingCore/readyToReturn -> receivedDate
    /// returnedAwaitingCredit     -> returnedDate ?? receivedDate
    /// disputed                   -> creditedDate ?? returnedDate ?? receivedDate
    /// credited/writtenOff        -> creditedDate ?? returnedDate ?? receivedDate
    static func referenceDate(for item: some CoreItemRepresenting) -> Date

    /// Days between referenceDate and now, clamped to >= 0.
    static func ageInDays(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> Int
    static func agingBucket(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> AgingBucket

    /// Aggregates only unresolved items into moneyAtRisk / aging buckets;
    /// statusCounts and statusAmounts cover every status present.
    static func summarize<Item: CoreItemRepresenting>(_ items: [Item], now: Date, calendar: Calendar) -> RiskSummary

    static func unresolvedCount<Item: CoreItemRepresenting>(_ items: [Item]) -> Int
}
```

### 2.9 `CreditReconciler.swift`

```swift
struct CreditReconciliation: Equatable, Sendable {
    var creditDate: Date
    var reference: String
    var amount: Money
    init(creditDate: Date, reference: String, amount: Money)
}

enum CreditOutcome: Equatable, Sendable {
    case exact
    case short(difference: Money)     // difference is positive
    case over(difference: Money)      // difference is positive

    var isDiscrepancy: Bool { get }
    var difference: Money { get }     // .zero for .exact
    var summaryText: String { get }   // e.g. "Short by ", caller appends formatted money
}

enum CreditReconciler {
    static func outcome(expected: Money, actual: Money) -> CreditOutcome
    /// .exact/.over -> .credited ; .short -> .disputed
    static func resultingStatus(for outcome: CreditOutcome) -> CoreStatus
}
```

### 2.10 `Entitlement.swift`

```swift
enum SubscriptionTier: String, Codable, Sendable, Equatable {
    case free
    case pro
    var displayName: String { get }
}

struct Entitlement: Codable, Sendable, Equatable {
    var tier: SubscriptionTier
    var expirationDate: Date?
    var isInGracePeriod: Bool
    var lastVerified: Date?
    var activeProductID: String?

    static let free: Entitlement
    var isPro: Bool { get }
    init(tier: SubscriptionTier, expirationDate: Date? = nil, isInGracePeriod: Bool = false,
         lastVerified: Date? = nil, activeProductID: String? = nil)
}

enum PaywallTrigger: Equatable, Sendable, Identifiable {
    case freeLimitReached(limit: Int)
    case voluntary
    var id: String { get }
    var headline: String { get }
    var subheadline: String { get }
}

enum EntitlementPolicy {
    static var freeUnresolvedLimit: Int { AppConfiguration.freeUnresolvedItemLimit }

    /// Pro is always true. Free is true while unresolvedCount < limit.
    static func canCreateItem(unresolvedCount: Int, tier: SubscriptionTier) -> Bool
    /// nil means unlimited (Pro).
    static func remainingFreeSlots(unresolvedCount: Int, tier: SubscriptionTier) -> Int?
    /// nil when creation is allowed.
    static func blockingTrigger(unresolvedCount: Int, tier: SubscriptionTier) -> PaywallTrigger?
    /// Existing records are never gated. Always true. Kept explicit so the rule is testable.
    static func canViewEditExportExistingItems(tier: SubscriptionTier) -> Bool
}
```

### 2.11 `CoreItemQuery.swift`

```swift
struct CoreItemFilter: Equatable, Sendable {
    var searchText: String
    var statuses: Set<CoreStatus>       // empty == all statuses
    var vendorIdentifier: UUID?
    var onlyOverdue: Bool
    var receivedOnOrAfter: Date?
    var receivedOnOrBefore: Date?

    init(searchText: String = "", statuses: Set<CoreStatus> = [], vendorIdentifier: UUID? = nil,
         onlyOverdue: Bool = false, receivedOnOrAfter: Date? = nil, receivedOnOrBefore: Date? = nil)

    static let none: CoreItemFilter
    var isActive: Bool { get }          // true when anything other than searchText is set
    var activeCriteriaCount: Int { get }
}

enum CoreItemSort: String, CaseIterable, Identifiable, Sendable {
    case dueDateAscending
    case valueDescending
    case newestFirst
    case oldestFirst
    var id: String { rawValue }
    var displayName: String { get }     // "Due date", "Highest value", "Newest", "Oldest"
    var symbolName: String { get }
}

enum CoreItemQuery {
    /// Case- and diacritic-insensitive substring match across partName, partNumber,
    /// invoiceReference, repairOrderReference, creditReference, vendorName, binLabel, notes.
    /// Empty/whitespace text matches everything.
    static func matchesSearch(_ item: some CoreItemRepresenting, text: String) -> Bool
    static func matches(_ item: some CoreItemRepresenting, filter: CoreItemFilter, now: Date, calendar: Calendar) -> Bool
    static func filter<Item: CoreItemRepresenting>(_ items: [Item], using filter: CoreItemFilter, now: Date, calendar: Calendar) -> [Item]
    /// Stable: ties broken by createdAt descending then identifier.
    /// dueDateAscending puts items with no due date last.
    static func sort<Item: CoreItemRepresenting>(_ items: [Item], by sort: CoreItemSort) -> [Item]
    static func filterAndSort<Item: CoreItemRepresenting>(_ items: [Item], filter: CoreItemFilter, sort: CoreItemSort, now: Date, calendar: Calendar) -> [Item]
    /// Groups ready-to-return items by vendor identifier for the Returns screen.
    static func groupedByVendor<Item: CoreItemRepresenting>(_ items: [Item]) -> [(vendorIdentifier: UUID?, vendorName: String, items: [Item])]
}
```

### 2.12 `CoreItemDraft.swift` + `CoreItemValidator.swift`

```swift
struct CoreItemDraft: Equatable, Sendable {
    var existingID: UUID?
    var partName: String
    var partNumber: String
    var vendorIdentifier: UUID?
    var binIdentifier: UUID?
    var expectedCreditText: String
    var invoiceReference: String
    var repairOrderReference: String
    var receivedDate: Date
    var usesCustomDueDate: Bool
    var customDueDate: Date?
    var notes: String

    init(existingID: UUID? = nil, partName: String = "", partNumber: String = "",
         vendorIdentifier: UUID? = nil, binIdentifier: UUID? = nil,
         expectedCreditText: String = "", invoiceReference: String = "",
         repairOrderReference: String = "", receivedDate: Date = Date(),
         usesCustomDueDate: Bool = false, customDueDate: Date? = nil, notes: String = "")

    var expectedCredit: Money? { get }         // Money.parse(expectedCreditText)
    var trimmedPartName: String { get }
    /// Resolved due date given the vendor window; customDueDate wins when usesCustomDueDate.
    func resolvedDueDate(vendorWindowDays: Int, calendar: Calendar) -> Date
}

enum CoreItemField: String, Hashable, Sendable, CaseIterable {
    case partName, partNumber, vendor, bin, expectedCredit, invoiceReference,
         repairOrderReference, receivedDate, dueDate, notes
    var displayName: String { get }
}

struct ValidationIssue: Equatable, Sendable, Identifiable {
    var field: CoreItemField
    var message: String
    var id: String { field.rawValue + "|" + message }
    init(field: CoreItemField, message: String)
}

enum CoreItemValidator {
    /// Rules:
    /// - partName must be non-empty after trimming -> "Enter a part name or description."
    /// - expectedCreditText must parse -> "Enter the core charge, for example 86.50."
    /// - parsed amount must be > 0 -> "The expected credit must be more than zero."
    /// - parsed amount must be <= 99_999_999 cents -> "That amount looks too large."
    /// - vendorIdentifier must be non-nil -> "Choose the vendor this core goes back to."
    /// - customDueDate (when used) must not precede receivedDate -> "The due date can't be before the received date."
    static func validate(_ draft: CoreItemDraft, calendar: Calendar) -> [ValidationIssue]
    static func firstIssue(_ issues: [ValidationIssue], for field: CoreItemField) -> ValidationIssue?
}
```

### 2.13 `DomainError.swift`

```swift
enum DomainError: LocalizedError, Equatable {
    case invalidTransition(from: CoreStatus, to: CoreStatus)
    case validationFailed([ValidationIssue])
    case mixedVendorBatch
    case emptyBatch
    case missingVendor
    case itemAlreadyInBatch(String)
    case persistenceFailed(String)
    case notFound

    var errorDescription: String? { get }
    var recoverySuggestion: String? { get }
}
```

---

## 3. Models — `CoreCredit/Models/` (Phase 1 agent A)

All `@Model final class`, `import SwiftData`. Every stored property has a default in `init`.
Money is stored as `Int64` cents. Optional strings are stored as non-optional `String` defaulting
to `""` (simpler SwiftData migrations); the `CoreItemRepresenting` conformance maps `""` -> `nil`
for `binLabel` / `vendorName` only.

### 3.1 `ShopProfile.swift`

```swift
@Model final class ShopProfile {
    var id: UUID = UUID()
    var name: String = ""
    var phone: String = ""
    var email: String = ""
    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var region: String = ""
    var postalCode: String = ""
    var currencyCode: String = AppConfiguration.defaultCurrencyCode
    var reminderLeadDays: Int = AppConfiguration.defaultReminderLeadDays
    var reminderHour: Int = AppConfiguration.defaultReminderHour
    var reminderMinute: Int = AppConfiguration.defaultReminderMinute
    var remindersEnabled: Bool = true
    var hasCompletedOnboarding: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String = "", currencyCode: String = AppConfiguration.defaultCurrencyCode, now: Date = Date())

    var displayName: String { get }          // name, or "Your shop" when empty
    var formattedAddress: String { get }     // multi-line, skips empty components
    var contactSummary: String { get }       // "phone • email", skips empties
    func touch(_ now: Date)                  // updatedAt = now
}
```

### 3.2 `Vendor.swift`

```swift
@Model final class Vendor {
    var id: UUID = UUID()
    var name: String = ""
    var contactName: String = ""
    var phone: String = ""
    var email: String = ""
    var accountNumber: String = ""
    var defaultReturnWindowDays: Int = AppConfiguration.defaultVendorReturnWindowDays
    var notes: String = ""
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \CoreItem.vendor)
    var coreItems: [CoreItem]? = []

    @Relationship(deleteRule: .nullify, inverse: \ReturnBatch.vendor)
    var returnBatches: [ReturnBatch]? = []

    init(name: String, defaultReturnWindowDays: Int = AppConfiguration.defaultVendorReturnWindowDays, now: Date = Date())

    var displayName: String { get }
    var items: [CoreItem] { get }            // coreItems ?? []
    var batches: [ReturnBatch] { get }
    func touch(_ now: Date)
}
```

### 3.3 `StorageBin.swift`

```swift
@Model final class StorageBin {
    var id: UUID = UUID()
    var label: String = ""
    var locationNote: String = ""
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \CoreItem.bin)
    var coreItems: [CoreItem]? = []

    init(label: String, locationNote: String = "", now: Date = Date())
    var displayName: String { get }
    var items: [CoreItem] { get }
    func touch(_ now: Date)
}
```

### 3.4 `CoreItem.swift`

```swift
@Model final class CoreItem {
    var id: UUID = UUID()
    var partName: String = ""
    var partNumber: String = ""
    var expectedCreditCents: Int64 = 0
    var actualCreditCents: Int64?
    var invoiceReference: String = ""
    var repairOrderReference: String = ""
    var creditReference: String = ""
    var statusRawValue: String = CoreStatus.awaitingCore.rawValue
    var receivedDate: Date = Date()
    var dueDate: Date?
    var usesCustomDueDate: Bool = false
    var returnedDate: Date?
    var creditedDate: Date?
    var notes: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var vendor: Vendor?
    var bin: StorageBin?
    var returnBatch: ReturnBatch?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.coreItem)
    var attachments: [Attachment]? = []

    @Relationship(deleteRule: .cascade, inverse: \CoreEvent.coreItem)
    var events: [CoreEvent]? = []

    init(partName: String, expectedCredit: Money, receivedDate: Date, vendor: Vendor? = nil,
         bin: StorageBin? = nil, now: Date = Date())

    // Typed accessors
    var status: CoreStatus { get set }              // get: CoreStatus.decoded(fromRawValue:) ; set: statusRawValue
    var expectedCredit: Money { get set }
    var actualCredit: Money? { get set }
    var photos: [Attachment] { get }                // attachments ?? [], sorted by capturedAt
    var timeline: [CoreEvent] { get }               // events ?? [], sorted by timestamp ascending
    var displayTitle: String { get }                // partName, or "Untitled core"
    func touch(_ now: Date)
}

extension CoreItem: CoreItemRepresenting {
    var identifier: UUID { id }
    var binLabel: String? { get }        // bin?.label, nil when empty
    var vendorName: String? { get }      // vendor?.name, nil when empty
    var vendorIdentifier: UUID? { get }  // vendor?.id
}
```

### 3.5 `ReturnBatch.swift`

```swift
enum ReturnMethod: String, CaseIterable, Codable, Sendable, Identifiable {
    case driverPickup
    case counterDropOff
    case shipped
    case other
    var id: String { rawValue }
    var displayName: String { get }   // "Driver pickup", "Counter drop-off", "Shipped", "Other"
    var symbolName: String { get }
    static func decoded(fromRawValue rawValue: String) -> ReturnMethod   // unknown -> .other
}

@Model final class ReturnBatch {
    var id: UUID = UUID()
    var returnDate: Date = Date()
    var methodRawValue: String = ReturnMethod.counterDropOff.rawValue
    var reference: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var closedAt: Date?

    var vendor: Vendor?

    @Relationship(deleteRule: .nullify, inverse: \CoreItem.returnBatch)
    var items: [CoreItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.returnBatch)
    var attachments: [Attachment]? = []

    init(vendor: Vendor?, returnDate: Date, method: ReturnMethod, reference: String = "", now: Date = Date())

    var method: ReturnMethod { get set }
    var coreItems: [CoreItem] { get }              // items ?? [], sorted by partName
    var receipts: [Attachment] { get }
    var itemCount: Int { get }
    var totalExpectedCredit: Money { get }
    var outstandingCredit: Money { get }           // sum of RiskCalculator.remainingExposure
    var isFullyCredited: Bool { get }
    var displayTitle: String { get }               // "NAPA — 3 cores" style
    func touch(_ now: Date)
}
```

### 3.6 `Attachment.swift`

```swift
enum AttachmentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case part
    case box
    case invoice
    case receipt
    case other
    var id: String { rawValue }
    var displayName: String { get }   // "Part", "Box or label", "Invoice", "Return receipt", "Other"
    var symbolName: String { get }
    static func decoded(fromRawValue rawValue: String) -> AttachmentKind  // unknown -> .other
}

@Model final class Attachment {
    var id: UUID = UUID()
    var kindRawValue: String = AttachmentKind.other.rawValue
    @Attribute(.externalStorage) var imageData: Data = Data()
    var caption: String = ""
    var capturedAt: Date = Date()
    var byteCount: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0

    var coreItem: CoreItem?
    var returnBatch: ReturnBatch?

    init(kind: AttachmentKind, imageData: Data, pixelWidth: Int, pixelHeight: Int,
         caption: String = "", capturedAt: Date = Date())

    var kind: AttachmentKind { get set }
    var accessibilityLabel: String { get }   // "Invoice photo captured 12 March 2026"
}
```

### 3.7 `CoreEvent.swift`

```swift
enum CoreEventType: String, CaseIterable, Codable, Sendable, Identifiable {
    case created
    case edited
    case statusChanged
    case photoAdded
    case photoRemoved
    case addedToBatch
    case removedFromBatch
    case returned
    case creditRecorded
    case disputeOpened
    case writtenOff
    case reopened
    case reminderScheduled
    case reminderCancelled
    var id: String { rawValue }
    var displayName: String { get }
    var symbolName: String { get }
    static func decoded(fromRawValue rawValue: String) -> CoreEventType   // unknown -> .edited
}

/// Append-only. Never mutate or delete an existing event except by cascade with its item.
@Model final class CoreEvent {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var typeRawValue: String = CoreEventType.edited.rawValue
    var detail: String = ""
    var amountCents: Int64?
    var reference: String = ""
    var fromStatusRawValue: String?
    var toStatusRawValue: String?

    var coreItem: CoreItem?

    init(type: CoreEventType, detail: String, timestamp: Date, amount: Money? = nil,
         reference: String = "", from: CoreStatus? = nil, to: CoreStatus? = nil)

    var type: CoreEventType { get }
    var amount: Money? { get }
    var fromStatus: CoreStatus? { get }
    var toStatus: CoreStatus? { get }
    var accessibilityDescription: String { get }
}
```

### 3.8 `CoreCreditSchema.swift`

```swift
enum CoreCreditSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [ShopProfile.self, Vendor.self, StorageBin.self, CoreItem.self,
         ReturnBatch.self, Attachment.self, CoreEvent.self]
    }
}

enum CoreCreditMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CoreCreditSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
```

### 3.9 `ModelContainerFactory.swift`

```swift
enum ModelContainerFactory {
    /// Never throws to the caller and never calls fatalError.
    /// On disk-store failure it retries in memory and records `lastLoadFailureMessage`.
    @MainActor static private(set) var lastLoadFailureMessage: String?

    static func makeContainer(inMemory: Bool) throws -> ModelContainer

    /// Bounded fallback ladder — NEVER an unbounded loop, never blocks the main thread.
    ///   1. the requested store (on disk unless `inMemory`)
    ///   2. the full schema in memory, recording `lastLoadFailureMessage`
    ///   3. a minimal single-model in-memory store
    /// Returns `nil` when all three fail. A nil result is a real, presentable state:
    /// `RootView` shows `StoreUnavailableView` rather than hanging or trapping.
    @MainActor static func makeAppContainer(inMemory: Bool) -> ModelContainer?

    /// Previews only. Returns nil if even the in-memory store cannot open, so preview
    /// bodies can `if let` instead of trapping.
    @MainActor static func makePreviewContainer() -> ModelContainer?    // in-memory + sample data
    @MainActor static func seedSampleData(in context: ModelContext, now: Date)
    @MainActor static func seedAcceptanceWalkthrough(in context: ModelContext, now: Date)  // NAPA / Alternator fixture
    @MainActor static func deleteAllData(in context: ModelContext) throws

    /// Removes the on-disk store (plus its `-wal`/`-shm` siblings) so the owner can recover
    /// from a corrupt or unopenable store. Safe when the files are already absent.
    /// Returns false only on a real removal failure.
    @MainActor static func destroyOnDiskStore() -> Bool
}
```

`schema` uses `Schema(versionedSchema: CoreCreditSchemaV1.self)` and
`ModelConfiguration(schema:isStoredInMemoryOnly:)`, migration plan `CoreCreditMigrationPlan.self`.

---

## 4. Mutation services — `CoreCredit/Services/` (Phase 1 agent A)

These own *all* writes so the event timeline can never be bypassed.

### 4.1 `CoreItemService.swift`

```swift
@MainActor
struct CoreItemService {
    let context: ModelContext
    let dateProvider: any DateProvider

    init(context: ModelContext, dateProvider: any DateProvider = SystemDateProvider())

    // Queries
    func allItems() throws -> [CoreItem]
    func unresolvedCount() throws -> Int
    func item(with id: UUID) throws -> CoreItem?
    func allVendors(includeInactive: Bool) throws -> [Vendor]
    func allBins(includeInactive: Bool) throws -> [StorageBin]
    func shopProfile() throws -> ShopProfile          // creates one if absent

    // Mutations
    @discardableResult
    func createItem(from draft: CoreItemDraft, vendor: Vendor?, bin: StorageBin?) throws -> CoreItem
    func update(_ item: CoreItem, from draft: CoreItemDraft, vendor: Vendor?, bin: StorageBin?) throws
    func transition(_ item: CoreItem, to status: CoreStatus, detail: String?) throws
    @discardableResult
    func recordCredit(_ item: CoreItem, reconciliation: CreditReconciliation) throws -> CreditOutcome
    func clearRecordedCredit(_ item: CoreItem) throws
    func writeOff(_ item: CoreItem, reason: String) throws
    func addAttachment(_ attachment: Attachment, to item: CoreItem) throws
    func removeAttachment(_ attachment: Attachment, from item: CoreItem) throws
    func delete(_ item: CoreItem) throws
    func recalculateDueDate(for item: CoreItem)

    // Vendors / bins / profile
    @discardableResult func createVendor(name: String, returnWindowDays: Int) throws -> Vendor
    func updateVendor(_ vendor: Vendor) throws
    func deleteVendor(_ vendor: Vendor) throws
    @discardableResult func createBin(label: String, locationNote: String) throws -> StorageBin
    func updateBin(_ bin: StorageBin) throws
    func deleteBin(_ bin: StorageBin) throws
    func updateShopProfile(_ profile: ShopProfile) throws

    // Internal helper other services may call
    func appendEvent(_ type: CoreEventType, to item: CoreItem, detail: String,
                     amount: Money?, reference: String,
                     fromStatus: CoreStatus?, toStatus: CoreStatus?)
    func draft(for item: CoreItem) -> CoreItemDraft
}
```

Behaviour notes (tests depend on these):
- `createItem` validates via `CoreItemValidator`, throws `DomainError.validationFailed` on issues,
  computes `dueDate` from the vendor window unless `usesCustomDueDate`, appends a `.created` event.
- `transition` validates via `CoreStatusMachine`, sets `returnedDate` when entering
  `.returnedAwaitingCredit` (if nil), clears `returnedDate` when leaving it backwards,
  appends a `.statusChanged` event, and calls `touch`.
- `recordCredit` sets `actualCredit`, `creditedDate`, `creditReference`, computes the outcome,
  transitions to `CreditReconciler.resultingStatus(for:)` **without** going through
  `CoreStatusMachine.validate` failure (the transition is always legal from
  `.returnedAwaitingCredit` and `.disputed`; from any other status it throws
  `DomainError.invalidTransition`), and appends `.creditRecorded` plus `.disputeOpened` when short.
- `delete(_ item:)` removes the item and its cascaded children; it does not delete the vendor/bin.

### 4.2 `ReturnBatchService.swift`

```swift
@MainActor
struct ReturnBatchService {
    let context: ModelContext
    let dateProvider: any DateProvider
    let itemService: CoreItemService

    init(context: ModelContext, dateProvider: any DateProvider = SystemDateProvider())

    func allBatches() throws -> [ReturnBatch]
    func openBatches() throws -> [ReturnBatch]        // any item still unresolved

    /// Throws .emptyBatch when items is empty, .missingVendor when vendor is nil,
    /// .mixedVendorBatch when any item's vendor differs from `vendor`.
    /// Moves every included item to .returnedAwaitingCredit and stamps returnedDate.
    @discardableResult
    func createBatch(vendor: Vendor?, items: [CoreItem], returnDate: Date, method: ReturnMethod,
                     reference: String, notes: String) throws -> ReturnBatch

    func addItems(_ items: [CoreItem], to batch: ReturnBatch) throws
    func removeItem(_ item: CoreItem, from batch: ReturnBatch) throws
    func updateBatch(_ batch: ReturnBatch, returnDate: Date, method: ReturnMethod,
                     reference: String, notes: String) throws
    func attachReceipt(_ attachment: Attachment, to batch: ReturnBatch) throws
    func removeReceipt(_ attachment: Attachment, from batch: ReturnBatch) throws
    func delete(_ batch: ReturnBatch) throws          // detaches items, leaves their status alone
}
```

---

## 5. Side-effect services — `CoreCredit/Services/` (Phase 2)

### 5.1 Subscription (agent D) — `SubscriptionModels.swift`, `StoreKitSubscriptionEngine.swift`, `SubscriptionController.swift`, `EntitlementCache.swift`

```swift
struct SubscriptionProduct: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var description: String
    var displayPrice: String            // ALWAYS from StoreKit. Never a hard-coded string.
    var period: SubscriptionPeriod
    var introductoryOffer: String?
    var isFamilyShareable: Bool
    /// Raw price for computing the annual-saving percentage. Declared last with a
    /// default so the argument order above still compiles. Never formatted directly —
    /// `displayPrice` is the only string shown to a user.
    var price: Decimal = 0
}

enum SubscriptionPeriod: String, Equatable, Sendable {
    case monthly, annual, unknown
    var displayName: String { get }     // "Monthly", "Annual", "Subscription"
    var perPeriodSuffix: String { get } // "/month", "/year", ""
}

enum ProductLoadState: Equatable, Sendable {
    case idle, loading, loaded, failed(String)
    var isFailed: Bool { get }
    var errorMessage: String? { get }
}

enum PurchasePhase: Equatable, Sendable {
    case idle
    case purchasing(productID: String)
    case pendingApproval
    case cancelled
    case failed(String)
    case succeeded
}

enum PurchaseResult: Equatable, Sendable {
    case success, pending, cancelled, failed(String)
}

/// `@MainActor` because a main-actor class cannot otherwise witness the synchronous
/// `entitlementUpdates()` requirement.
@MainActor protocol SubscriptionEngine: AnyObject {
    func loadProducts(identifiers: [String]) async throws -> [SubscriptionProduct]
    func purchase(productID: String) async throws -> PurchaseResult
    func currentEntitlement() async -> Entitlement
    func restorePurchases() async throws
    /// Emits a fresh entitlement whenever StoreKit reports a transaction update.
    func entitlementUpdates() -> AsyncStream<Entitlement>
}

@MainActor final class StoreKitSubscriptionEngine: SubscriptionEngine { init() }

/// Deterministic engine for UI tests and previews. Never touches StoreKit.
@MainActor final class StubSubscriptionEngine: SubscriptionEngine {
    init(tier: SubscriptionTier, simulateLoadFailure: Bool = false)
    var tier: SubscriptionTier { get set }
}

/// Offline-friendly last-known entitlement, stored in UserDefaults.
enum EntitlementCache {
    static func load(from defaults: UserDefaults = .standard) -> Entitlement
    static func save(_ entitlement: Entitlement, to defaults: UserDefaults = .standard)
    static func clear(_ defaults: UserDefaults = .standard)
}

@MainActor @Observable final class SubscriptionController {
    init(engine: any SubscriptionEngine, defaults: UserDefaults = .standard)
    private(set) var entitlement: Entitlement
    private(set) var products: [SubscriptionProduct]
    private(set) var loadState: ProductLoadState
    private(set) var purchasePhase: PurchasePhase
    var isPro: Bool { get }
    var monthlyProduct: SubscriptionProduct? { get }
    var annualProduct: SubscriptionProduct? { get }
    /// "Save 33%" style, computed from StoreKit prices only when both are available; nil otherwise.
    var annualSavingsText: String? { get }

    func start() async                      // load cache, refresh entitlement, observe updates
    func loadProducts() async
    func retryLoadProducts() async
    func purchase(_ product: SubscriptionProduct) async
    func restorePurchases() async
    func refreshEntitlement() async
    func clearPurchasePhase()
}
```

Paywall presentation for Settings uses `SubscriptionController` + `PaywallTrigger`.
Manage-subscription deep link: `AppStore.showManageSubscriptions(in:)` via a
`ManageSubscriptionSheet` or `Link(destination: URL(string: "https://apps.apple.com/account/subscriptions"))`
fallback — implement both, prefer the StoreKit sheet, fall back to the URL.

### 5.2 Scanning / Vision / Images / QR (agent E)

```swift
// ScannerAvailability.swift
enum ScannerAvailability: Equatable, Sendable {
    case available
    case simulator
    case unsupportedDevice
    case cameraDenied
    case cameraRestricted
    case cameraNotDetermined
    var allowsScanning: Bool { get }
    var explanation: String { get }        // user-facing sentence
    var actionTitle: String? { get }       // "Open Settings" / "Enter manually" / nil
}

struct ScanResult: Equatable, Sendable, Identifiable {
    var id: UUID
    var payload: String
    var symbology: String
    init(payload: String, symbology: String)
}

enum BarcodeScannerAvailabilityChecker {
    /// Reports .simulator on the simulator, and camera authorization otherwise.
    @MainActor static func current() -> ScannerAvailability
    @MainActor static func requestCameraAccess() async -> ScannerAvailability
    static var openSettingsURL: URL? { get }
}

// BarcodeScannerView.swift — UIViewControllerRepresentable over DataScannerViewController
// SUPERSEDED by docs/SCAN_CONTRACTS.md §10, which adds explicit symbologies, an
// `isPaused` binding, duplicate suppression, a cooldown on an injected clock, and haptics.
@MainActor struct BarcodeScannerView: UIViewControllerRepresentable {
    init(isPaused: Bool = false,
         dateProvider: any DateProvider = SystemDateProvider(),
         onScan: @escaping (ScanResult) -> Void,
         onError: @escaping (String) -> Void)
}

// TextRecognizing.swift
struct RecognizedLine: Equatable, Sendable, Identifiable {
    var id: UUID
    var text: String
    var confidence: Double
}

enum OCRField: String, CaseIterable, Sendable, Identifiable {
    case partNumber, invoiceReference, repairOrderReference, amount, vendorName
    var id: String { rawValue }
    var displayName: String { get }
    var coreItemField: CoreItemField { get }
}

struct OCRFieldSuggestion: Equatable, Sendable, Identifiable {
    var id: UUID
    var field: OCRField
    var value: String
    var confidence: Double
    init(field: OCRField, value: String, confidence: Double)
}

protocol TextRecognizing: Sendable {
    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine]
    func recognizeBarcodes(in imageData: Data) async throws -> [ScanResult]
}

final class VisionTextRecognizer: TextRecognizing { init() }
/// Returns caller-supplied fixtures; used by previews, unit tests, and UI tests.
final class StubTextRecognizer: TextRecognizing {
    init(lines: [String] = [], barcodes: [String] = [], error: (any Error)? = nil)
}

enum RecognitionError: LocalizedError, Equatable {
    case invalidImage, recognitionFailed(String), noTextFound
    var errorDescription: String? { get }
}

/// Pure and unit-tested. Never auto-commits — the UI shows these as editable suggestions.
enum OCRSuggestionExtractor {
    static func suggestions(from lines: [String]) -> [OCRFieldSuggestion]
    static func amountCandidates(from lines: [String]) -> [Money]
    static func referenceCandidates(from lines: [String], prefixes: [String]) -> [String]
}

// ImageProcessor.swift
struct ProcessedImage: Equatable, Sendable {
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int { data.count }
}

enum ImageProcessingError: LocalizedError, Equatable {
    case invalidImage, encodingFailed, tooLarge
    var errorDescription: String? { get }
}

enum ImageProcessor {
    /// Downsamples with ImageIO (correct orientation, no main-actor work), re-encodes as JPEG.
    static func prepare(data: Data,
                        maxDimension: CGFloat = AppConfiguration.attachmentMaxDimension,
                        quality: CGFloat = AppConfiguration.attachmentJPEGQuality) async throws -> ProcessedImage
    static func prepare(image: UIImage,
                        maxDimension: CGFloat = AppConfiguration.attachmentMaxDimension,
                        quality: CGFloat = AppConfiguration.attachmentJPEGQuality) async throws -> ProcessedImage
    static func thumbnail(from data: Data, maxDimension: CGFloat = AppConfiguration.thumbnailMaxDimension) -> UIImage?
    /// 1x1 opaque JPEG used by tests and previews so no fixture files are needed.
    static func placeholderJPEGData(width: Int, height: Int, hue: Double) -> Data
}

// QRCodeGenerator.swift + BinTag.swift
struct BinTagPayload: Codable, Equatable, Sendable {
    var version: Int
    var itemID: UUID
    var partName: String
    var partNumber: String
    var vendorName: String
    var binLabel: String
    var expectedCents: Int64
    init(item: some CoreItemRepresenting)
    /// "corecredit://item/<uuid>" — short on purpose so the QR stays scannable.
    var encodedString: String { get }
    static func itemID(fromEncodedString string: String) -> UUID?
}

enum QRCodeGenerator {
    /// CIFilter.qrCodeGenerator with .high correction, nearest-neighbour upscale.
    static func image(for payload: String, sideLength: CGFloat = 512) -> UIImage?
}

@MainActor struct BinTagRenderer {
    /// Renders a 4x6-inch label as PDF data for share/print. Never throws on empty fields.
    static func makePDFData(item: some CoreItemRepresenting, shopName: String,
                            currencyCode: String, qrImage: UIImage?) throws -> Data
}
```

### 5.3 Notifications + Exports (agent F)

```swift
// NotificationScheduling.swift
enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral, unknown
    var allowsScheduling: Bool { get }
    var explanation: String { get }
}

struct CoreReminderRequest: Equatable, Sendable {
    var itemID: UUID
    var title: String
    var body: String
    var fireDate: Date
    var identifier: String { get }          // "core-reminder-<uuid>"
    init(itemID: UUID, title: String, body: String, fireDate: Date)
}

protocol NotificationScheduling: AnyObject, Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    @discardableResult func requestAuthorization() async -> NotificationAuthorizationStatus
    func schedule(_ request: CoreReminderRequest) async throws
    func cancel(itemIDs: [UUID]) async
    func cancelAll() async
    func pendingIdentifiers() async -> [String]
}

final class UserNotificationScheduler: NotificationScheduling { init() }
/// Records calls, performs nothing. Used by UI tests and unit tests.
final class RecordingNotificationScheduler: NotificationScheduling {
    init(status: NotificationAuthorizationStatus = .authorized)
    var scheduledRequests: [CoreReminderRequest] { get }
    var cancelledIDs: [UUID] { get }
}

enum NotificationSchedulingError: LocalizedError, Equatable {
    case notAuthorized, fireDateInPast, systemError(String)
    var errorDescription: String? { get }
}

/// Pure: decides *whether* and *when* to fire. Unit-tested with FixedDateProvider.
enum ReminderPlanner {
    /// nil when: item is closed, has no due date, or the computed fire date is already past.
    static func plan(for item: some CoreItemRepresenting, leadDays: Int, hour: Int, minute: Int,
                     now: Date, calendar: Calendar, currencyCode: String) -> CoreReminderRequest?
}

@MainActor @Observable final class ReminderCoordinator {
    init(scheduler: any NotificationScheduling, dateProvider: any DateProvider)
    private(set) var authorization: NotificationAuthorizationStatus
    private(set) var lastError: String?
    func refreshAuthorization() async
    @discardableResult func requestAuthorizationIfNeeded() async -> NotificationAuthorizationStatus
    func reschedule(for item: CoreItem, profile: ShopProfile) async
    func rescheduleAll(items: [CoreItem], profile: ShopProfile) async
    func cancel(for item: CoreItem) async
    func cancelAll() async
}

// Snapshots.swift  (mapping lives in SnapshotBuilder, @MainActor)
struct CoreItemExportSnapshot: Codable, Equatable, Sendable, Identifiable, CoreItemRepresenting {
    var identifier: UUID
    var partName: String
    var partNumber: String
    var invoiceReference: String
    var repairOrderReference: String
    var creditReference: String
    var notes: String
    var binLabel: String?
    var vendorName: String?
    var vendorIdentifier: UUID?
    var status: CoreStatus
    var expectedCredit: Money
    var actualCredit: Money?
    var receivedDate: Date
    var dueDate: Date?
    var returnedDate: Date?
    var creditedDate: Date?
    var createdAt: Date
    var updatedAt: Date
    var returnBatchReference: String?
    var returnMethod: ReturnMethod?
    var events: [CoreEventSnapshot]
    var id: UUID { identifier }
}

struct CoreEventSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var timestamp: Date
    var type: CoreEventType
    var detail: String
    var amount: Money?
    var reference: String
    var fromStatus: CoreStatus?
    var toStatus: CoreStatus?
}

struct ShopProfileSnapshot: Codable, Equatable, Sendable {
    var name: String, phone: String, email: String, addressLines: [String], currencyCode: String
    static let placeholder: ShopProfileSnapshot
}

struct VendorSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: UUID, name: String, contactName: String, phone: String, email: String
    var accountNumber: String, defaultReturnWindowDays: Int, notes: String, isActive: Bool
}

struct StorageBinSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: UUID, label: String, locationNote: String, isActive: Bool
}

struct ReturnBatchSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: UUID, vendorName: String, vendorIdentifier: UUID?, returnDate: Date
    var method: ReturnMethod, reference: String, notes: String, itemIdentifiers: [UUID]
}

struct BackupPayload: Codable, Equatable, Sendable {
    var formatVersion: Int          // 1
    var appVersion: String
    var exportedAt: Date
    var shop: ShopProfileSnapshot
    var vendors: [VendorSnapshot]
    var bins: [StorageBinSnapshot]
    var items: [CoreItemExportSnapshot]
    var batches: [ReturnBatchSnapshot]
    static let currentFormatVersion = 1
}

@MainActor enum SnapshotBuilder {
    static func snapshot(_ item: CoreItem) -> CoreItemExportSnapshot
    static func snapshot(_ profile: ShopProfile) -> ShopProfileSnapshot
    static func snapshot(_ vendor: Vendor) -> VendorSnapshot
    static func snapshot(_ bin: StorageBin) -> StorageBinSnapshot
    static func snapshot(_ batch: ReturnBatch) -> ReturnBatchSnapshot
    static func backup(profile: ShopProfile, vendors: [Vendor], bins: [StorageBin],
                       items: [CoreItem], batches: [ReturnBatch], appVersion: String,
                       exportedAt: Date) -> BackupPayload
    /// Receipt/part images for the dispute packet, already downsized for PDF embedding.
    static func evidenceImages(for item: CoreItem, limit: Int) -> [(caption: String, data: Data)]
}

// Exporters
enum ExportKind: String, Codable, Sendable {
    case pdf, csv, json
    var fileExtension: String { get }
    var utTypeIdentifier: String { get }
}

struct ExportDocument: Identifiable, Equatable, Sendable {
    var id: UUID
    var url: URL
    var suggestedName: String
    var kind: ExportKind
}

enum ExportError: LocalizedError, Equatable {
    case renderingFailed(String), writeFailed(String), noData
    var errorDescription: String? { get }
}

enum ExportFileStore {
    static func directory() throws -> URL      // Caches/CoreCreditExports, created if needed
    static func write(_ data: Data, baseName: String, kind: ExportKind) throws -> ExportDocument
    static func cleanUpOldExports(olderThan interval: TimeInterval = AppConfiguration.exportRetention)
    static func sanitizedFileName(_ raw: String) -> String
}

/// Pure string building so it is unit-testable. RFC4180 quoting. Amounts use plainDecimalString.
enum CSVLedgerExporter {
    static let headerRow: [String]
    static func makeCSV(items: [CoreItemExportSnapshot], currencyCode: String) -> String
    static func escape(_ field: String) -> String
}

enum JSONBackupExporter {
    static func encode(_ payload: BackupPayload) throws -> Data      // ISO8601 dates, sorted keys, pretty
    static func decode(_ data: Data) throws -> BackupPayload
}

@MainActor enum DisputePacketBuilder {
    /// UIGraphicsPDFRenderer, US Letter, multi-page. Includes shop + vendor + item detail,
    /// expected vs actual, discrepancy summary, status timeline, dates, notes, and photos.
    static func makePDFData(item: CoreItemExportSnapshot, shop: ShopProfileSnapshot,
                            images: [(caption: String, data: Data)], generatedAt: Date) throws -> Data
    static func makeLedgerPDFData(items: [CoreItemExportSnapshot], shop: ShopProfileSnapshot,
                                  summary: RiskSummary, generatedAt: Date) throws -> Data
}

@MainActor @Observable final class ExportCoordinator {
    init(dateProvider: any DateProvider)
    private(set) var inFlight: Bool
    private(set) var lastError: String?
    var presentedDocument: ExportDocument?
    func exportDisputePacket(for item: CoreItem, profile: ShopProfile) async
    func exportCSVLedger(items: [CoreItem], profile: ShopProfile) async
    func exportJSONBackup(profile: ShopProfile, vendors: [Vendor], bins: [StorageBin],
                          items: [CoreItem], batches: [ReturnBatch]) async
    func exportBinTag(for item: CoreItem, profile: ShopProfile) async
    func dismiss()
}
```

---

## 6. Components + design tokens — `CoreCredit/Components/` (Phase 1 agent C)

```swift
// Palette.swift
enum Palette {
    static let background: Color          // near-black navy in dark, off-white in light
    static let surface: Color
    static let surfaceElevated: Color
    static let hairline: Color
    static let textPrimary: Color
    static let textSecondary: Color
    static let accent: Color              // restrained amber — warnings / "ready to return"
    static let positive: Color            // green — confirmed credits ONLY
    static let danger: Color              // red — overdue / disputed ONLY
    static let neutral: Color             // graphite — awaiting / returned
    static let muted: Color               // written off

    static func color(for status: CoreStatus) -> Color
    static func onColor(for status: CoreStatus) -> Color   // readable foreground on that color
}

// Typography.swift
enum Typography {
    static let hero: Font           // .system(.largeTitle, design: .rounded, weight: .bold)
    static let money: Font          // monospaced digits
    static let sectionTitle: Font
    static let rowTitle: Font
    static let caption: Font
}

// Spacing.swift
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let minimumTapTarget: CGFloat = 44
    static let cornerRadius: CGFloat = 12
}

// Views
struct StatusBadge: View {
    init(status: CoreStatus, isOverdue: Bool = false, compact: Bool = false)
}

enum MoneyLabelStyle { case hero, prominent, row, caption }
struct MoneyLabel: View {
    init(_ money: Money, currencyCode: String, style: MoneyLabelStyle = .row,
         emphasizeNegative: Bool = false)
}

struct CurrencyTextField: View {
    init(title: String, text: Binding<String>, currencyCode: String,
         errorMessage: String? = nil, focusHint: String? = nil)
}

struct FormErrorText: View { init(_ message: String?) }

struct EmptyStateView: View {
    init(symbol: String, title: String, message: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil)
}

struct ErrorBanner: View {
    init(message: String, retryTitle: String? = nil, onRetry: (() -> Void)? = nil,
         onDismiss: (() -> Void)? = nil)
}

struct SectionCard<Content: View>: View {
    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content)
}

struct StatTile: View {
    init(title: String, value: String, symbol: String, tint: Color,
         caption: String? = nil, accessibilityValue: String? = nil, action: (() -> Void)? = nil)
}

struct LabeledValueRow: View {
    init(_ label: String, value: String, symbol: String? = nil, isMonospaced: Bool = false)
}

struct AttachmentThumbnail: View { init(attachment: Attachment, size: CGFloat = 72) }
struct AttachmentStrip: View {
    init(attachments: [Attachment], onSelect: ((Attachment) -> Void)? = nil,
         onDelete: ((Attachment) -> Void)? = nil)
}

struct PrimaryButtonLabel: View { init(_ title: String, systemImage: String? = nil) }

struct DestructiveConfirmButton: View {
    init(title: String, confirmationTitle: String, message: String, action: @escaping () -> Void)
}

struct LoadingOverlay: View { init(message: String) }

// AccessibilityIdentifiers.swift — shared by app + UI tests. UI tests import these strings verbatim.
enum A11y {
    enum Tab { static let dashboard = "tab.dashboard"; static let cores = "tab.cores"
               static let returns = "tab.returns"; static let settings = "tab.settings" }
    enum Dashboard { static let moneyAtRisk = "dashboard.moneyAtRisk"
                     static let overdueAmount = "dashboard.overdueAmount"
                     static let addCore = "dashboard.addCore"
                     static let root = "dashboard.root" }
    enum Cores { static let root = "cores.root"; static let list = "cores.list"
                 static let addButton = "cores.add"
                 static func row(_ id: UUID) -> String { "cores.row." + id.uuidString } }
    // NOTE: there is deliberately no `Cores.searchField`. SwiftUI's `.searchable` injects the
    // field into the navigation bar, so an identifier applied to the modified view lands on that
    // view, never on the field. UI tests use `app.searchFields.firstMatch`.
    enum Editor { static let partName = "editor.partName"; static let partNumber = "editor.partNumber"
                  static let amount = "editor.amount"; static let vendor = "editor.vendor"
                  static let bin = "editor.bin"; static let invoice = "editor.invoice"
                  static let repairOrder = "editor.repairOrder"; static let save = "editor.save"
                  static let cancel = "editor.cancel"; static let scan = "editor.scan" }
    enum Detail { static let root = "detail.root"; static let status = "detail.status"
                  static let markReady = "detail.markReady"; static let recordCredit = "detail.recordCredit"
                  static let exportPacket = "detail.exportPacket"; static let binTag = "detail.binTag" }
    enum Returns { static let root = "returns.root"
                   static let reference = "returns.reference"        // create-batch sheet
                   static let editReference = "returns.editReference" // batch detail, while editing
                   static let confirm = "returns.confirm"
                   static let awaitingCredit = "returns.awaitingCredit"
                   // Rendered once per ready vendor group, so it must be keyed per vendor.
                   static func createBatch(vendor name: String) -> String { "returns.createBatch." + name } }
    enum Credit { static let amount = "credit.amount"; static let reference = "credit.reference"
                  static let save = "credit.save" }
    enum Paywall { static let root = "paywall.root"; static let monthly = "paywall.monthly"
                   static let annual = "paywall.annual"; static let restore = "paywall.restore"
                   static let close = "paywall.close" }
    enum Settings { static let root = "settings.root"; static let vendors = "settings.vendors"
                    static let addVendor = "settings.addVendor"; static let vendorName = "settings.vendorName"
                    static let vendorWindow = "settings.vendorWindow"; static let vendorSave = "settings.vendorSave"
                    static let subscription = "settings.subscription"        // the Settings row
                    static let subscriptionScreen = "settings.subscriptionScreen" // the screen it pushes
                    static let exportCSV = "settings.exportCSV" }
    enum Onboarding { static let root = "onboarding.root"; static let next = "onboarding.next"
                      static let shopName = "onboarding.shopName"; static let finish = "onboarding.finish"
                      static let skip = "onboarding.skip" }
}
```

---

## 7. App shell — `CoreCredit/App/` (Phase 3 agent I)

```swift
struct LaunchOptions: Equatable, Sendable {
    var isUITesting: Bool
    var useInMemoryStore: Bool
    var seedScenario: SeedScenario
    var forcedTier: SubscriptionTier?
    var simulateStoreKitFailure: Bool
    var disableAnimations: Bool
    var disableNotifications: Bool
    var stubScannerPayload: String?
    var skipOnboarding: Bool
    static let `default`: LaunchOptions
    static func parse(_ arguments: [String] = ProcessInfo.processInfo.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions
}

enum SeedScenario: String, Sendable {
    case none            // -uiTestSeed none
    case empty
    case fiveUnresolved  // exactly at the free limit
    case walkthrough     // NAPA / Alternator acceptance fixture
}

@MainActor @Observable final class AppEnvironment {
    let launchOptions: LaunchOptions
    let dateProvider: any DateProvider
    /// nil when the persistent store could not be opened at all — RootView then renders
    /// `StoreUnavailableView(message:onRetry:onReset:)` instead of the tab bar.
    let container: ModelContainer?
    let subscriptions: SubscriptionController
    let reminders: ReminderCoordinator
    let exports: ExportCoordinator
    let textRecognizer: any TextRecognizing
    var storeLoadWarning: String?
    var pendingPaywallTrigger: PaywallTrigger?

    init(launchOptions: LaunchOptions)
    func bootstrap() async
    func itemService(_ context: ModelContext) -> CoreItemService
    func batchService(_ context: ModelContext) -> ReturnBatchService
}

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard, cores, returns, settings
    var id: String { rawValue }
    var title: String { get }
    var symbolName: String { get }
    var accessibilityIdentifier: String { get }
}

@main struct CoreCreditApp: App { }

struct RootView: View { }              // decides StoreUnavailable vs Onboarding vs MainTabView
struct MainTabView: View { }           // TabView on compact, NavigationSplitView on regular

/// Shown only when `AppEnvironment.container == nil`.
struct StoreUnavailableView: View {
    init(message: String, onRetry: @escaping () -> Void, onReset: @escaping () -> Void)
}
```

Launch arguments consumed by `LaunchOptions.parse`:

| Argument | Effect |
|---|---|
| `-uiTesting` | in-memory store, stub scanner/notifications/StoreKit, animations off |
| `-uiTestSeed <none\|empty\|fiveUnresolved\|walkthrough>` | seeds the in-memory store |
| `-uiTestTier <free\|pro>` | forces the stub entitlement |
| `-uiTestStoreKitFailure` | `StubSubscriptionEngine(simulateLoadFailure: true)` |
| `-uiTestScannerPayload <string>` | manual-entry field pre-filled / stub scan result |
| `-uiTestSkipOnboarding` | marks the seeded profile as onboarded |

---

## 8. Feature view names (Phase 3)

Agents must use exactly these type names so cross-feature navigation compiles.

```
Features/Onboarding/OnboardingView.swift          -> struct OnboardingView: View
                    OnboardingViewModel.swift     -> @MainActor @Observable final class OnboardingModel
Features/Dashboard/DashboardView.swift            -> struct DashboardView: View
                   DashboardModel.swift           -> @MainActor @Observable final class DashboardModel
                   DashboardSection.swift         -> struct MoneyAtRiskHeader, StatusCardGrid, AgingBucketRow
Features/Cores/CoreListView.swift                 -> struct CoreListView: View
               CoreListModel.swift                -> @MainActor @Observable final class CoreListModel
               CoreRowView.swift                  -> struct CoreRowView: View
               CoreFilterSheet.swift              -> struct CoreFilterSheet: View
               CoreDetailView.swift               -> struct CoreDetailView: View
               CoreDetailModel.swift              -> @MainActor @Observable final class CoreDetailModel
               CoreTimelineView.swift             -> struct CoreTimelineView: View
Features/Capture/CoreEditorView.swift             -> struct CoreEditorView: View
                 CoreEditorModel.swift            -> @MainActor @Observable final class CoreEditorModel
                 ScanSheet.swift                  -> struct ScanSheet: View
                 ScanReviewSheet.swift            -> struct ScanReviewSheet: View
                 OCRReviewSheet.swift             -> struct OCRReviewSheet: View
                 AttachmentPickerSheet.swift      -> struct AttachmentPickerSheet: View
                 BinTagSheet.swift                -> struct BinTagSheet: View
Features/Returns/ReturnsView.swift                -> struct ReturnsView: View
                 ReturnsModel.swift               -> @MainActor @Observable final class ReturnsModel
                 CreateBatchSheet.swift           -> struct CreateBatchSheet: View
                 BatchDetailView.swift            -> struct BatchDetailView: View
                 RecordCreditSheet.swift          -> struct RecordCreditSheet: View
Features/Settings/SettingsView.swift              -> struct SettingsView: View
                  ShopProfileEditor.swift         -> struct ShopProfileEditor: View
                  VendorListView.swift            -> struct VendorListView: View
                  VendorEditorView.swift          -> struct VendorEditorView: View
                  BinListView.swift               -> struct BinListView: View
                  NotificationSettingsView.swift  -> struct NotificationSettingsView: View
                  DataSettingsView.swift          -> struct DataSettingsView: View
                  AboutView.swift                 -> struct AboutView: View
Features/Paywall/PaywallView.swift                -> struct PaywallView: View
                 SubscriptionStatusView.swift     -> struct SubscriptionStatusView: View
```

`CoreEditorView` init: `init(mode: CoreEditorMode)` where
`enum CoreEditorMode: Equatable { case create, edit(CoreItem) }`.
`RecordCreditSheet` init: `init(item: CoreItem)`.
`CreateBatchSheet` init: `init(vendor: Vendor?, preselected: [CoreItem])`.
`PaywallView` init: `init(trigger: PaywallTrigger)`.
`CoreDetailView` init: `init(item: CoreItem)`.

Environment access inside features:

```swift
@Environment(AppEnvironment.self) private var appEnvironment
@Environment(\.modelContext) private var modelContext
```

The shop profile is fetched with `@Query private var profiles: [ShopProfile]` and the first element
is used, falling back to a locally constructed default for display only.

---

## 9. SF Symbols (fixed, so icons stay consistent)

| Concept | Symbol |
|---|---|
| awaitingCore | `shippingbox` |
| readyToReturn | `arrow.uturn.left.circle` |
| returnedAwaitingCredit | `clock.arrow.circlepath` |
| credited | `checkmark.seal` |
| disputed | `exclamationmark.triangle` |
| writtenOff | `xmark.bin` |
| overdue | `exclamationmark.circle` |
| money at risk | `dollarsign.circle` |
| dashboard tab | `gauge.with.dots.needle.bottom.50percent` |
| cores tab | `shippingbox.fill` |
| returns tab | `arrow.uturn.left` |
| settings tab | `gearshape` |
| vendor | `building.2` |
| bin | `tray.full` |
| scan | `barcode.viewfinder` |
| photo | `camera` |
| export | `square.and.arrow.up` |
| QR tag | `qrcode` |
