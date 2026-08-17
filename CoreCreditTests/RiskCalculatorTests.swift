//
//  RiskCalculatorTests.swift
//  CoreCreditTests
//
//  Pure-domain money maths: what is still owed, what is late, and how old it is.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Money at risk, exposure, and dashboard summaries")
struct RiskCalculatorTests {

    private let calendar = TestClock.calendar
    private let now = TestClock.date(year: 2026, month: 3, day: 12)

    // MARK: - Exposure

    @Test("An unresolved core exposes its full core charge")
    func unresolvedItemsExposeTheirFullCharge() {
        for status in CoreStatus.unresolvedCases where status != .disputed {
            let item = TestItem(status: status, expectedCredit: Money(cents: 8_650))
            #expect(RiskCalculator.remainingExposure(for: item) == Money(cents: 8_650))
        }
    }

    @Test("A closed core exposes nothing, whatever it was worth")
    func closedItemsExposeNothing() {
        let credited = TestItem(status: .credited, expectedCredit: Money(cents: 8_650),
                                actualCredit: Money(cents: 8_650))
        let writtenOff = TestItem(status: .writtenOff, expectedCredit: Money(cents: 8_650))

        #expect(RiskCalculator.remainingExposure(for: credited) == Money.zero)
        #expect(RiskCalculator.remainingExposure(for: writtenOff) == Money.zero)
    }

    @Test("A disputed core with a recorded credit exposes only the shortfall")
    func disputedItemsExposeOnlyTheShortfall() {
        let short = TestItem(status: .disputed, expectedCredit: Money(cents: 8_650),
                             actualCredit: Money(cents: 7_500))
        #expect(RiskCalculator.remainingExposure(for: short) == Money(cents: 1_150))

        let overCredited = TestItem(status: .disputed, expectedCredit: Money(cents: 8_650),
                                    actualCredit: Money(cents: 9_000))
        #expect(RiskCalculator.remainingExposure(for: overCredited) == Money.zero)

        let noCreditYet = TestItem(status: .disputed, expectedCredit: Money(cents: 8_650))
        #expect(RiskCalculator.remainingExposure(for: noCreditYet) == Money(cents: 8_650))
    }

    // MARK: - Discrepancy

    @Test("Discrepancy is nil until a credit is recorded")
    func discrepancyIsNilUntilACreditIsRecorded() {
        let item = TestItem(status: .returnedAwaitingCredit, expectedCredit: Money(cents: 8_650))
        #expect(RiskCalculator.discrepancy(for: item) == nil)
    }

    @Test("Discrepancy is expected minus actual, positive when the vendor short-paid")
    func discrepancyIsExpectedMinusActual() {
        let short = TestItem(status: .disputed, expectedCredit: Money(cents: 8_650),
                             actualCredit: Money(cents: 7_500))
        #expect(RiskCalculator.discrepancy(for: short) == Money(cents: 1_150))

        let over = TestItem(status: .credited, expectedCredit: Money(cents: 8_650),
                            actualCredit: Money(cents: 9_000))
        #expect(RiskCalculator.discrepancy(for: over) == Money(cents: -350))

        let exact = TestItem(status: .credited, expectedCredit: Money(cents: 8_650),
                             actualCredit: Money(cents: 8_650))
        #expect(RiskCalculator.discrepancy(for: exact) == Money.zero)
    }

    // MARK: - Summaries

    @Test("A single unresolved $86.50 core makes money at risk exactly $86.50")
    func oneUnresolvedCoreMakesMoneyAtRiskEqualItsCharge() {
        let item = TestItem(status: .awaitingCore, expectedCredit: Money(cents: 8_650))
        let summary = RiskCalculator.summarize([item], now: now, calendar: calendar)

        #expect(summary.moneyAtRisk == Money(cents: 8_650))
        #expect(summary.unresolvedCount == 1)
        #expect(summary.overdueCount == 0)
        #expect(summary.overdueAmount == Money.zero)
        #expect(summary.hasAnyItems)
    }

    @Test("Only unresolved items contribute to money at risk")
    func onlyUnresolvedItemsContributeToMoneyAtRisk() {
        let items = [
            TestItem(status: .awaitingCore, expectedCredit: Money(cents: 8_650)),
            TestItem(status: .readyToReturn, expectedCredit: Money(cents: 5_400)),
            TestItem(status: .credited, expectedCredit: Money(cents: 22_000),
                     actualCredit: Money(cents: 22_000)),
            TestItem(status: .writtenOff, expectedCredit: Money(cents: 3_150))
        ]

        let summary = RiskCalculator.summarize(items, now: now, calendar: calendar)
        #expect(summary.moneyAtRisk == Money(cents: 14_050))
        #expect(summary.unresolvedCount == 2)
        #expect(RiskCalculator.unresolvedCount(items) == 2)
    }

    @Test("Status counts and amounts cover every status present, closed ones included")
    func statusCountsAndAmountsCoverEveryStatus() {
        let items = [
            TestItem(status: .awaitingCore, expectedCredit: Money(cents: 8_650)),
            TestItem(status: .awaitingCore, expectedCredit: Money(cents: 1_350)),
            TestItem(status: .credited, expectedCredit: Money(cents: 22_000),
                     actualCredit: Money(cents: 22_000))
        ]

        let summary = RiskCalculator.summarize(items, now: now, calendar: calendar)
        #expect(summary.count(for: .awaitingCore) == 2)
        #expect(summary.amount(for: .awaitingCore) == Money(cents: 10_000))
        #expect(summary.count(for: .credited) == 1)
        #expect(summary.amount(for: .credited) == Money(cents: 22_000))
        #expect(summary.count(for: .disputed) == 0)
        #expect(summary.amount(for: .disputed) == Money.zero)
    }

    @Test("A summary always carries three aging buckets in order")
    func summariesAlwaysCarryThreeBuckets() {
        let old = TestItem(status: .awaitingCore, expectedCredit: Money(cents: 8_650),
                           receivedDate: TestClock.date(year: 2026, month: 1, day: 1))
        let fresh = TestItem(status: .awaitingCore, expectedCredit: Money(cents: 1_000),
                             receivedDate: TestClock.date(year: 2026, month: 3, day: 10))

        let summary = RiskCalculator.summarize([old, fresh], now: now, calendar: calendar)
        #expect(summary.agingBuckets.count == 3)
        #expect(summary.agingBuckets.map(\.bucket) == AgingBucket.allCases)
        #expect(summary.aging(.zeroToSeven).count == 1)
        #expect(summary.aging(.zeroToSeven).amount == Money(cents: 1_000))
        #expect(summary.aging(.thirtyOnePlus).count == 1)
        #expect(summary.aging(.thirtyOnePlus).amount == Money(cents: 8_650))
        #expect(summary.aging(.eightToThirty).count == 0)
        #expect(summary.aging(.eightToThirty).amount == Money.zero)
    }

    @Test("Overdue totals are measured against the injected clock only")
    func overdueTotalsUseTheInjectedClock() {
        let overdue = TestItem(status: .readyToReturn, expectedCredit: Money(cents: 8_650),
                               dueDate: TestClock.date(year: 2026, month: 3, day: 11))
        let dueToday = TestItem(status: .readyToReturn, expectedCredit: Money(cents: 5_400),
                                dueDate: TestClock.date(year: 2026, month: 3, day: 12, hour: 23))
        let closedButLate = TestItem(status: .credited, expectedCredit: Money(cents: 9_900),
                                     actualCredit: Money(cents: 9_900),
                                     dueDate: TestClock.date(year: 2026, month: 1, day: 1))

        let summary = RiskCalculator.summarize([overdue, dueToday, closedButLate],
                                               now: now, calendar: calendar)
        #expect(summary.overdueCount == 1)
        #expect(summary.overdueAmount == Money(cents: 8_650))
        #expect(summary.moneyAtRisk == Money(cents: 14_050))
    }

    @Test("Money at risk on a disputed core is only what is still owed")
    func disputedItemsContributeOnlyTheirShortfall() {
        let disputed = TestItem(status: .disputed, expectedCredit: Money(cents: 8_650),
                                actualCredit: Money(cents: 7_500))
        let summary = RiskCalculator.summarize([disputed], now: now, calendar: calendar)

        #expect(summary.moneyAtRisk == Money(cents: 1_150))
        #expect(summary.amount(for: .disputed) == Money(cents: 8_650))
        #expect(summary.unresolvedCount == 1)
    }

    @Test("An empty summary reports nothing but still has three buckets")
    func theEmptySummaryIsWellFormed() {
        let empty = RiskSummary.empty
        #expect(empty.hasAnyItems == false)
        #expect(empty.moneyAtRisk == Money.zero)
        #expect(empty.overdueAmount == Money.zero)
        #expect(empty.overdueCount == 0)
        #expect(empty.unresolvedCount == 0)
        #expect(empty.agingBuckets.count == 3)
        #expect(empty.count(for: .awaitingCore) == 0)
        #expect(empty.amount(for: .awaitingCore) == Money.zero)
        #expect(empty.aging(.eightToThirty).amount == Money.zero)

        let summarised: [TestItem] = []
        #expect(RiskCalculator.summarize(summarised, now: now, calendar: calendar) == empty)
    }

    @Test("Aging bucket summaries are identified by their bucket")
    func agingBucketSummaryIdentity() {
        let summary = AgingBucketSummary(bucket: .eightToThirty, count: 2, amount: Money(cents: 500))
        #expect(summary.id == AgingBucket.eightToThirty.rawValue)
        #expect(summary.count == 2)
        #expect(summary.amount == Money(cents: 500))
    }
}
