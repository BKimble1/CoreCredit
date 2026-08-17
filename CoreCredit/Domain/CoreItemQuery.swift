//
//  CoreItemQuery.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// The state of the Cores screen's search field and filter sheet.
struct CoreItemFilter: Equatable, Sendable {

    /// Free text typed into the search field.
    var searchText: String

    /// Statuses to keep. An **empty** set means "all statuses", not "none".
    var statuses: Set<CoreStatus>

    var vendorIdentifier: UUID?
    var onlyOverdue: Bool

    /// Inclusive lower bound on `receivedDate`, compared at day granularity.
    var receivedOnOrAfter: Date?

    /// Inclusive upper bound on `receivedDate`, compared at day granularity.
    var receivedOnOrBefore: Date?

    init(searchText: String = "",
         statuses: Set<CoreStatus> = [],
         vendorIdentifier: UUID? = nil,
         onlyOverdue: Bool = false,
         receivedOnOrAfter: Date? = nil,
         receivedOnOrBefore: Date? = nil) {
        self.searchText = searchText
        self.statuses = statuses
        self.vendorIdentifier = vendorIdentifier
        self.onlyOverdue = onlyOverdue
        self.receivedOnOrAfter = receivedOnOrAfter
        self.receivedOnOrBefore = receivedOnOrBefore
    }

    /// An empty filter: everything passes.
    static let none = CoreItemFilter()

    /// True when a *filter* is applied. Typing in the search field does not count, because search
    /// has its own visible affordance and should not light up the filter badge.
    var isActive: Bool {
        !statuses.isEmpty
            || vendorIdentifier != nil
            || onlyOverdue
            || receivedOnOrAfter != nil
            || receivedOnOrBefore != nil
    }

    /// Number of filter criteria in use, for the badge on the filter button.
    ///
    /// The whole status set counts as one criterion, and `searchText` is excluded to match
    /// `isActive`.
    var activeCriteriaCount: Int {
        var total = 0
        if !statuses.isEmpty { total += 1 }
        if vendorIdentifier != nil { total += 1 }
        if onlyOverdue { total += 1 }
        if receivedOnOrAfter != nil { total += 1 }
        if receivedOnOrBefore != nil { total += 1 }
        return total
    }
}

/// Sort orders offered on the Cores screen.
enum CoreItemSort: String, CaseIterable, Identifiable, Sendable {
    case dueDateAscending
    case valueDescending
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dueDateAscending: return "Due date"
        case .valueDescending: return "Highest value"
        case .newestFirst: return "Newest"
        case .oldestFirst: return "Oldest"
        }
    }

    var symbolName: String {
        switch self {
        case .dueDateAscending: return "calendar"
        case .valueDescending: return "dollarsign.circle"
        case .newestFirst: return "arrow.down.circle"
        case .oldestFirst: return "arrow.up.circle"
        }
    }
}

/// Filtering, sorting, and grouping for lists of core items.
///
/// Pure functions over `CoreItemRepresenting`, so the same code drives the live SwiftData list and
/// an exported snapshot array, and both are unit-testable.
enum CoreItemQuery {

    /// Label used for the bucket of items with no vendor attached.
    static let noVendorGroupName = "No vendor"

    /// Label used when a vendor is linked but has no usable name.
    static let unnamedVendorGroupName = "Unnamed vendor"

    /// Case- and diacritic-insensitive substring match.
    ///
    /// Searches `partName`, `partNumber`, `invoiceReference`, `repairOrderReference`,
    /// `creditReference`, `vendorName`, `binLabel`, and `notes`. Blank or whitespace-only text
    /// matches everything, so clearing the field restores the full list.
    static func matchesSearch(_ item: some CoreItemRepresenting, text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }

        let haystacks: [String?] = [
            item.partName,
            item.partNumber,
            item.invoiceReference,
            item.repairOrderReference,
            item.creditReference,
            item.vendorName,
            item.binLabel,
            item.notes
        ]

        for haystack in haystacks {
            guard let value = haystack, !value.isEmpty else { continue }
            if value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// True when the item satisfies every part of the filter.
    static func matches(_ item: some CoreItemRepresenting,
                        filter: CoreItemFilter,
                        now: Date,
                        calendar: Calendar) -> Bool {
        guard matchesSearch(item, text: filter.searchText) else { return false }

        if !filter.statuses.isEmpty, !filter.statuses.contains(item.status) {
            return false
        }
        if let vendorIdentifier = filter.vendorIdentifier, item.vendorIdentifier != vendorIdentifier {
            return false
        }
        if filter.onlyOverdue, !RiskCalculator.isOverdue(item, now: now, calendar: calendar) {
            return false
        }
        if let lowerBound = filter.receivedOnOrAfter {
            let received = calendar.startOfDay(for: item.receivedDate)
            if received < calendar.startOfDay(for: lowerBound) { return false }
        }
        if let upperBound = filter.receivedOnOrBefore {
            let received = calendar.startOfDay(for: item.receivedDate)
            if received > calendar.startOfDay(for: upperBound) { return false }
        }
        return true
    }

    static func filter<Item: CoreItemRepresenting>(_ items: [Item],
                                                   using filter: CoreItemFilter,
                                                   now: Date,
                                                   calendar: Calendar) -> [Item] {
        items.filter { CoreItemQuery.matches($0, filter: filter, now: now, calendar: calendar) }
    }

    /// Deterministic tiebreaker shared by every sort: newest first, then identifier.
    ///
    /// Without it `sorted(by:)` would be free to reorder equal elements between runs, which makes
    /// list animations jump and snapshot tests flake.
    private static func newestFirstTiebreak(_ lhs: some CoreItemRepresenting,
                                            _ rhs: some CoreItemRepresenting) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.identifier.uuidString < rhs.identifier.uuidString
    }

    /// Sorts a list. Items with no due date always land **last** under `.dueDateAscending`.
    static func sort<Item: CoreItemRepresenting>(_ items: [Item], by sort: CoreItemSort) -> [Item] {
        switch sort {
        case .dueDateAscending:
            return items.sorted { lhs, rhs in
                let leftDue = lhs.dueDate
                let rightDue = rhs.dueDate
                if let left = leftDue, let right = rightDue {
                    if left != right { return left < right }
                } else if leftDue != nil {
                    return true
                } else if rightDue != nil {
                    return false
                }
                return CoreItemQuery.newestFirstTiebreak(lhs, rhs)
            }

        case .valueDescending:
            return items.sorted { lhs, rhs in
                if lhs.expectedCredit != rhs.expectedCredit {
                    return lhs.expectedCredit > rhs.expectedCredit
                }
                return CoreItemQuery.newestFirstTiebreak(lhs, rhs)
            }

        case .newestFirst:
            return items.sorted { lhs, rhs in
                CoreItemQuery.newestFirstTiebreak(lhs, rhs)
            }

        case .oldestFirst:
            return items.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.identifier.uuidString < rhs.identifier.uuidString
            }
        }
    }

    static func filterAndSort<Item: CoreItemRepresenting>(_ items: [Item],
                                                          filter: CoreItemFilter,
                                                          sort: CoreItemSort,
                                                          now: Date,
                                                          calendar: Calendar) -> [Item] {
        let filtered = CoreItemQuery.filter(items, using: filter, now: now, calendar: calendar)
        return CoreItemQuery.sort(filtered, by: sort)
    }

    /// Groups items by vendor for the Returns screen.
    ///
    /// Groups are sorted by vendor name, case- and diacritic-insensitively, with the no-vendor
    /// group always last. Item order inside each group is the order they arrived in.
    static func groupedByVendor<Item: CoreItemRepresenting>(
        _ items: [Item]
    ) -> [(vendorIdentifier: UUID?, vendorName: String, items: [Item])] {

        var grouped: [UUID?: [Item]] = [:]
        var names: [UUID?: String] = [:]

        for item in items {
            let key = item.vendorIdentifier
            grouped[key, default: []].append(item)
            if names[key] == nil {
                if key == nil {
                    names[key] = noVendorGroupName
                } else {
                    let name = item.vendorName ?? ""
                    names[key] = name.isEmpty ? unnamedVendorGroupName : name
                }
            }
        }

        var groups: [(vendorIdentifier: UUID?, vendorName: String, items: [Item])] = []
        for (key, value) in grouped {
            groups.append((
                vendorIdentifier: key,
                vendorName: names[key] ?? noVendorGroupName,
                items: value
            ))
        }

        return groups.sorted { lhs, rhs in
            if lhs.vendorIdentifier == nil { return false }
            if rhs.vendorIdentifier == nil { return true }
            let comparison = lhs.vendorName.compare(
                rhs.vendorName,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            if comparison != .orderedSame { return comparison == .orderedAscending }
            let leftID = lhs.vendorIdentifier?.uuidString ?? ""
            let rightID = rhs.vendorIdentifier?.uuidString ?? ""
            return leftID < rightID
        }
    }
}
