//
//  AgingAndDueDateTests.swift
//  CoreCreditTests
//
//  Required scenario 7: due/overdue and aging-bucket boundaries are deterministic under the
//  injected clock and calendar.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Due dates, overdue boundaries, and aging buckets are deterministic")
struct AgingAndDueDateTests {

    private let calendar = TestClock.calendar
    private let now = TestClock.date(year: 2026, month: 3, day: 12)

    // MARK: - Overdue boundary

    @Test("A core due today is not overdue, and one due yesterday is")
    func dueTodayIsNotOverdueButDueYesterdayIs() {
        let dueToday = TestItem(
            status: .awaitingCore,
            dueDate: TestClock.date(year: 2026, month: 3, day: 12, hour: 23)
        )
        let dueYesterday = TestItem(
            status: .awaitingCore,
            dueDate: TestClock.date(year: 2026, month: 3, day: 11, hour: 1)
        )
        let dueTomorrow = TestItem(
            status: .awaitingCore,
            dueDate: TestClock.date(year: 2026, month: 3, day: 13, hour: 0)
        )

        #expect(RiskCalculator.isOverdue(dueToday, now: now, calendar: calendar) == false)
        #expect(RiskCalculator.isOverdue(dueYesterday, now: now, calendar: calendar) == true)
        #expect(RiskCalculator.isOverdue(dueTomorrow, now: now, calendar: calendar) == false)
    }

    @Test("A closed core is never overdue, however old its deadline is")
    func closedItemsAreNeverOverdue() {
        let credited = TestItem(
            status: .credited,
            dueDate: TestClock.date(year: 2025, month: 1, day: 1)
        )
        let writtenOff = TestItem(
            status: .writtenOff,
            dueDate: TestClock.date(year: 2025, month: 1, day: 1)
        )
        #expect(RiskCalculator.isOverdue(credited, now: now, calendar: calendar) == false)
        #expect(RiskCalculator.isOverdue(writtenOff, now: now, calendar: calendar) == false)
    }

    @Test("An item with no due date is never overdue")
    func itemsWithoutDeadlinesAreNeverOverdue() {
        let noDeadline = TestItem(status: .readyToReturn)
        #expect(RiskCalculator.isOverdue(noDeadline, now: now, calendar: calendar) == false)
    }

    @Test("Days until due counts whole calendar days and goes negative once passed")
    func daysUntilDueCountsWholeCalendarDays() {
        let dueInAWeek = TestItem(
            status: .awaitingCore,
            dueDate: TestClock.date(year: 2026, month: 3, day: 19, hour: 3)
        )
        let dueToday = TestItem(
            status: .awaitingCore,
            dueDate: TestClock.date(year: 2026, month: 3, day: 12, hour: 23)
        )
        let dueYesterday = TestItem(
            status: .awaitingCore,
            dueDate: TestClock.date(year: 2026, month: 3, day: 11)
        )

        #expect(RiskCalculator.daysUntilDue(dueInAWeek, now: now, calendar: calendar) == 7)
        #expect(RiskCalculator.daysUntilDue(dueToday, now: now, calendar: calendar) == 0)
        #expect(RiskCalculator.daysUntilDue(dueYesterday, now: now, calendar: calendar) == -1)
    }

    @Test("Days until due is nil for a closed item and for an item with no deadline")
    func daysUntilDueIsNilWhenThereIsNothingToChase() {
        let closed = TestItem(
            status: .credited,
            dueDate: TestClock.date(year: 2026, month: 3, day: 19)
        )
        let undated = TestItem(status: .awaitingCore)

        #expect(RiskCalculator.daysUntilDue(closed, now: now, calendar: calendar) == nil)
        #expect(RiskCalculator.daysUntilDue(undated, now: now, calendar: calendar) == nil)
    }

    // MARK: - Due date arithmetic

    @Test("A due date is the start of the received day plus the clamped vendor window")
    func dueDateAddsTheWindowToTheStartOfTheReceivedDay() {
        let received = TestClock.date(year: 2026, month: 3, day: 12, hour: 23)
        let due = DueDateCalculator.dueDate(receivedDate: received, windowDays: 30, calendar: calendar)
        #expect(due == TestClock.date(year: 2026, month: 4, day: 11, hour: 0))

        let shortWindow = DueDateCalculator.dueDate(receivedDate: received, windowDays: 14, calendar: calendar)
        #expect(shortWindow == TestClock.date(year: 2026, month: 3, day: 26, hour: 0))
    }

    @Test("Two cores received on the same day get the same deadline whatever the clock said")
    func timeOfDayDoesNotChangeTheDeadline() {
        let morning = TestClock.date(year: 2026, month: 3, day: 12, hour: 6)
        let evening = TestClock.date(year: 2026, month: 3, day: 12, hour: 22)
        #expect(
            DueDateCalculator.dueDate(receivedDate: morning, windowDays: 30, calendar: calendar)
                == DueDateCalculator.dueDate(receivedDate: evening, windowDays: 30, calendar: calendar)
        )
    }

    @Test("Vendor windows are clamped to one through three hundred and sixty-five days")
    func windowDaysAreClamped() {
        #expect(DueDateCalculator.minimumWindowDays == 1)
        #expect(DueDateCalculator.maximumWindowDays == 365)
        #expect(DueDateCalculator.clampWindowDays(0) == 1)
        #expect(DueDateCalculator.clampWindowDays(-9) == 1)
        #expect(DueDateCalculator.clampWindowDays(30) == 30)
        #expect(DueDateCalculator.clampWindowDays(400) == 365)
    }

    @Test("Day difference is signed and normalised to whole days")
    func dayDifferenceIsSignedAndNormalised() {
        let start = TestClock.date(year: 2026, month: 3, day: 12, hour: 9)
        let later = TestClock.date(year: 2026, month: 3, day: 19, hour: 23)
        let sameDay = TestClock.date(year: 2026, month: 3, day: 12, hour: 1)

        #expect(DueDateCalculator.dayDifference(from: start, to: later, calendar: calendar) == 7)
        #expect(DueDateCalculator.dayDifference(from: later, to: start, calendar: calendar) == -7)
        #expect(DueDateCalculator.dayDifference(from: start, to: sameDay, calendar: calendar) == 0)
    }

    // MARK: - Aging buckets

    @Test("Bucket boundaries fall exactly at seven, eight, thirty, and thirty-one days")
    func bucketBoundariesAreExact() {
        #expect(AgingBucket.bucket(forDays: 0) == .zeroToSeven)
        #expect(AgingBucket.bucket(forDays: 7) == .zeroToSeven)
        #expect(AgingBucket.bucket(forDays: 8) == .eightToThirty)
        #expect(AgingBucket.bucket(forDays: 30) == .eightToThirty)
        #expect(AgingBucket.bucket(forDays: 31) == .thirtyOnePlus)
        #expect(AgingBucket.bucket(forDays: 900) == .thirtyOnePlus)
    }

    @Test("A negative age clamps into the youngest bucket")
    func negativeAgesClampToTheYoungestBucket() {
        #expect(AgingBucket.bucket(forDays: -3) == .zeroToSeven)

        let receivedTomorrow = TestItem(
            status: .awaitingCore,
            receivedDate: TestClock.date(year: 2026, month: 3, day: 13)
        )
        #expect(RiskCalculator.ageInDays(receivedTomorrow, now: now, calendar: calendar) == 0)
        #expect(RiskCalculator.agingBucket(receivedTomorrow, now: now, calendar: calendar) == .zeroToSeven)
    }

    @Test("Ages of seven, eight, thirty, and thirty-one days land in the right buckets")
    func itemAgesLandInTheRightBuckets() {
        let today = TestClock.date(year: 2026, month: 4, day: 12)

        let sevenDays = TestItem(receivedDate: TestClock.date(year: 2026, month: 4, day: 5))
        let eightDays = TestItem(receivedDate: TestClock.date(year: 2026, month: 4, day: 4))
        let thirtyDays = TestItem(receivedDate: TestClock.date(year: 2026, month: 3, day: 13))
        let thirtyOneDays = TestItem(receivedDate: TestClock.date(year: 2026, month: 3, day: 12))

        #expect(RiskCalculator.ageInDays(sevenDays, now: today, calendar: calendar) == 7)
        #expect(RiskCalculator.ageInDays(eightDays, now: today, calendar: calendar) == 8)
        #expect(RiskCalculator.ageInDays(thirtyDays, now: today, calendar: calendar) == 30)
        #expect(RiskCalculator.ageInDays(thirtyOneDays, now: today, calendar: calendar) == 31)

        #expect(RiskCalculator.agingBucket(sevenDays, now: today, calendar: calendar) == .zeroToSeven)
        #expect(RiskCalculator.agingBucket(eightDays, now: today, calendar: calendar) == .eightToThirty)
        #expect(RiskCalculator.agingBucket(thirtyDays, now: today, calendar: calendar) == .eightToThirty)
        #expect(RiskCalculator.agingBucket(thirtyOneDays, now: today, calendar: calendar) == .thirtyOnePlus)
    }

    @Test("Bucket labels and bounds match the contract")
    func bucketLabelsAndBounds() {
        #expect(AgingBucket.allCases == [.zeroToSeven, .eightToThirty, .thirtyOnePlus])
        #expect(AgingBucket.zeroToSeven.displayName == "0\u{2013}7 days")
        #expect(AgingBucket.eightToThirty.displayName == "8\u{2013}30 days")
        #expect(AgingBucket.thirtyOnePlus.displayName == "31+ days")
        #expect(AgingBucket.zeroToSeven.shortName == "0\u{2013}7")
        #expect(AgingBucket.eightToThirty.shortName == "8\u{2013}30")
        #expect(AgingBucket.thirtyOnePlus.shortName == "31+")
        #expect(AgingBucket.zeroToSeven.lowerBoundDays == 0)
        #expect(AgingBucket.eightToThirty.lowerBoundDays == 8)
        #expect(AgingBucket.thirtyOnePlus.lowerBoundDays == 31)
        #expect(AgingBucket.zeroToSeven.upperBoundDays == 7)
        #expect(AgingBucket.eightToThirty.upperBoundDays == 30)
        #expect(AgingBucket.thirtyOnePlus.upperBoundDays == nil)
        #expect(AgingBucket.thirtyOnePlus.id == AgingBucket.thirtyOnePlus.rawValue)
    }

    // MARK: - Reference date

    @Test("Age is measured from the last thing that actually happened to the core")
    func referenceDateFollowsTheLastEvent() {
        let received = TestClock.date(year: 2026, month: 3, day: 1)
        let returned = TestClock.date(year: 2026, month: 3, day: 5)
        let credited = TestClock.date(year: 2026, month: 3, day: 9)

        let awaiting = TestItem(status: .awaitingCore, receivedDate: received,
                                returnedDate: returned, creditedDate: credited)
        let ready = TestItem(status: .readyToReturn, receivedDate: received,
                             returnedDate: returned, creditedDate: credited)
        let returnedAwaiting = TestItem(status: .returnedAwaitingCredit, receivedDate: received,
                                        returnedDate: returned, creditedDate: credited)
        let returnedWithNoStamp = TestItem(status: .returnedAwaitingCredit, receivedDate: received)
        let disputed = TestItem(status: .disputed, receivedDate: received,
                                returnedDate: returned, creditedDate: credited)
        let creditedNoDate = TestItem(status: .credited, receivedDate: received,
                                      returnedDate: returned)
        let writtenOffBare = TestItem(status: .writtenOff, receivedDate: received)

        #expect(RiskCalculator.referenceDate(for: awaiting) == received)
        #expect(RiskCalculator.referenceDate(for: ready) == received)
        #expect(RiskCalculator.referenceDate(for: returnedAwaiting) == returned)
        #expect(RiskCalculator.referenceDate(for: returnedWithNoStamp) == received)
        #expect(RiskCalculator.referenceDate(for: disputed) == credited)
        #expect(RiskCalculator.referenceDate(for: creditedNoDate) == returned)
        #expect(RiskCalculator.referenceDate(for: writtenOffBare) == received)
    }

    // MARK: - Draft due dates

    @Test("A draft uses the vendor window unless a custom due date is pinned")
    func draftResolvesItsDueDate() {
        let received = TestClock.date(year: 2026, month: 3, day: 12, hour: 17)

        let vendorWindow = CoreItemDraft(receivedDate: received)
        #expect(
            vendorWindow.resolvedDueDate(vendorWindowDays: 30, calendar: calendar)
                == TestClock.date(year: 2026, month: 4, day: 11, hour: 0)
        )

        let custom = CoreItemDraft(
            receivedDate: received,
            usesCustomDueDate: true,
            customDueDate: TestClock.date(year: 2026, month: 3, day: 20, hour: 16)
        )
        #expect(
            custom.resolvedDueDate(vendorWindowDays: 30, calendar: calendar)
                == TestClock.date(year: 2026, month: 3, day: 20, hour: 0)
        )

        let customButUnset = CoreItemDraft(receivedDate: received, usesCustomDueDate: true)
        #expect(
            customButUnset.resolvedDueDate(vendorWindowDays: 30, calendar: calendar)
                == TestClock.date(year: 2026, month: 4, day: 11, hour: 0)
        )
    }
}
