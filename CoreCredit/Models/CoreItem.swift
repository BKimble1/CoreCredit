import Foundation
import SwiftData

/// One tracked core charge: the part that was replaced, the money the vendor is holding,
/// and where that money currently is in its lifecycle.
///
/// Money is persisted as `Int64` cents — never `Double` — and surfaced through the `Money`
/// value type. Status is persisted as its raw `String` so an unknown value written by a future
/// build decodes to `.awaitingCore` instead of failing to load the store.
///
/// `attachments` and `events` cascade: deleting a core item deletes its photos and its timeline,
/// but never its vendor or bin.
@Model
final class CoreItem {
    var id: UUID = UUID()
    var partName: String = ""
    var partNumber: String = ""

    /// The exact payload as the scanner reported it, before any normalisation.
    /// Kept apart from `partNumber` so a scan can never overwrite a confirmed value.
    var scannedBarcodeValue: String?

    /// `VNBarcodeSymbology.rawValue` for the payload above.
    var scannedBarcodeSymbology: String?

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

    /// Creates a core item in `.awaitingCore`.
    ///
    /// `dueDate` is deliberately left `nil` here: the due date depends on the vendor's return
    /// window *and* an injected calendar, so it is computed by `CoreItemService` (or explicitly
    /// by the seeding helpers) rather than guessed inside the model.
    ///
    /// The scanned-barcode fields are likewise left `nil`: they are written by `CoreItemService`
    /// only when a draft actually carries a scanned payload. Keeping them out of the parameter
    /// list means every existing call site of this initialiser is unchanged.
    init(partName: String,
         expectedCredit: Money,
         receivedDate: Date,
         vendor: Vendor? = nil,
         bin: StorageBin? = nil,
         now: Date = Date()) {
        self.id = UUID()
        self.partName = partName
        self.partNumber = ""
        self.scannedBarcodeValue = nil
        self.scannedBarcodeSymbology = nil
        self.expectedCreditCents = expectedCredit.cents
        self.actualCreditCents = nil
        self.invoiceReference = ""
        self.repairOrderReference = ""
        self.creditReference = ""
        self.statusRawValue = CoreStatus.awaitingCore.rawValue
        self.receivedDate = receivedDate
        self.dueDate = nil
        self.usesCustomDueDate = false
        self.returnedDate = nil
        self.creditedDate = nil
        self.notes = ""
        self.createdAt = now
        self.updatedAt = now
        self.vendor = vendor
        self.bin = bin
        self.returnBatch = nil
        self.attachments = []
        self.events = []
    }

    // MARK: - Typed accessors

    /// Typed view over `statusRawValue`. Unknown raw values decode to `.awaitingCore`.
    var status: CoreStatus {
        get { CoreStatus.decoded(fromRawValue: statusRawValue) }
        set { statusRawValue = newValue.rawValue }
    }

    /// Typed view over `expectedCreditCents`.
    var expectedCredit: Money {
        get { Money(cents: expectedCreditCents) }
        set { expectedCreditCents = newValue.cents }
    }

    /// Typed view over `actualCreditCents`. `nil` means no credit has been recorded yet.
    var actualCredit: Money? {
        get {
            guard let cents = actualCreditCents else { return nil }
            return Money(cents: cents)
        }
        set { actualCreditCents = newValue?.cents }
    }

    /// Attachments in capture order, oldest first.
    var photos: [Attachment] {
        (attachments ?? []).sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Append-only event history, oldest first.
    var timeline: [CoreEvent] {
        (events ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// The part name, or a neutral placeholder when it is blank.
    var displayTitle: String {
        let trimmed = partName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled core" : trimmed
    }

    /// Stamps `updatedAt`.
    func touch(_ now: Date) {
        updatedAt = now
    }
}

// MARK: - CoreItemRepresenting

/// Lets the pure domain calculators, filters, and exporters work against `CoreItem` without
/// importing SwiftData. Blank vendor/bin text is mapped to `nil` so "no vendor" and
/// "a vendor with an empty name" read the same way downstream.
extension CoreItem: CoreItemRepresenting {
    var identifier: UUID { id }

    var binLabel: String? {
        guard let value = bin?.label else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var vendorName: String? {
        guard let value = vendor?.name else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var vendorIdentifier: UUID? { vendor?.id }
}
