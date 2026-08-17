import Foundation
import SwiftData

/// How a batch of cores physically left the shop.
enum ReturnMethod: String, CaseIterable, Codable, Sendable, Identifiable {
    case driverPickup
    case counterDropOff
    case shipped
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .driverPickup: return "Driver pickup"
        case .counterDropOff: return "Counter drop-off"
        case .shipped: return "Shipped"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .driverPickup: return "car"
        case .counterDropOff: return "building.2"
        case .shipped: return "shippingbox"
        case .other: return "ellipsis.circle"
        }
    }

    /// Safe decoding for values written by a future version. Unknown -> `.other`.
    static func decoded(fromRawValue rawValue: String) -> ReturnMethod {
        ReturnMethod(rawValue: rawValue) ?? .other
    }
}

/// A physical hand-off of one or more cores back to a single vendor.
///
/// A batch is always single-vendor: `ReturnBatchService.createBatch` rejects mixed-vendor lists
/// so the vendor's credit memo can be reconciled against exactly one batch.
///
/// `items` uses `.nullify` — deleting a batch detaches its cores and leaves their status alone.
/// `attachments` (return receipts) cascade with the batch.
@Model
final class ReturnBatch {
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

    init(vendor: Vendor?,
         returnDate: Date,
         method: ReturnMethod,
         reference: String = "",
         now: Date = Date()) {
        self.id = UUID()
        self.returnDate = returnDate
        self.methodRawValue = method.rawValue
        self.reference = reference
        self.notes = ""
        self.createdAt = now
        self.updatedAt = now
        self.closedAt = nil
        self.vendor = vendor
        self.items = []
        self.attachments = []
    }

    // MARK: - Typed accessors

    /// Typed view over `methodRawValue`. Unknown raw values decode to `.other`.
    var method: ReturnMethod {
        get { ReturnMethod.decoded(fromRawValue: methodRawValue) }
        set { methodRawValue = newValue.rawValue }
    }

    /// The cores in this batch, ordered by part name for a stable on-screen list.
    var coreItems: [CoreItem] {
        (items ?? []).sorted { lhs, rhs in
            let comparison = lhs.partName.localizedCaseInsensitiveCompare(rhs.partName)
            if comparison == .orderedSame {
                return lhs.createdAt < rhs.createdAt
            }
            return comparison == .orderedAscending
        }
    }

    /// Return receipts photographed at drop-off, oldest first.
    var receipts: [Attachment] {
        (attachments ?? []).sorted { $0.capturedAt < $1.capturedAt }
    }

    var itemCount: Int {
        (items ?? []).count
    }

    /// Sum of every included core's expected credit.
    var totalExpectedCredit: Money {
        (items ?? []).reduce(Money.zero) { partial, item in
            partial + item.expectedCredit
        }
    }

    /// Sum of the money still genuinely at risk across the batch.
    var outstandingCredit: Money {
        (items ?? []).reduce(Money.zero) { partial, item in
            partial + RiskCalculator.remainingExposure(for: item)
        }
    }

    /// True only when the batch has cores and every one of them reached `.credited`.
    ///
    /// Deliberately stricter than "no money outstanding". **A written-off core does NOT count as
    /// settled**: writing one off zeroes its remaining exposure, but the shop never got that money
    /// back, so a batch containing one must not read as fully credited. An empty batch is false.
    var isFullyCredited: Bool {
        let members = items ?? []
        guard !members.isEmpty else { return false }
        return members.allSatisfy { $0.status == .credited }
    }

    /// "NAPA — 3 cores"
    var displayTitle: String {
        let vendorPart = vendor?.displayName ?? "Unknown vendor"
        let count = itemCount
        let noun = count == 1 ? "core" : "cores"
        return vendorPart + " — " + String(count) + " " + noun
    }

    /// Stamps `updatedAt`.
    func touch(_ now: Date) {
        updatedAt = now
    }
}
