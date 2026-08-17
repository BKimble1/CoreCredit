//
//  ReminderPlannerTests.swift
//  CoreCreditTests
//
//  Required scenario 12: reminders are planned from an injected clock and calendar, are never
//  scheduled into the past, and carry an identifier derived from the item so re-planning replaces
//  the pending alert instead of stacking a second one.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Reminders are planned deterministically and never fire into the past")
struct ReminderPlannerTests {

    // MARK: - Fixtures

    private let calendar = TestClock.calendar

    /// 12 March 2026, 12:00 UTC. Every expectation below is measured from this instant.
    private let now = TestClock.referenceNow

    /// The core every planner test starts from: an open alternator due on Friday 20 March 2026,
    /// eight days after `now`, so a three-day lead still lands in the future.
    ///
    /// Computed rather than stored, so each access yields a fresh `identifier` — tests that care
    /// about identity bind it to a `let` first.
    private var alternator: TestItem {
        TestItem(partName: "Alternator",
                 partNumber: "03-1887",
                 binLabel: "A3",
                 vendorName: "NAPA",
                 status: .awaitingCore,
                 expectedCredit: Money(cents: 8_650),
                 receivedDate: TestClock.date(year: 2026, month: 3, day: 10),
                 dueDate: TestClock.date(year: 2026, month: 3, day: 20))
    }

    /// The planner call with this suite's clock and calendar already wired in.
    private func makePlan(for item: TestItem,
                          leadDays: Int = 3,
                          hour: Int = 8,
                          minute: Int = 0,
                          now: Date = TestClock.referenceNow,
                          currencyCode: String = "USD") -> CoreReminderRequest? {
        ReminderPlanner.plan(for: item,
                             leadDays: leadDays,
                             hour: hour,
                             minute: minute,
                             now: now,
                             calendar: TestClock.calendar,
                             currencyCode: currencyCode)
    }

    /// The fire date broken into the fields this suite asserts on.
    private func fireComponents(_ request: CoreReminderRequest) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                from: request.fireDate)
    }

    /// The amount text the planner will embed, built through `Money.formatted` itself.
    ///
    /// The planner does not pass a locale, so `Money.formatted` falls back to the machine's own
    /// region and the literal text of `$86.50` is not fixed. Comparing like with like keeps these
    /// assertions about the **currency code the caller passed**, which is the contract under test.
    private func amountText(_ currencyCode: String) -> String {
        Money(cents: 8_650).formatted(currencyCode: currencyCode)
    }

    // MARK: - When there is nothing to remind about

    @Test("A closed core never gets a reminder, however far out its deadline is")
    func closedCoresNeverGetAReminder() {
        for status in CoreStatus.closedCases {
            var item = alternator
            item.status = status
            #expect(makePlan(for: item) == nil)
        }
        #expect(CoreStatus.closedCases == [.credited, .writtenOff])
    }

    @Test("Every unresolved status still gets a reminder, disputed included")
    func everyUnresolvedStatusGetsAReminder() {
        for status in CoreStatus.unresolvedCases {
            var item = alternator
            item.status = status
            #expect(makePlan(for: item) != nil)
        }
    }

    @Test("A core with no due date has no deadline to warn about")
    func aCoreWithNoDueDateGetsNoReminder() {
        var item = alternator
        item.dueDate = nil
        #expect(makePlan(for: item) == nil)
    }

    @Test("A fire date that has already passed produces no reminder at all")
    func aFireDateInThePastProducesNoReminder() throws {
        var item = alternator
        item.dueDate = TestClock.date(year: 2026, month: 3, day: 13)

        // Three days before 13 March is 10 March, two days behind `now`.
        #expect(makePlan(for: item, leadDays: 3) == nil)

        // The same core, warned about on the evening of the twelfth, is still in the future.
        let sameDay = try #require(makePlan(for: item, leadDays: 0, hour: 18))
        #expect(sameDay.fireDate > now)
    }

    @Test("A fire date exactly equal to now is treated as past; one minute later is not")
    func aFireDateEqualToNowIsTreatedAsPast() throws {
        var item = alternator
        item.dueDate = TestClock.date(year: 2026, month: 3, day: 12)

        // `now` is 12:00 UTC on the twelfth, which is exactly this fire date.
        #expect(makePlan(for: item, leadDays: 0, hour: 12, minute: 0) == nil)

        let oneMinuteLater = try #require(makePlan(for: item, leadDays: 0, hour: 12, minute: 1))
        #expect(fireComponents(oneMinuteLater).hour == 12)
        #expect(fireComponents(oneMinuteLater).minute == 1)
    }

    // MARK: - The fire date

    @Test("A three-day lead at 08:00 fires at 08:00 on the seventeenth of March")
    func aThreeDayLeadAtEightFiresOnTheSeventeenth() throws {
        let request = try #require(makePlan(for: alternator, leadDays: 3, hour: 8, minute: 0))
        let components = fireComponents(request)

        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 17)
        #expect(components.hour == 8)
        #expect(components.minute == 0)
        #expect(components.second == 0)
        #expect(request.fireDate > now)
        #expect(request.title == "Core return due Friday")
    }

    @Test("A due date exactly the lead days away fires later the same day")
    func aDueDateExactlyTheLeadDaysAwayFiresToday() throws {
        var item = alternator
        item.dueDate = TestClock.date(year: 2026, month: 3, day: 15)

        // Three days before the fifteenth is the twelfth — today — so the hour decides.
        #expect(makePlan(for: item, leadDays: 3, hour: 8) == nil)

        let request = try #require(makePlan(for: item, leadDays: 3, hour: 18, minute: 30))
        let components = fireComponents(request)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 12)
        #expect(components.hour == 18)
        #expect(components.minute == 30)
        #expect(request.title == "Core return due Sunday")
    }

    @Test("A zero-day lead fires on the morning the core is due")
    func aZeroDayLeadFiresOnTheMorningItIsDue() throws {
        var item = alternator
        item.dueDate = TestClock.date(year: 2026, month: 3, day: 14)

        let request = try #require(makePlan(for: item, leadDays: 0, hour: 8, minute: 0))
        let components = fireComponents(request)

        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 14)
        #expect(components.hour == 8)
        #expect(components.minute == 0)
        #expect(request.title == "Core return due today")
    }

    @Test("Lead days, hours, and minutes outside their range are clamped, not rejected")
    func outOfRangeLeadHourAndMinuteAreClamped() throws {
        let item = alternator

        let negativeLead = try #require(makePlan(for: item, leadDays: -5))
        let zeroLead = try #require(makePlan(for: item, leadDays: 0))
        #expect(negativeLead == zeroLead)
        #expect(fireComponents(zeroLead).day == 20)

        let late = try #require(makePlan(for: item, leadDays: 3, hour: 99, minute: 99))
        #expect(fireComponents(late).hour == 23)
        #expect(fireComponents(late).minute == 59)

        let early = try #require(makePlan(for: item, leadDays: 3, hour: -4, minute: -30))
        #expect(fireComponents(early).hour == 0)
        #expect(fireComponents(early).minute == 0)

        // A lead longer than a year collapses onto the 365-day maximum.
        var distant = alternator
        distant.dueDate = TestClock.date(year: 2028, month: 3, day: 20)
        let absurdLead = try #require(makePlan(for: distant, leadDays: 10_000))
        let maximumLead = try #require(makePlan(for: distant,
                                                leadDays: ReminderPlanner.maximumLeadDays))
        #expect(absurdLead.fireDate == maximumLead.fireDate)
        #expect(ReminderPlanner.minimumLeadDays == 0)
        #expect(ReminderPlanner.maximumLeadDays == 365)
    }

    // MARK: - Identity

    @Test("The identifier is derived from the item id, so re-planning replaces instead of stacking")
    func theIdentifierIsDerivedFromTheItemID() throws {
        let item = alternator
        let otherItem = alternator

        let first = try #require(makePlan(for: item, leadDays: 3, hour: 8))
        let second = try #require(makePlan(for: item, leadDays: 5, hour: 17, minute: 30))
        let other = try #require(makePlan(for: otherItem, leadDays: 3, hour: 8))

        #expect(first.identifier == second.identifier)
        #expect(first.identifier != other.identifier)
        #expect(first.fireDate != second.fireDate)

        #expect(first.itemID == item.identifier)
        #expect(first.identifier == CoreReminderRequest.identifier(for: item.identifier))
        #expect(first.identifier == CoreReminderRequest.identifierPrefix + item.identifier.uuidString)
        #expect(first.identifier.hasPrefix(CoreReminderRequest.identifierPrefix))
    }

    // MARK: - Wording

    @Test("The deadline is described relative to the day the alert lands, not to today")
    func theDeadlineIsDescribedRelativeToTheFireDate() throws {
        var dueSaturday = alternator
        dueSaturday.dueDate = TestClock.date(year: 2026, month: 3, day: 14)

        let today = try #require(makePlan(for: dueSaturday, leadDays: 0))
        #expect(today.title == "Core return due today")

        let tomorrow = try #require(makePlan(for: dueSaturday, leadDays: 1))
        #expect(tomorrow.title == "Core return due tomorrow")

        let weekday = try #require(makePlan(for: alternator, leadDays: 3))
        #expect(weekday.title == "Core return due Friday")

        var dueInApril = alternator
        dueInApril.dueDate = TestClock.date(year: 2026, month: 4, day: 9)
        let farOut = try #require(makePlan(for: dueInApril, leadDays: 10))
        #expect(farOut.title == "Core return due Apr 9")
    }

    @Test("The body names the part, the amount in the caller's currency, the vendor, and the bin")
    func theBodyNamesThePartAndTheFormattedAmount() throws {
        let item = alternator

        let dollars = try #require(makePlan(for: item, currencyCode: "USD"))
        let euros = try #require(makePlan(for: item, currencyCode: "EUR"))

        #expect(dollars.body == "Alternator (03-1887) \u{2014} " + amountText("USD") + " to NAPA. Bin A3.")
        #expect(euros.body == "Alternator (03-1887) \u{2014} " + amountText("EUR") + " to NAPA. Bin A3.")

        #expect(dollars.body.contains("Alternator"))
        #expect(dollars.body.contains("03-1887"))
        #expect(dollars.body.contains(amountText("USD")))
        #expect(dollars.title.contains("Core return due"))
    }

    @Test("A core with no part number, vendor, or bin still reads as a complete sentence")
    func aBareCoreStillReadsAsASentence() throws {
        var bare = alternator
        bare.partName = "   "
        bare.partNumber = ""
        bare.vendorName = nil
        bare.binLabel = nil

        let request = try #require(makePlan(for: bare))
        #expect(request.body == "Core \u{2014} " + amountText("USD") + ".")

        var blankVendorAndBin = alternator
        blankVendorAndBin.vendorName = "  "
        blankVendorAndBin.binLabel = " "
        let trimmedAway = try #require(makePlan(for: blankVendorAndBin))
        #expect(trimmedAway.body == "Alternator (03-1887) \u{2014} " + amountText("USD") + ".")
    }

    // MARK: - The recording scheduler

    @Test("Scheduling records the request and cancelling by item id clears it")
    func schedulingRecordsTheRequestAndCancellingClearsIt() async throws {
        let item = alternator
        let request = try #require(makePlan(for: item))
        let scheduler = RecordingNotificationScheduler()

        try await scheduler.schedule(request)

        #expect(scheduler.scheduledRequests == [request])
        #expect(scheduler.scheduledRequest(for: item.identifier) == request)
        let pending = await scheduler.pendingIdentifiers()
        #expect(pending == [request.identifier])

        await scheduler.cancel(itemIDs: [item.identifier])

        #expect(scheduler.cancelledIDs == [item.identifier])
        #expect(scheduler.scheduledRequests.isEmpty)
        let afterCancel = await scheduler.pendingIdentifiers()
        #expect(afterCancel.isEmpty)
    }

    @Test("Re-scheduling the same core replaces its pending reminder instead of stacking one")
    func reschedulingReplacesThePendingReminder() async throws {
        let item = alternator
        let first = try #require(makePlan(for: item, leadDays: 3, hour: 8))
        let second = try #require(makePlan(for: item, leadDays: 5, hour: 17, minute: 30))
        let scheduler = RecordingNotificationScheduler()

        try await scheduler.schedule(first)
        try await scheduler.schedule(second)

        #expect(scheduler.scheduledRequests == [second])
        let pending = await scheduler.pendingIdentifiers()
        #expect(pending == [second.identifier])
    }

    @Test("Scheduling while notifications are denied throws and records nothing")
    func schedulingWhileDeniedThrows() async throws {
        let item = alternator
        let request = try #require(makePlan(for: item))
        let scheduler = RecordingNotificationScheduler(status: .denied)

        await #expect(throws: NotificationSchedulingError.notAuthorized) {
            try await scheduler.schedule(request)
        }
        #expect(scheduler.scheduledRequests.isEmpty)
        let pending = await scheduler.pendingIdentifiers()
        #expect(pending.isEmpty)

        scheduler.setAuthorizationStatus(.authorized)
        try await scheduler.schedule(request)
        #expect(scheduler.scheduledRequests == [request])
    }

    @Test("Cancelling nothing records nothing, and cancelAll empties the queue")
    func cancellingNothingRecordsNothingAndCancelAllEmptiesTheQueue() async throws {
        let request = try #require(makePlan(for: alternator))
        let scheduler = RecordingNotificationScheduler()

        try await scheduler.schedule(request)
        await scheduler.cancel(itemIDs: [])

        #expect(scheduler.cancelledIDs.isEmpty)
        #expect(scheduler.scheduledRequests == [request])

        await scheduler.cancelAll()

        #expect(scheduler.cancelAllCount == 1)
        #expect(scheduler.scheduledRequests.isEmpty)
        let pending = await scheduler.pendingIdentifiers()
        #expect(pending.isEmpty)

        // Permission is never requested as a side effect of scheduling or cancelling.
        #expect(scheduler.authorizationRequestCount == 0)
    }
}
