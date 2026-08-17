import Foundation
import SwiftData

/// Every write to a `ReturnBatch` goes through here.
///
/// A batch is a single physical hand-off to one vendor, so it is always single-vendor: mixing
/// vendors would make the vendor's credit memo impossible to reconcile against the batch.
///
/// Item-level events are appended through `itemService.appendEvent` rather than by constructing
/// `CoreEvent` objects here, so there is still exactly one place that writes the timeline.
@MainActor
struct ReturnBatchService {
    let context: ModelContext
    let dateProvider: any DateProvider
    let itemService: CoreItemService

    init(context: ModelContext, dateProvider: any DateProvider = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
        self.itemService = CoreItemService(context: context, dateProvider: dateProvider)
    }

    // MARK: - Queries

    /// Every batch, most recent return date first.
    func allBatches() throws -> [ReturnBatch] {
        let descriptor = FetchDescriptor<ReturnBatch>(
            sortBy: [SortDescriptor(\ReturnBatch.returnDate, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw DomainError.persistenceFailed(String(describing: error))
        }
    }

    /// Batches that still contain at least one unresolved core — i.e. money the vendor owes.
    func openBatches() throws -> [ReturnBatch] {
        try allBatches().filter { batch in
            batch.coreItems.contains { $0.status.isUnresolved }
        }
    }

    // MARK: - Mutations

    /// Creates a batch and moves every included core into `.returnedAwaitingCredit`.
    ///
    /// Throws `.emptyBatch` when `items` is empty, `.missingVendor` when `vendor` is nil, and
    /// `.mixedVendorBatch` when any item belongs to a different vendor.
    ///
    /// The status move is applied directly rather than through `CoreStatusMachine`: a core can be
    /// handed back while still sitting in `.awaitingCore` (the old unit went straight into the
    /// return bin), which the transition table would otherwise reject.
    @discardableResult
    func createBatch(vendor: Vendor?,
                     items: [CoreItem],
                     returnDate: Date,
                     method: ReturnMethod,
                     reference: String,
                     notes: String) throws -> ReturnBatch {
        guard !items.isEmpty else { throw DomainError.emptyBatch }
        guard let batchVendor = vendor else { throw DomainError.missingVendor }

        for item in items {
            guard let itemVendor = item.vendor, itemVendor.id == batchVendor.id else {
                throw DomainError.mixedVendorBatch
            }
        }

        let now = dateProvider.now
        let batch = ReturnBatch(vendor: batchVendor,
                                returnDate: returnDate,
                                method: method,
                                reference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                                now: now)
        batch.notes = notes
        context.insert(batch)

        attach(items, to: batch)
        batch.touch(now)

        try persist()
        return batch
    }

    /// Adds more cores to an existing batch. Items already in this batch are ignored; an item
    /// that belongs to a *different* batch is rejected rather than silently moved.
    func addItems(_ items: [CoreItem], to batch: ReturnBatch) throws {
        guard !items.isEmpty else { throw DomainError.emptyBatch }
        guard let batchVendor = batch.vendor else { throw DomainError.missingVendor }

        for item in items {
            if let existing = item.returnBatch, existing.id != batch.id {
                throw DomainError.itemAlreadyInBatch(item.displayTitle)
            }
            guard let itemVendor = item.vendor, itemVendor.id == batchVendor.id else {
                throw DomainError.mixedVendorBatch
            }
        }

        let newcomers = items.filter { $0.returnBatch?.id != batch.id }
        attach(newcomers, to: batch)
        batch.touch(dateProvider.now)

        try persist()
    }

    /// Pulls a core back out of a batch. The core's status is deliberately left alone — undoing
    /// a return is a separate, explicit decision made through `CoreItemService.transition`.
    func removeItem(_ item: CoreItem, from batch: ReturnBatch) throws {
        guard item.returnBatch?.id == batch.id else { throw DomainError.notFound }

        let now = dateProvider.now
        item.returnBatch = nil
        item.touch(now)
        batch.touch(now)

        itemService.appendEvent(.removedFromBatch,
                                to: item,
                                detail: "Removed from return batch.",
                                amount: nil,
                                reference: batch.reference,
                                fromStatus: nil,
                                toStatus: nil)

        try persist()
    }

    /// Edits the batch header. Member cores keep the `returnedDate` they were stamped with, so
    /// correcting a typo in the reference never rewrites item history.
    func updateBatch(_ batch: ReturnBatch,
                     returnDate: Date,
                     method: ReturnMethod,
                     reference: String,
                     notes: String) throws {
        batch.returnDate = returnDate
        batch.method = method
        batch.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        batch.notes = notes
        batch.touch(dateProvider.now)
        try persist()
    }

    func attachReceipt(_ attachment: Attachment, to batch: ReturnBatch) throws {
        context.insert(attachment)
        attachment.returnBatch = batch
        batch.touch(dateProvider.now)
        try persist()
    }

    func removeReceipt(_ attachment: Attachment, from batch: ReturnBatch) throws {
        attachment.returnBatch = nil
        context.delete(attachment)
        batch.touch(dateProvider.now)
        try persist()
    }

    /// Deletes the batch. Member cores are detached and keep their status; the batch's own
    /// receipt photos cascade away with it.
    func delete(_ batch: ReturnBatch) throws {
        let members = batch.coreItems
        let reference = batch.reference
        let now = dateProvider.now

        for item in members {
            item.returnBatch = nil
            item.touch(now)
            itemService.appendEvent(.removedFromBatch,
                                    to: item,
                                    detail: "Return batch deleted.",
                                    amount: nil,
                                    reference: reference,
                                    fromStatus: nil,
                                    toStatus: nil)
        }

        batch.vendor = nil
        context.delete(batch)
        try persist()
    }

    // MARK: - Private

    /// Links cores to the batch, stamps them as returned, and writes the two-event pair
    /// (`.addedToBatch` then `.returned`) that the timeline expects.
    private func attach(_ items: [CoreItem], to batch: ReturnBatch) {
        let now = dateProvider.now
        for item in items {
            let from = item.status

            item.returnBatch = batch
            itemService.appendEvent(.addedToBatch,
                                    to: item,
                                    detail: "Added to return batch.",
                                    amount: nil,
                                    reference: batch.reference,
                                    fromStatus: nil,
                                    toStatus: nil)

            item.status = .returnedAwaitingCredit
            item.returnedDate = batch.returnDate
            item.touch(now)

            itemService.appendEvent(.returned,
                                    to: item,
                                    detail: "Returned to " + (batch.vendor?.displayName ?? "vendor") + ".",
                                    amount: item.expectedCredit,
                                    reference: batch.reference,
                                    fromStatus: from,
                                    toStatus: .returnedAwaitingCredit)
        }
    }

    private func persist() throws {
        do {
            try context.save()
        } catch {
            throw DomainError.persistenceFailed(String(describing: error))
        }
    }
}
