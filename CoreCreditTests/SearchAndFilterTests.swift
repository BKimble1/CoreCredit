//
//  SearchAndFilterTests.swift
//  CoreCreditTests
//
//  Required scenario 10: search and filter find vendor, part, invoice, RO, and bin references.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Searching, filtering, sorting, and grouping the core list")
struct SearchAndFilterTests {

    private let calendar = TestClock.calendar
    private let now = TestClock.date(year: 2026, month: 3, day: 12)
    private let napaID = UUID()
    private let oreillyID = UUID()

    // MARK: - Fixtures

    private var alternator: TestItem {
        TestItem(partName: "Alternator",
                 partNumber: "03-1887",
                 invoiceReference: "INV-552",
                 repairOrderReference: "1024",
                 notes: "Chased NAPA twice.",
                 binLabel: "A3",
                 vendorName: "NAPA",
                 vendorIdentifier: napaID,
                 status: .awaitingCore,
                 expectedCredit: Money(cents: 8_650),
                 receivedDate: TestClock.date(year: 2026, month: 3, day: 10),
                 dueDate: TestClock.date(year: 2026, month: 4, day: 9),
                 createdAt: TestClock.date(year: 2026, month: 3, day: 10))
    }

    private var starter: TestItem {
        TestItem(partName: "Starter",
                 partNumber: "17-4420",
                 invoiceReference: "INV-553",
                 repairOrderReference: "1099",
                 creditReference: "CM-4471",
                 binLabel: "B1",
                 vendorName: "O'Reilly",
                 vendorIdentifier: oreillyID,
                 status: .credited,
                 expectedCredit: Money(cents: 5_400),
                 actualCredit: Money(cents: 5_400),
                 receivedDate: TestClock.date(year: 2026, month: 3, day: 1),
                 dueDate: TestClock.date(year: 2026, month: 3, day: 15),
                 createdAt: TestClock.date(year: 2026, month: 3, day: 1))
    }

    private var caliper: TestItem {
        TestItem(partName: "Caf\u{00E9} brake caliper",
                 partNumber: "CAL-118",
                 binLabel: "B1",
                 vendorName: "NAPA",
                 vendorIdentifier: napaID,
                 status: .readyToReturn,
                 expectedCredit: Money(cents: 4_200),
                 receivedDate: TestClock.date(year: 2026, month: 2, day: 20),
                 dueDate: TestClock.date(year: 2026, month: 3, day: 11),
                 createdAt: TestClock.date(year: 2026, month: 2, day: 20))
    }

    private var orphan: TestItem {
        TestItem(partName: "Water pump",
                 partNumber: "WP-9021",
                 status: .awaitingCore,
                 expectedCredit: Money(cents: 3_150),
                 receivedDate: TestClock.date(year: 2026, month: 3, day: 5),
                 createdAt: TestClock.date(year: 2026, month: 3, day: 5))
    }

    private var allItems: [TestItem] { [alternator, starter, caliper, orphan] }

    // MARK: - Scenario 10: every reference kind is searchable

    @Test("Search finds a vendor reference")
    func searchFindsAVendorReference() {
        #expect(CoreItemQuery.matchesSearch(alternator, text: "NAPA"))
        #expect(CoreItemQuery.matchesSearch(alternator, text: "napa"))
        #expect(CoreItemQuery.matchesSearch(starter, text: "O'Reilly"))
    }

    @Test("Search finds a part reference")
    func searchFindsAPartReference() {
        #expect(CoreItemQuery.matchesSearch(alternator, text: "Alternator"))
        #expect(CoreItemQuery.matchesSearch(alternator, text: "03-1887"))
        #expect(CoreItemQuery.matchesSearch(starter, text: "17-4420"))
    }

    @Test("Search finds an invoice reference")
    func searchFindsAnInvoiceReference() {
        #expect(CoreItemQuery.matchesSearch(alternator, text: "INV-552"))
        #expect(CoreItemQuery.matchesSearch(alternator, text: "inv-552"))
        #expect(CoreItemQuery.matchesSearch(starter, text: "INV-552") == false)
    }

    @Test("Search finds a repair order reference")
    func searchFindsARepairOrderReference() {
        #expect(CoreItemQuery.matchesSearch(alternator, text: "1024"))
        #expect(CoreItemQuery.matchesSearch(starter, text: "1099"))
        #expect(CoreItemQuery.matchesSearch(alternator, text: "1099") == false)
    }

    @Test("Search finds a bin reference")
    func searchFindsABinReference() {
        #expect(CoreItemQuery.matchesSearch(alternator, text: "A3"))
        #expect(CoreItemQuery.matchesSearch(alternator, text: "a3"))
        #expect(CoreItemQuery.matchesSearch(orphan, text: "A3") == false)
    }

    // MARK: - Search behaviour

    @Test("Search also covers notes and the credit memo number")
    func searchCoversNotesAndCreditReference() {
        #expect(CoreItemQuery.matchesSearch(alternator, text: "chased"))
        #expect(CoreItemQuery.matchesSearch(starter, text: "CM-4471"))
    }

    @Test("Search ignores diacritics")
    func searchIgnoresDiacritics() {
        #expect(CoreItemQuery.matchesSearch(caliper, text: "cafe"))
        #expect(CoreItemQuery.matchesSearch(caliper, text: "Caf\u{00E9}"))
    }

    @Test("Blank search text matches everything")
    func blankSearchTextMatchesEverything() {
        for item in allItems {
            #expect(CoreItemQuery.matchesSearch(item, text: ""))
            #expect(CoreItemQuery.matchesSearch(item, text: "   "))
        }
        let filtered = CoreItemQuery.filter(allItems,
                                            using: CoreItemFilter(searchText: "  "),
                                            now: now,
                                            calendar: calendar)
        #expect(filtered.count == 4)
    }

    @Test("Search text that matches nothing filters everything out")
    func unmatchedSearchTextFiltersEverythingOut() {
        let filtered = CoreItemQuery.filter(allItems,
                                            using: CoreItemFilter(searchText: "flux capacitor"),
                                            now: now,
                                            calendar: calendar)
        #expect(filtered.isEmpty)
    }

    // MARK: - Filtering

    @Test("An empty status set means every status, a populated one narrows the list")
    func statusFiltering() {
        let all = CoreItemQuery.filter(allItems, using: CoreItemFilter(statuses: []),
                                       now: now, calendar: calendar)
        #expect(all.count == 4)

        let awaiting = CoreItemQuery.filter(allItems, using: CoreItemFilter(statuses: [.awaitingCore]),
                                            now: now, calendar: calendar)
        #expect(awaiting.count == 2)
        #expect(awaiting.allSatisfy { $0.status == .awaitingCore })
    }

    @Test("Filtering by vendor keeps only that vendor's cores")
    func vendorFiltering() {
        let napaOnly = CoreItemQuery.filter(allItems,
                                            using: CoreItemFilter(vendorIdentifier: napaID),
                                            now: now,
                                            calendar: calendar)
        #expect(napaOnly.count == 2)
        #expect(napaOnly.allSatisfy { $0.vendorIdentifier == napaID })
    }

    @Test("The overdue filter is measured against the injected clock")
    func overdueFiltering() {
        let overdue = CoreItemQuery.filter(allItems,
                                           using: CoreItemFilter(onlyOverdue: true),
                                           now: now,
                                           calendar: calendar)
        #expect(overdue.count == 1)
        #expect(overdue.first?.partNumber == "CAL-118")

        let earlier = CoreItemQuery.filter(allItems,
                                           using: CoreItemFilter(onlyOverdue: true),
                                           now: TestClock.date(year: 2026, month: 3, day: 11),
                                           calendar: calendar)
        #expect(earlier.isEmpty)
    }

    @Test("Received-date bounds are inclusive at day granularity")
    func receivedDateBoundsAreInclusive() {
        let onOrAfter = CoreItemQuery.filter(
            allItems,
            using: CoreItemFilter(receivedOnOrAfter: TestClock.date(year: 2026, month: 3, day: 5, hour: 23)),
            now: now,
            calendar: calendar
        )
        #expect(onOrAfter.count == 2)

        let onOrBefore = CoreItemQuery.filter(
            allItems,
            using: CoreItemFilter(receivedOnOrBefore: TestClock.date(year: 2026, month: 3, day: 1, hour: 0)),
            now: now,
            calendar: calendar
        )
        #expect(onOrBefore.count == 2)
    }

    @Test("A filter is only 'active' when something other than the search field is set")
    func filterActivityIgnoresSearchText() {
        #expect(CoreItemFilter.none.isActive == false)
        #expect(CoreItemFilter.none.activeCriteriaCount == 0)
        #expect(CoreItemFilter(searchText: "napa").isActive == false)
        #expect(CoreItemFilter(searchText: "napa").activeCriteriaCount == 0)

        let busy = CoreItemFilter(searchText: "napa",
                                  statuses: [.awaitingCore, .disputed],
                                  vendorIdentifier: napaID,
                                  onlyOverdue: true,
                                  receivedOnOrAfter: now,
                                  receivedOnOrBefore: now)
        #expect(busy.isActive)
        #expect(busy.activeCriteriaCount == 5)
    }

    // MARK: - Sorting

    @Test("Sorting by due date puts undated cores last")
    func dueDateSortPutsUndatedCoresLast() {
        let sorted = CoreItemQuery.sort(allItems, by: .dueDateAscending)
        #expect(sorted.map(\.partNumber) == ["CAL-118", "17-4420", "03-1887", "WP-9021"])
    }

    @Test("Sorting by value puts the biggest core charge first")
    func valueSortIsDescending() {
        let sorted = CoreItemQuery.sort(allItems, by: .valueDescending)
        #expect(sorted.map(\.expectedCredit) == [
            Money(cents: 8_650), Money(cents: 5_400), Money(cents: 4_200), Money(cents: 3_150)
        ])
    }

    @Test("Newest and oldest sorts are exact mirrors of one another")
    func newestAndOldestSortsMirror() {
        let newest = CoreItemQuery.sort(allItems, by: .newestFirst)
        let oldest = CoreItemQuery.sort(allItems, by: .oldestFirst)

        #expect(newest.map(\.partNumber) == ["03-1887", "WP-9021", "17-4420", "CAL-118"])
        #expect(oldest.map(\.partNumber) == ["CAL-118", "17-4420", "WP-9021", "03-1887"])
    }

    @Test("Ties are broken deterministically by identifier")
    func tiesAreBrokenDeterministically() {
        let created = TestClock.date(year: 2026, month: 3, day: 3)
        let first = TestItem(partName: "A", partNumber: "SAME-1",
                             expectedCredit: Money(cents: 1_000), createdAt: created)
        let second = TestItem(partName: "B", partNumber: "SAME-2",
                              expectedCredit: Money(cents: 1_000), createdAt: created)

        let forwards = CoreItemQuery.sort([first, second], by: .newestFirst).map(\.identifier)
        let backwards = CoreItemQuery.sort([second, first], by: .newestFirst).map(\.identifier)
        #expect(forwards == backwards)

        let expectedOrder = first.identifier.uuidString < second.identifier.uuidString
            ? [first.identifier, second.identifier]
            : [second.identifier, first.identifier]
        #expect(forwards == expectedOrder)
    }

    @Test("Filtering and sorting compose")
    func filteringAndSortingCompose() {
        let result = CoreItemQuery.filterAndSort(
            allItems,
            filter: CoreItemFilter(statuses: [.awaitingCore, .readyToReturn]),
            sort: .valueDescending,
            now: now,
            calendar: calendar
        )
        #expect(result.map(\.partNumber) == ["03-1887", "CAL-118", "WP-9021"])
    }

    @Test("Sort options carry their own labels")
    func sortOptionLabels() {
        #expect(CoreItemSort.dueDateAscending.displayName == "Due date")
        #expect(CoreItemSort.valueDescending.displayName == "Highest value")
        #expect(CoreItemSort.newestFirst.displayName == "Newest")
        #expect(CoreItemSort.oldestFirst.displayName == "Oldest")
        #expect(CoreItemSort.dueDateAscending.id == CoreItemSort.dueDateAscending.rawValue)
        #expect(CoreItemSort.allCases.count == 4)
        #expect(CoreItemSort.valueDescending.symbolName == "dollarsign.circle")
    }

    // MARK: - Grouping

    @Test("Grouping by vendor sorts by name and puts the no-vendor bucket last")
    func groupingByVendorPutsTheNoVendorBucketLast() {
        let groups = CoreItemQuery.groupedByVendor(allItems)

        #expect(groups.count == 3)
        // Tuple elements have no key paths, so map with an explicit closure.
        #expect(groups.map { $0.vendorName } == ["NAPA", "O'Reilly", CoreItemQuery.noVendorGroupName])
        #expect(groups.first?.items.count == 2)
        #expect(groups.last?.vendorIdentifier == nil)
        #expect(groups.last?.items.count == 1)
    }

    @Test("A vendor with a blank name is grouped under the unnamed-vendor label")
    func aBlankVendorNameGetsItsOwnLabel() {
        let ghostID = UUID()
        let ghost = TestItem(partName: "Mystery core", vendorName: nil,
                             vendorIdentifier: ghostID, expectedCredit: Money(cents: 100))

        let groups = CoreItemQuery.groupedByVendor([ghost])
        #expect(groups.count == 1)
        #expect(groups.first?.vendorName == CoreItemQuery.unnamedVendorGroupName)
        #expect(groups.first?.vendorIdentifier == ghostID)
    }
}
