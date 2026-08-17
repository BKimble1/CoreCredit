//
//  ReturnsModel.swift
//  CoreCredit
//

import Foundation
import Observation
import SwiftData

// MARK: - Section value types

/// One vendor's worth of cores that are on the shelf, ready to go back.
///
/// A return batch is always single-vendor, so the Returns screen never offers a mixed list: the
/// group *is* the unit of work, and `vendor` is what `CreateBatchSheet` is handed.
struct ReturnsReadyGroup: Identifiable {

    /// `nil` for the bucket of cores that have no vendor attached yet.
    let vendorIdentifier: UUID?

    /// Display name supplied by `CoreItemQuery.groupedByVendor(_:)`.
    let vendorName: String

    /// The live vendor record. `nil` for the no-vendor bucket, which cannot become a batch.
    let vendor: Vendor?

    /// The `.readyToReturn` cores in this group, due date first.
    let items: [CoreItem]

    var id: String { vendorIdentifier?.uuidString ?? "returns.readyGroup.noVendor" }

    var itemCount: Int { items.count }

    /// Face value of everything staged for this vendor.
    var totalExpectedCredit: Money {
        items.reduce(Money.zero) { partial, item in partial + item.expectedCredit }
    }

    /// False for the no-vendor bucket: `ReturnBatchService.createBatch` requires a vendor.
    var canCreateBatch: Bool {
        vendor != nil && items.isEmpty == false
    }
}

/// One row of the "waiting on a vendor credit" queue.
///
/// Everything the row needs is computed once, in the model, so the view never re-runs risk maths
/// while it lays out.
struct ReturnsCreditQueueEntry: Identifiable {

    let item: CoreItem

    /// Whole days since the last thing that happened to this core — the hand-off for a returned
    /// core, the short credit for a disputed one.
    let daysWaiting: Int

    /// Money still genuinely at stake: the full charge for a returned core, the shortfall for a
    /// disputed one.
    let outstanding: Money

    let isOverdue: Bool

    var id: UUID { item.id }
}

/// The payload behind a presented `CreateBatchSheet`.
struct ReturnsBatchRequest: Identifiable {

    let vendor: Vendor
    let preselected: [CoreItem]

    var id: UUID { vendor.id }
}

// MARK: - ReturnsModel

/// Screen state for `ReturnsView`.
///
/// This object owns three things and nothing else:
///
/// 1. **Derivation.** The screen's three sections are pure functions of the `@Query` results, so
///    they live here as functions over arrays rather than as stored, drift-prone copies.
/// 2. **Routing.** Which sheet is up, and what it was opened with.
/// 3. **Error text.** One user-facing sentence at a time, already phrased for an `ErrorBanner`.
///
/// Persistence stays in `@Query` and `ModelContext`; every mutation goes through `CoreItemService`
/// or `ReturnBatchService`. Nothing is cached here, so a change written by a sheet is reflected on
/// the screen behind it the moment SwiftData publishes it.
@MainActor
@Observable
final class ReturnsModel {

    // MARK: Routing

    /// The modal this screen currently has open. `nil` means the Returns screen itself is in front.
    ///
    /// One enum, presented by a single `.sheet(item:)`, rather than one optional per sheet: two
    /// `.sheet` modifiers attached to the *same* view can shadow one another, so only one of them
    /// would ever present. Each case's `id` combines the record it was opened with and a
    /// per-case prefix, so opening the credit sheet for a core after batching that same core's
    /// vendor is a genuine change of identity.
    enum Route: Identifiable {

        /// `CreateBatchSheet`, opened on one vendor's staged cores.
        case batch(ReturnsBatchRequest)

        /// `RecordCreditSheet`, opened on one core.
        case credit(CoreItem)

        var id: String {
            switch self {
            case .batch(let request):
                return "batch." + request.id.uuidString
            case .credit(let item):
                return "credit." + item.id.uuidString
            }
        }
    }

    /// Which sheet is presented, if any.
    var route: Route?

    // MARK: Section state

    /// Vendor groups whose full core list is expanded. Groups start collapsed to the first
    /// `collapsedItemPreviewCount` cores so a busy shelf does not push the queue off screen.
    var expandedVendorGroupIDs: Set<String> = []

    /// Whether returns with nothing left outstanding are listed alongside the open ones.
    var showsSettledBatches = false

    // MARK: Errors

    /// The current screen-level failure, or `nil`. Rendered by `ErrorBanner`.
    var errorMessage: String?

    /// How many cores a collapsed vendor group lists before it offers "Show all".
    static let collapsedItemPreviewCount = 3

    init() { }

    // MARK: - Derivation

    /// Cores that are ready to go back, grouped by vendor.
    ///
    /// Groups come back in `CoreItemQuery.groupedByVendor(_:)` order — vendor name, no-vendor last
    /// — and each group's cores are ordered by due date so the ones running out of window are at
    /// the top of the pick list.
    func readyGroups(from items: [CoreItem]) -> [ReturnsReadyGroup] {
        let ready = items.filter { $0.status == .readyToReturn }
        return CoreItemQuery.groupedByVendor(ready).map { group in
            ReturnsReadyGroup(
                vendorIdentifier: group.vendorIdentifier,
                vendorName: group.vendorName,
                vendor: group.items.first?.vendor,
                items: CoreItemQuery.sort(group.items, by: .dueDateAscending)
            )
        }
    }

    /// Batches that still contain at least one unresolved core — i.e. money the vendor owes.
    ///
    /// Mirrors `ReturnBatchService.openBatches()`, applied to the live `@Query` results rather than
    /// re-fetching, with one addition: a batch whose cores have all been removed is listed here
    /// too. It owes nothing, but it is also not settled, and hiding it would leave a record the
    /// user could no longer reach to delete.
    func openBatches(from batches: [ReturnBatch]) -> [ReturnBatch] {
        batches.filter { batch in
            let members = batch.coreItems
            if members.isEmpty { return true }
            return members.contains(where: { $0.status.isUnresolved })
        }
    }

    /// Batches with nothing outstanding. Hidden by default; kept reachable so the receipt photo
    /// behind a settled return can still be found.
    func settledBatches(from batches: [ReturnBatch]) -> [ReturnBatch] {
        batches.filter { batch in
            let members = batch.coreItems
            if members.isEmpty { return false }
            return members.contains(where: { $0.status.isUnresolved }) == false
        }
    }

    /// Every core that has gone back but has not been settled, oldest wait first.
    ///
    /// Both `.returnedAwaitingCredit` and `.disputed` belong here: a short credit is still an
    /// unfinished conversation with the vendor.
    func creditQueue(from items: [CoreItem], now: Date, calendar: Calendar) -> [ReturnsCreditQueueEntry] {
        let waiting = items.filter { $0.status == .returnedAwaitingCredit || $0.status == .disputed }

        let entries = waiting.map { item in
            ReturnsCreditQueueEntry(
                item: item,
                daysWaiting: RiskCalculator.ageInDays(item, now: now, calendar: calendar),
                outstanding: RiskCalculator.remainingExposure(for: item),
                isOverdue: RiskCalculator.isOverdue(item, now: now, calendar: calendar)
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.daysWaiting != rhs.daysWaiting { return lhs.daysWaiting > rhs.daysWaiting }
            if lhs.outstanding != rhs.outstanding { return lhs.outstanding > rhs.outstanding }
            return lhs.item.id.uuidString < rhs.item.id.uuidString
        }
    }

    /// Total still owed across the credit queue — the number this screen exists to answer.
    func totalOutstanding(in entries: [ReturnsCreditQueueEntry]) -> Money {
        entries.reduce(Money.zero) { partial, entry in partial + entry.outstanding }
    }

    /// Face value of everything staged to go back, across all vendors.
    func totalStaged(in groups: [ReturnsReadyGroup]) -> Money {
        groups.reduce(Money.zero) { partial, group in partial + group.totalExpectedCredit }
    }

    /// How many queue entries are past their return window.
    func overdueCount(in entries: [ReturnsCreditQueueEntry]) -> Int {
        entries.reduce(into: 0) { total, entry in
            if entry.isOverdue { total += 1 }
        }
    }

    // MARK: - Section state

    func isExpanded(_ group: ReturnsReadyGroup) -> Bool {
        expandedVendorGroupIDs.contains(group.id)
    }

    /// Cores to draw for a group: the first few, or all of them once expanded.
    func visibleItems(in group: ReturnsReadyGroup) -> [CoreItem] {
        if isExpanded(group) { return group.items }
        return Array(group.items.prefix(ReturnsModel.collapsedItemPreviewCount))
    }

    func toggleExpansion(_ group: ReturnsReadyGroup) {
        if expandedVendorGroupIDs.contains(group.id) {
            expandedVendorGroupIDs.remove(group.id)
        } else {
            expandedVendorGroupIDs.insert(group.id)
        }
    }

    func toggleSettledBatches() {
        showsSettledBatches.toggle()
    }

    // MARK: - Routing

    /// Opens `CreateBatchSheet` for a vendor group.
    ///
    /// A group with no vendor cannot become a batch, so this reports the domain's own explanation
    /// rather than presenting a sheet that could only fail on save.
    func beginBatch(for group: ReturnsReadyGroup) {
        guard let vendor = group.vendor else {
            errorMessage = ReturnsModel.message(for: DomainError.missingVendor)
            return
        }
        errorMessage = nil
        route = .batch(ReturnsBatchRequest(vendor: vendor, preselected: group.items))
    }

    /// Opens `RecordCreditSheet` for one core.
    func beginCredit(for item: CoreItem) {
        errorMessage = nil
        route = .credit(item)
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Error phrasing

    /// Turns any thrown error into one sentence a person can act on.
    ///
    /// `DomainError` already writes shop-floor English in `errorDescription` and always says what
    /// to do next in `recoverySuggestion`, so both are used and joined. Shared by the Returns
    /// sheets so an identical failure never reads two different ways.
    static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError {
            var parts: [String] = []
            if let description = localized.errorDescription, description.isEmpty == false {
                parts.append(description)
            }
            if let suggestion = localized.recoverySuggestion, suggestion.isEmpty == false {
                parts.append(suggestion)
            }
            if parts.isEmpty == false {
                return parts.joined(separator: " ")
            }
        }
        return error.localizedDescription
    }

    /// "3 cores", "1 core" — used in counts, captions, and spoken labels alike.
    static func coreCountText(_ count: Int) -> String {
        count == 1 ? "1 core" : String(count) + " cores"
    }

    /// Plain-language wait length for the credit queue.
    static func waitingText(days: Int) -> String {
        if days < 1 { return "Waiting since today" }
        if days == 1 { return "Waiting 1 day" }
        return "Waiting " + String(days) + " days"
    }
}
