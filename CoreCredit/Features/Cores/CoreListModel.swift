//
//  CoreListModel.swift
//  CoreCredit
//

import Foundation
import Observation

/// View state for `CoreListView`: the search text, the filter, the sort order, sheet routing, and
/// the last error.
///
/// The model holds no items. `CoreListView` owns the `@Query`, hands the result here, and gets back
/// whatever `CoreItemQuery.filterAndSort(_:filter:sort:now:calendar:)` returns — the list never
/// writes its own matching or ordering rules, so search behaves identically here, in the exporter,
/// and in the unit tests.
@MainActor
@Observable
final class CoreListModel {

    /// Search text and every filter criterion, in the exact shape the domain expects.
    var filter: CoreItemFilter

    /// Deadline order by default: the point of this screen is what has to go back next.
    var sort: CoreItemSort = .dueDateAscending

    /// The modal this screen currently has open. `nil` means the ledger itself is in front.
    ///
    /// One enum, presented by a single `.sheet(item:)`, rather than a flag per sheet: two `.sheet`
    /// modifiers attached to the *same* view can shadow one another, so only one of them would ever
    /// present. Each case carries its own `id`, so moving from one sheet to another re-presents.
    enum Route: Identifiable {

        /// The filter sheet, opened on the criteria currently applied.
        case filters

        /// A brand-new core charge.
        case editor

        /// Shown *instead of* the editor when the free tier blocks another open core.
        case paywall(PaywallTrigger)

        var id: String {
            switch self {
            case .filters:
                return "filters"
            case .editor:
                return "editor"
            case .paywall(let trigger):
                return "paywall." + trigger.id
            }
        }
    }

    /// Which sheet is presented, if any.
    var route: Route?

    var errorMessage: String?

    /// - Parameter filter: Pre-set criteria, used when the dashboard opens this screen already
    ///   filtered to a status, to overdue items, or to one vendor.
    init(filter: CoreItemFilter = .none) {
        self.filter = filter
    }

    // MARK: - Search and filtering

    /// Bound to `.searchable`. Lives inside `filter` so there is exactly one source of truth.
    var searchText: String {
        get { filter.searchText }
        set { filter.searchText = newValue }
    }

    /// Drives the "Filters (n)" badge. Search text is excluded on purpose — it has its own visible
    /// field and should not light the badge up.
    var activeFilterCount: Int { filter.activeCriteriaCount }

    var hasActiveFilters: Bool { filter.isActive }

    /// True when *anything* is narrowing the list, search included. This is what tells an empty
    /// result apart from an empty ledger.
    var isNarrowingResults: Bool {
        if filter.isActive { return true }
        return !filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rows to show, filtered and ordered entirely by the domain.
    func visibleItems(from items: [CoreItem], dateProvider: any DateProvider) -> [CoreItem] {
        CoreItemQuery.filterAndSort(
            items,
            filter: filter,
            sort: sort,
            now: dateProvider.now,
            calendar: dateProvider.calendar
        )
    }

    /// Replaces every criterion, keeping whatever the filter sheet decided about search text.
    func apply(_ newFilter: CoreItemFilter) {
        filter = newFilter
    }

    /// Drops the filter criteria but keeps what the user typed.
    func clearFilters() {
        filter = CoreItemFilter(searchText: filter.searchText)
    }

    /// Drops the filter criteria *and* the search text — the "show me everything again" escape
    /// hatch offered by the no-results state.
    func clearFiltersAndSearch() {
        filter = .none
    }

    // MARK: - Actions

    /// Free tier check before opening the editor.
    ///
    /// Only *creating* is gated. Viewing, editing, and exporting what already exists is never
    /// blocked for either tier — see `EntitlementPolicy.canViewEditExportExistingItems(tier:)`.
    func requestAddCore(items: [CoreItem], tier: SubscriptionTier) {
        let unresolved = RiskCalculator.unresolvedCount(items)
        if let trigger = EntitlementPolicy.blockingTrigger(unresolvedCount: unresolved, tier: tier) {
            route = .paywall(trigger)
        } else {
            route = .editor
        }
    }

    // MARK: - Errors

    func present(_ error: any Error) {
        errorMessage = CoreListModel.message(for: error)
    }

    func clearError() {
        errorMessage = nil
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
                return description + " " + suggestion
            }
            return description
        }
        return error.localizedDescription
    }
}
