import Foundation
import SwiftData

/// Where the write path announces that something in the ledger changed.
///
/// # Why this exists
///
/// Reminders have to be re-planned after every write, but `CoreItemService` must not know that
/// notifications exist — it is the audited mutation path, not a scheduling layer, and pulling
/// `UserNotifications` into it would make every test that saves a core drag the notification centre
/// along with it. So the service posts a bare "the ledger changed, here is the context it changed
/// in" and stops caring. `ReminderCoordinator` is the listener, and it is the only side of this
/// that touches notifications.
///
/// # One listener
///
/// The relay holds a single observer, claimed by whichever `ReminderCoordinator` was created last.
/// The app creates exactly one, in `AppEnvironment.init`, so in practice there is no contention.
/// A caller that wants none of this hands `CoreItemService` a freshly built relay: nobody is
/// subscribed to it, so every announcement it receives goes nowhere.
@MainActor
final class CoreItemChangeRelay {

    /// The instance `CoreItemService` uses unless a caller injects another.
    static let shared = CoreItemChangeRelay()

    private var observer: ((ModelContext) -> Void)?

    init() {}

    /// Replaces the current observer.
    func setObserver(_ observer: ((ModelContext) -> Void)?) {
        self.observer = observer
    }

    func removeObserver() {
        observer = nil
    }

    /// Announces a change. A no-op when nothing is listening — nothing is ever buffered, because a
    /// change that nobody was listening for is one the next full refresh will read out of the store
    /// anyway.
    func post(_ context: ModelContext) {
        observer?(context)
    }
}

/// Every write to a `CoreItem` goes through here.
///
/// The reason this type exists is the audit trail: a core's timeline is the evidence a shop shows
/// a vendor when a credit is short. If a view could mutate a `CoreItem` directly, a status change
/// could land with no matching `CoreEvent` and the timeline would silently lie. So this service —
/// and `ReturnBatchService`, which delegates its event writing here — owns all mutation, and every
/// mutating method appends the appropriate event before saving.
///
/// The clock is injected so due dates and event timestamps are deterministic under test.
@MainActor
struct CoreItemService {
    let context: ModelContext
    let dateProvider: any DateProvider

    /// The relay this service announces through, or `nil` for the app-wide one.
    ///
    /// This is the *only* connection between the write path and notifications, and it points the
    /// harmless way round: the service knows about a relay that takes a `ModelContext`, not about
    /// `UserNotifications`, `ReminderCoordinator`, or `ShopProfile.remindersEnabled`. Hand in a
    /// freshly built `CoreItemChangeRelay` — one nobody has subscribed to — to keep a test's writes
    /// entirely to itself.
    private let injectedChangeRelay: CoreItemChangeRelay?

    init(context: ModelContext,
         dateProvider: any DateProvider = SystemDateProvider(),
         changeRelay: CoreItemChangeRelay? = nil) {
        self.context = context
        self.dateProvider = dateProvider
        self.injectedChangeRelay = changeRelay
    }

    /// Where a completed write is announced.
    var changeRelay: CoreItemChangeRelay {
        injectedChangeRelay ?? CoreItemChangeRelay.shared
    }

    // MARK: - Queries

    /// Every core item, newest first.
    func allItems() throws -> [CoreItem] {
        let descriptor = FetchDescriptor<CoreItem>(
            sortBy: [SortDescriptor(\CoreItem.createdAt, order: .reverse)]
        )
        return try fetching(descriptor)
    }

    /// Number of items that still represent money the shop has not got back.
    ///
    /// Credited and written-off items are closed and deliberately excluded — the free-tier limit
    /// counts open obligations, not lifetime volume, so settling a core frees a slot.
    func unresolvedCount() throws -> Int {
        try allItems().reduce(into: 0) { total, item in
            if item.status.isUnresolved { total += 1 }
        }
    }

    func item(with id: UUID) throws -> CoreItem? {
        let targetID = id
        var descriptor = FetchDescriptor<CoreItem>(
            predicate: #Predicate<CoreItem> { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        return try fetching(descriptor).first
    }

    /// Vendors sorted by name. Inactive vendors are hidden unless explicitly requested.
    func allVendors(includeInactive: Bool) throws -> [Vendor] {
        let vendors = try fetching(FetchDescriptor<Vendor>())
        var visible = vendors
        if !includeInactive {
            visible = vendors.filter({ $0.isActive })
        }
        return visible.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame { return lhs.createdAt < rhs.createdAt }
            return comparison == .orderedAscending
        }
    }

    /// Bins sorted by label. Inactive bins are hidden unless explicitly requested.
    func allBins(includeInactive: Bool) throws -> [StorageBin] {
        let bins = try fetching(FetchDescriptor<StorageBin>())
        var visible = bins
        if !includeInactive {
            visible = bins.filter({ $0.isActive })
        }
        return visible.sorted { lhs, rhs in
            let comparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
            if comparison == .orderedSame { return lhs.createdAt < rhs.createdAt }
            return comparison == .orderedAscending
        }
    }

    /// The single shop profile, created and inserted on first call so callers never see `nil`.
    func shopProfile() throws -> ShopProfile {
        let descriptor = FetchDescriptor<ShopProfile>(
            sortBy: [SortDescriptor(\ShopProfile.createdAt, order: .forward)]
        )
        let existing = try fetching(descriptor)
        if let profile = existing.first {
            return profile
        }
        let profile = ShopProfile(now: dateProvider.now)
        context.insert(profile)
        try persist()
        return profile
    }

    // MARK: - Item mutations

    /// Validates the draft, computes the due date, inserts the item, and opens its timeline
    /// with a `.created` event.
    @discardableResult
    func createItem(from draft: CoreItemDraft, vendor: Vendor?, bin: StorageBin?) throws -> CoreItem {
        let calendar = dateProvider.calendar
        let issues = CoreItemValidator.validate(draft, calendar: calendar)
        guard issues.isEmpty else { throw DomainError.validationFailed(issues) }
        guard let amount = draft.expectedCredit else {
            throw DomainError.validationFailed([
                ValidationIssue(field: .expectedCredit,
                                message: "Enter the core charge, for example 86.50.")
            ])
        }

        let now = dateProvider.now
        let item = CoreItem(partName: draft.trimmedPartName,
                            expectedCredit: amount,
                            receivedDate: draft.receivedDate,
                            vendor: vendor,
                            bin: bin,
                            now: now)
        apply(draft, to: item, amount: amount, vendor: vendor, bin: bin, calendar: calendar)
        let scannedPayload = applyScannedBarcode(from: draft, to: item)
        item.createdAt = now
        item.touch(now)
        context.insert(item)

        appendEvent(.created,
                    to: item,
                    detail: "Logged " + item.displayTitle + ".",
                    amount: amount,
                    reference: item.invoiceReference,
                    fromStatus: nil,
                    toStatus: item.status)

        recordScannedBarcodeEvent(payload: scannedPayload,
                                  symbology: draft.scannedBarcodeSymbology,
                                  on: item)

        try persist()
        return item
    }

    /// Re-validates and rewrites an existing item, then appends an `.edited` event.
    /// Status, returned/credited dates, and the batch membership are not touched here — those
    /// only move through `transition`, `recordCredit`, and `ReturnBatchService`.
    func update(_ item: CoreItem, from draft: CoreItemDraft, vendor: Vendor?, bin: StorageBin?) throws {
        let calendar = dateProvider.calendar
        let issues = CoreItemValidator.validate(draft, calendar: calendar)
        guard issues.isEmpty else { throw DomainError.validationFailed(issues) }
        guard let amount = draft.expectedCredit else {
            throw DomainError.validationFailed([
                ValidationIssue(field: .expectedCredit,
                                message: "Enter the core charge, for example 86.50.")
            ])
        }

        apply(draft, to: item, amount: amount, vendor: vendor, bin: bin, calendar: calendar)
        let scannedPayload = applyScannedBarcode(from: draft, to: item)
        item.touch(dateProvider.now)

        appendEvent(.edited,
                    to: item,
                    detail: "Core details updated.",
                    amount: amount,
                    reference: item.invoiceReference,
                    fromStatus: nil,
                    toStatus: nil)

        recordScannedBarcodeEvent(payload: scannedPayload,
                                  symbology: draft.scannedBarcodeSymbology,
                                  on: item)

        try persist()
    }

    /// Moves an item to a new status.
    ///
    /// The move must be legal per `CoreStatusMachine` (which rejects same-to-same), so this is the
    /// safe entry point for every user-driven status change in the UI.
    func transition(_ item: CoreItem, to status: CoreStatus, detail: String?) throws {
        let from = item.status
        try CoreStatusMachine.validate(from: from, to: status)

        let now = dateProvider.now
        item.status = status

        if status == .returnedAwaitingCredit {
            // Entering "returned" stamps the hand-off date, but never overwrites a real one.
            if item.returnedDate == nil { item.returnedDate = now }
        } else if from == .returnedAwaitingCredit,
                  status == .readyToReturn || status == .awaitingCore {
            // Stepping backwards out of "returned" means it never actually went back.
            item.returnedDate = nil
        }

        item.touch(now)

        let describedChange = from.displayName + " → " + status.displayName
        appendEvent(.statusChanged,
                    to: item,
                    detail: detail ?? describedChange,
                    amount: nil,
                    reference: "",
                    fromStatus: from,
                    toStatus: status)

        try persist()
    }

    /// Records the vendor's credit memo and reconciles it against what was expected.
    ///
    /// Legal only from `.returnedAwaitingCredit` and `.disputed`. The resulting status is set
    /// directly rather than through `CoreStatusMachine.validate`, because re-recording a still-short
    /// credit on an already-disputed item is a same-to-same move the machine would reject.
    @discardableResult
    func recordCredit(_ item: CoreItem, reconciliation: CreditReconciliation) throws -> CreditOutcome {
        let from = item.status
        guard from == .returnedAwaitingCredit || from == .disputed else {
            throw DomainError.invalidTransition(from: from, to: .credited)
        }

        let outcome = CreditReconciler.outcome(expected: item.expectedCredit,
                                               actual: reconciliation.amount)
        let resulting = CreditReconciler.resultingStatus(for: outcome)

        item.actualCredit = reconciliation.amount
        item.creditedDate = reconciliation.creditDate
        item.creditReference = reconciliation.reference
        item.status = resulting
        item.touch(dateProvider.now)

        appendEvent(.creditRecorded,
                    to: item,
                    detail: "Vendor credit recorded.",
                    amount: reconciliation.amount,
                    reference: reconciliation.reference,
                    fromStatus: from,
                    toStatus: resulting)

        if case .short(let difference) = outcome {
            appendEvent(.disputeOpened,
                        to: item,
                        detail: "Credit came up short.",
                        amount: difference,
                        reference: reconciliation.reference,
                        fromStatus: from,
                        toStatus: resulting)
        }

        try persist()
        return outcome
    }

    /// Undoes `recordCredit`: clears the recorded amount, date, and reference, and puts a
    /// credited or disputed item back into `.returnedAwaitingCredit`.
    func clearRecordedCredit(_ item: CoreItem) throws {
        let from = item.status
        item.actualCredit = nil
        item.creditedDate = nil
        item.creditReference = ""

        var resultingStatus: CoreStatus? = nil
        if from == .credited || from == .disputed {
            item.status = .returnedAwaitingCredit
            resultingStatus = .returnedAwaitingCredit
            if item.returnedDate == nil { item.returnedDate = dateProvider.now }
        }

        item.touch(dateProvider.now)

        appendEvent(.reopened,
                    to: item,
                    detail: "Recorded credit cleared.",
                    amount: nil,
                    reference: "",
                    fromStatus: from,
                    toStatus: resultingStatus)

        try persist()
    }

    /// Gives up on a core. Rejected when the current status has no legal path to `.writtenOff`.
    func writeOff(_ item: CoreItem, reason: String) throws {
        let from = item.status
        if from != .writtenOff {
            try CoreStatusMachine.validate(from: from, to: .writtenOff)
            item.status = .writtenOff
        }
        item.touch(dateProvider.now)

        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        appendEvent(.writtenOff,
                    to: item,
                    detail: trimmedReason.isEmpty ? "Written off." : trimmedReason,
                    amount: item.expectedCredit,
                    reference: "",
                    fromStatus: from,
                    toStatus: .writtenOff)

        try persist()
    }

    func addAttachment(_ attachment: Attachment, to item: CoreItem) throws {
        context.insert(attachment)
        attachment.coreItem = item
        item.touch(dateProvider.now)

        appendEvent(.photoAdded,
                    to: item,
                    detail: attachment.kind.displayName + " photo added.",
                    amount: nil,
                    reference: "",
                    fromStatus: nil,
                    toStatus: nil)

        try persist()
    }

    func removeAttachment(_ attachment: Attachment, from item: CoreItem) throws {
        let kindName = attachment.kind.displayName
        attachment.coreItem = nil
        context.delete(attachment)
        item.touch(dateProvider.now)

        appendEvent(.photoRemoved,
                    to: item,
                    detail: kindName + " photo removed.",
                    amount: nil,
                    reference: "",
                    fromStatus: nil,
                    toStatus: nil)

        try persist()
    }

    // MARK: - Scanned barcode

    /// Forgets the raw barcode payload recorded against this core.
    ///
    /// # Why this is a service method and not a property assignment
    ///
    /// `scannedBarcodeValue` is evidence: it is the exact string a scanner read, kept deliberately
    /// apart from `partNumber` so that "did it misread it, or did somebody change it?" stays
    /// answerable months later. Removing evidence is a mutation like any other and belongs in the
    /// append-only timeline, so it goes through here rather than being assigned from a view.
    ///
    /// Recorded as `.edited` rather than a new event type. Adding a case to `CoreEventType` would
    /// break every exhaustive switch over it and change a persisted raw value, which is a large
    /// change to make for one line of audit text; `.edited` already means "a field on this record
    /// was changed by hand", which is exactly what happened.
    ///
    /// The confirmed `partNumber` is never touched. Clearing the payload does not clear the part
    /// number, and it never promotes the payload into it.
    ///
    /// Does nothing at all when there is no payload, so a double tap cannot write a second event.
    func clearScannedBarcode(_ item: CoreItem) throws {
        guard let payload = item.scannedBarcodeValue, payload.isEmpty == false else { return }

        item.scannedBarcodeValue = nil
        item.scannedBarcodeSymbology = nil
        item.touch(dateProvider.now)

        appendEvent(.edited,
                    to: item,
                    detail: "Scanned barcode cleared: " + payload,
                    amount: nil,
                    reference: "",
                    fromStatus: nil,
                    toStatus: nil)

        try persist()
    }

    /// Deletes the item and its cascaded attachments and events. The vendor and bin survive.
    func delete(_ item: CoreItem) throws {
        item.vendor = nil
        item.bin = nil
        item.returnBatch = nil
        context.delete(item)
        try persist()
    }

    /// Recomputes the due date from the current vendor window. A no-op for items whose owner
    /// pinned a custom due date. Does not save — callers batch this with another mutation.
    func recalculateDueDate(for item: CoreItem) {
        guard !item.usesCustomDueDate else { return }
        let windowDays = item.vendor?.defaultReturnWindowDays
            ?? AppConfiguration.defaultVendorReturnWindowDays
        item.dueDate = DueDateCalculator.dueDate(receivedDate: item.receivedDate,
                                                 windowDays: windowDays,
                                                 calendar: dateProvider.calendar)
    }

    // MARK: - Vendors, bins, profile

    @discardableResult
    func createVendor(name: String, returnWindowDays: Int) throws -> Vendor {
        let now = dateProvider.now
        let vendor = Vendor(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            defaultReturnWindowDays: DueDateCalculator.clampWindowDays(returnWindowDays),
                            now: now)
        context.insert(vendor)
        try persist()
        return vendor
    }

    /// Persists in-place edits to a vendor. Due dates of its open items are refreshed so a
    /// changed return window takes effect immediately.
    func updateVendor(_ vendor: Vendor) throws {
        vendor.defaultReturnWindowDays = DueDateCalculator.clampWindowDays(vendor.defaultReturnWindowDays)
        vendor.touch(dateProvider.now)
        for item in vendor.items where item.status.isUnresolved {
            recalculateDueDate(for: item)
        }
        try persist()
    }

    /// Detaches the vendor from its items and batches, then deletes it. History is preserved.
    func deleteVendor(_ vendor: Vendor) throws {
        for item in vendor.items {
            item.vendor = nil
        }
        for batch in vendor.batches {
            batch.vendor = nil
        }
        context.delete(vendor)
        try persist()
    }

    @discardableResult
    func createBin(label: String, locationNote: String) throws -> StorageBin {
        let now = dateProvider.now
        let bin = StorageBin(label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                             locationNote: locationNote.trimmingCharacters(in: .whitespacesAndNewlines),
                             now: now)
        context.insert(bin)
        try persist()
        return bin
    }

    func updateBin(_ bin: StorageBin) throws {
        bin.touch(dateProvider.now)
        try persist()
    }

    /// Detaches the bin from its items, then deletes it. The cores themselves survive.
    func deleteBin(_ bin: StorageBin) throws {
        for item in bin.items {
            item.bin = nil
        }
        context.delete(bin)
        try persist()
    }

    func updateShopProfile(_ profile: ShopProfile) throws {
        profile.touch(dateProvider.now)
        try persist()
    }

    // MARK: - Shared helpers

    /// Appends one timeline entry. Public because `ReturnBatchService` records its own item-level
    /// events through this service rather than writing `CoreEvent` objects itself.
    ///
    /// Does not save — the calling mutation saves once, so an event can never be persisted
    /// without the change it describes.
    func appendEvent(_ type: CoreEventType,
                     to item: CoreItem,
                     detail: String,
                     amount: Money?,
                     reference: String,
                     fromStatus: CoreStatus?,
                     toStatus: CoreStatus?) {
        let event = CoreEvent(type: type,
                              detail: detail,
                              timestamp: dateProvider.now,
                              amount: amount,
                              reference: reference,
                              from: fromStatus,
                              to: toStatus)
        context.insert(event)
        event.coreItem = item

        // Announced here as well as from `persist()` because `ReturnBatchService` writes item
        // events through this method and then saves through *its* own `persist()`, which this
        // service never sees. The listener coalesces and defers to the next turn of the run loop,
        // so announcing before the save — and announcing twice for one change — is harmless.
        announceChange()
    }

    /// Builds an editable draft from a stored item, for the editor screen.
    ///
    /// The scanned payload travels with the rest of the values. Without it the draft would report
    /// "no payload", and `applyScannedBarcode(from:to:)` reads exactly that as "nothing to record"
    /// — so a payload stored earlier would be invisible in the editor and impossible to correct.
    func draft(for item: CoreItem) -> CoreItemDraft {
        CoreItemDraft(existingID: item.id,
                      partName: item.partName,
                      partNumber: item.partNumber,
                      vendorIdentifier: item.vendor?.id,
                      binIdentifier: item.bin?.id,
                      expectedCreditText: item.expectedCredit.plainDecimalString,
                      invoiceReference: item.invoiceReference,
                      repairOrderReference: item.repairOrderReference,
                      receivedDate: item.receivedDate,
                      usesCustomDueDate: item.usesCustomDueDate,
                      customDueDate: item.dueDate,
                      notes: item.notes,
                      scannedBarcodeValue: item.scannedBarcodeValue,
                      scannedBarcodeSymbology: item.scannedBarcodeSymbology)
    }

    // MARK: - Private

    /// Copies the validated draft onto the item, including the resolved due date.
    private func apply(_ draft: CoreItemDraft,
                       to item: CoreItem,
                       amount: Money,
                       vendor: Vendor?,
                       bin: StorageBin?,
                       calendar: Calendar) {
        item.partName = draft.trimmedPartName
        item.partNumber = draft.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        item.expectedCredit = amount
        item.invoiceReference = draft.invoiceReference.trimmingCharacters(in: .whitespacesAndNewlines)
        item.repairOrderReference = draft.repairOrderReference.trimmingCharacters(in: .whitespacesAndNewlines)
        item.notes = draft.notes
        item.receivedDate = draft.receivedDate
        item.vendor = vendor
        item.bin = bin
        item.usesCustomDueDate = draft.usesCustomDueDate

        let windowDays = vendor?.defaultReturnWindowDays
            ?? AppConfiguration.defaultVendorReturnWindowDays
        item.dueDate = draft.resolvedDueDate(vendorWindowDays: windowDays, calendar: calendar)
    }

    /// Copies a scanned payload from the draft onto the item, verbatim, and returns it.
    ///
    /// Two rules make this safe:
    ///
    /// 1. The payload is written **only** to `scannedBarcodeValue`. `partNumber` stays exactly
    ///    what `apply` put there — the value the user confirmed — so a scan can never overwrite it.
    /// 2. A draft with no payload writes nothing at all, so re-saving such an item cannot erase a
    ///    payload recorded earlier.
    /// 3. A payload identical to the one already on the item is **not** news. `draft(for:)` now
    ///    carries the stored payload into the editor — which is what makes it correctable — so an
    ///    ordinary edit-and-save hands the same bytes straight back. Reporting that as a fresh
    ///    scan would stamp a "Scanned barcode recorded" entry on the timeline every single save.
    ///
    /// Returns `nil` when there was nothing new to record, which is also the signal not to append
    /// an event.
    private func applyScannedBarcode(from draft: CoreItemDraft, to item: CoreItem) -> String? {
        guard let payload = draft.scannedBarcodeValue else { return nil }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let isUnchanged = item.scannedBarcodeValue == payload
            && item.scannedBarcodeSymbology == draft.scannedBarcodeSymbology

        item.scannedBarcodeValue = payload
        item.scannedBarcodeSymbology = draft.scannedBarcodeSymbology

        return isUnchanged ? nil : payload
    }

    /// Appends the timeline entry for a newly recorded scan. A no-op when `payload` is `nil`.
    ///
    /// Goes through `appendEvent` like every other event, so the event is inserted into the same
    /// context and saved by the caller's single `persist()`.
    private func recordScannedBarcodeEvent(payload: String?, symbology: String?, on item: CoreItem) {
        guard let payload = payload else { return }

        var detail = "Scanned barcode recorded: " + payload + "."
        if let symbology = symbology,
           !symbology.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail += " Symbology " + symbology + "."
        }

        appendEvent(.edited,
                    to: item,
                    detail: detail,
                    amount: nil,
                    reference: "",
                    fromStatus: nil,
                    toStatus: nil)
    }

    private func fetching<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw DomainError.persistenceFailed(String(describing: error))
        }
    }

    private func persist() throws {
        do {
            try context.save()
        } catch {
            throw DomainError.persistenceFailed(String(describing: error))
        }
        announceChange()
    }

    /// Tells the relay the ledger moved.
    ///
    /// Announced after the save rather than before it, so a listener that reads the store back sees
    /// the change it is being told about. Deliberately fire-and-forget: whether anything is
    /// listening, and what it does about it, is none of this service's business — a mutation must
    /// never fail because a reminder could not be re-planned.
    private func announceChange() {
        changeRelay.post(context)
    }
}
