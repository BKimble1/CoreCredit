//
//  ReminderEligibilityTests.swift
//  CoreCreditTests
//
//  *Which* reminders a core deserves, and *exactly when* each one fires.
//
//  `ReminderPlanner` is pure: `now` and `calendar` are always parameters, never the system clock.
//  Every instant below is measured from `TestClock.referenceNow` — 12 March 2026, 12:00 UTC, a
//  Thursday — so these expectations read the same in Columbus and in Auckland.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("A core is only reminded about while it is still open, and never into the past")
struct ReminderEligibilityTests {

    // MARK: - Fixtures

    private let calendar = TestClock.calendar

    /// 12 March 2026, 12:00 UTC. Midday matters: an 08:00 reminder for today has already passed.
    private let now = TestClock.referenceNow

    /// Friday 20 March 2026 — eight days out, so even a seven-day lead is still ahead of `now`.
    private let dueFriday = TestClock.date(year: 2026, month: 3, day: 20)

    /// A synthetic core. No real vendor, part number, or repair order appears in this suite.
    private func makeItem(status: CoreStatus = .awaitingCore,
                          dueDate: Date? = nil,
                          returnedDate: Date? = nil,
                          creditedDate: Date? = nil,
                          actualCredit: Money? = nil) -> TestItem {
        var item = TestItem()
        item.partName = "Widget core"
        item.partNumber = "ZX-0042"
        item.vendorName = "Vendor Alpha"
        item.binLabel = "B7"
        item.expectedCredit = Money(cents: 12_345)
        item.status = status
        item.dueDate = dueDate
        item.returnedDate = returnedDate
        item.creditedDate = creditedDate
        item.actualCredit = actualCredit
        return item
    }

    /// Default settings unless a test says otherwise: warn 7, 3, and 1 days out, at 08:00.
    private func makeOptions(dueSoonLeadDays: [Int] = ReminderPlanner.defaultDueSoonLeadDays,
                             hour: Int = 8,
                             minute: Int = 0,
                             awaitingCreditDelayDays: Int = ReminderPlanner.defaultAwaitingCreditDelayDays,
                             disputeFollowUpDelayDays: Int = ReminderPlanner.defaultDisputeFollowUpDelayDays)
        -> ReminderPlanningOptions {
        ReminderPlanningOptions(dueSoonLeadDays: dueSoonLeadDays,
                                hour: hour,
                                minute: minute,
                                awaitingCreditDelayDays: awaitingCreditDelayDays,
                                disputeFollowUpDelayDays: disputeFollowUpDelayDays)
    }

    private func plan(_ item: TestItem, options: ReminderPlanningOptions) -> [CoreReminderRequest] {
        ReminderPlanner.requests(for: item, options: options, now: now, calendar: calendar)
    }

    private func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// The one request of a given kind, or a recorded failure if there is not exactly one.
    private func onlyRequest(_ requests: [CoreReminderRequest],
                             kind: ReminderKind) throws -> CoreReminderRequest {
        let matches = requests.filter { $0.kind == kind }
        #expect(matches.count == 1, "Expected exactly one \(kind.rawValue) reminder.")
        return try #require(matches.first)
    }

    // MARK: - Status

    @Test("A closed core is never reminded about, whatever else is true of it")
    func aClosedCoreIsNeverRemindedAbout() {
        #expect(CoreStatus.closedCases == [.credited, .writtenOff])

        for status in CoreStatus.closedCases {
            let item = makeItem(status: status,
                                dueDate: dueFriday,
                                returnedDate: TestClock.date(year: 2026, month: 3, day: 10),
                                creditedDate: TestClock.date(year: 2026, month: 3, day: 11),
                                actualCredit: Money(cents: 12_345))
            #expect(plan(item, options: makeOptions()).isEmpty,
                    "A \(status.rawValue) core has nothing left to chase.")
        }
    }

    @Test("Each open status produces exactly the kinds that apply to it")
    func eachOpenStatusProducesExactlyTheKindsThatApplyToIt() throws {
        let options = makeOptions()
        let returned = TestClock.date(year: 2026, month: 3, day: 10)

        // Every case of the enum is walked, so a new status cannot be added without a decision here.
        for status in CoreStatus.allCases {
            let item = makeItem(status: status, dueDate: dueFriday, returnedDate: returned)
            let kinds = Set(plan(item, options: options).map(\.kind))

            switch status {
            case .credited, .writtenOff:
                #expect(kinds.isEmpty)
            case .awaitingCore, .readyToReturn:
                #expect(kinds == [.dueSoon, .dueToday])
            case .returnedAwaitingCredit:
                #expect(kinds == [.dueSoon, .dueToday, .awaitingCredit])
            case .disputed:
                #expect(kinds == [.dueSoon, .dueToday, .disputeFollowUp])
            }
        }

        // One core, several reasons: three configured leads are three separate due-soon reminders.
        let open = makeItem(status: .returnedAwaitingCredit, dueDate: dueFriday, returnedDate: returned)
        let requests = plan(open, options: options)
        #expect(requests.count == 5)
        #expect(requests.filter { $0.kind == .dueSoon }.count == 3)
        #expect(requests.compactMap(\.leadDays).sorted() == [1, 3, 7])
    }

    @Test("A core with no deadline has no due-date reminder to give")
    func aCoreWithNoDeadlineHasNoDueDateReminder() {
        let item = makeItem(status: .readyToReturn, dueDate: nil)
        #expect(plan(item, options: makeOptions()).isEmpty)
    }

    // MARK: - The due-date boundary

    @Test("Due tomorrow warns this evening and again tomorrow evening")
    func dueTomorrowWarnsThisEveningAndAgainTomorrowEvening() throws {
        let options = makeOptions(dueSoonLeadDays: [1], hour: 18, minute: 30)
        let item = makeItem(dueDate: TestClock.date(year: 2026, month: 3, day: 13))
        let requests = plan(item, options: options)

        #expect(Set(requests.map(\.kind)) == [.dueSoon, .dueToday])

        let soon = try onlyRequest(requests, kind: .dueSoon)
        #expect(components(soon.fireDate).year == 2026)
        #expect(components(soon.fireDate).month == 3)
        #expect(components(soon.fireDate).day == 12)
        #expect(components(soon.fireDate).hour == 18)
        #expect(components(soon.fireDate).minute == 30)
        #expect(components(soon.fireDate).second == 0)
        #expect(soon.leadDays == 1)

        let today = try onlyRequest(requests, kind: .dueToday)
        #expect(components(today.fireDate).day == 13)
        #expect(components(today.fireDate).hour == 18)
        #expect(components(today.fireDate).minute == 30)
        #expect(today.leadDays == nil)
    }

    @Test("Due today is due, not overdue, and fires later the same day")
    func dueTodayIsDueAndNotOverdue() throws {
        let options = makeOptions(dueSoonLeadDays: [1], hour: 18, minute: 30)
        let item = makeItem(dueDate: TestClock.date(year: 2026, month: 3, day: 12))
        let requests = plan(item, options: options)

        // The deadline day itself belongs to `.dueToday`; yesterday's one-day lead is long gone.
        #expect(requests.map(\.kind) == [.dueToday])

        let today = try onlyRequest(requests, kind: .dueToday)
        #expect(components(today.fireDate).year == 2026)
        #expect(components(today.fireDate).month == 3)
        #expect(components(today.fireDate).day == 12)
        #expect(components(today.fireDate).hour == 18)
        #expect(components(today.fireDate).minute == 30)
        #expect(today.fireDate > now)
    }

    @Test("Due yesterday is overdue, and the nudge re-arms at the next reminder time")
    func dueYesterdayIsOverdueAndReArmsAtTheNextReminderTime() throws {
        let item = makeItem(dueDate: TestClock.date(year: 2026, month: 3, day: 11))

        // 18:30 today is still ahead of midday, so the nudge lands this evening.
        let thisEvening = plan(item, options: makeOptions(dueSoonLeadDays: [1], hour: 18, minute: 30))
        #expect(thisEvening.map(\.kind) == [.overdue])
        let evening = try onlyRequest(thisEvening, kind: .overdue)
        #expect(components(evening.fireDate).day == 12)
        #expect(components(evening.fireDate).hour == 18)
        #expect(components(evening.fireDate).minute == 30)

        // 08:00 today has already passed, so it lands tomorrow morning instead — never in the past.
        let tomorrowMorning = plan(item, options: makeOptions(dueSoonLeadDays: [1], hour: 8, minute: 0))
        let morning = try onlyRequest(tomorrowMorning, kind: .overdue)
        #expect(components(morning.fireDate).day == 13)
        #expect(components(morning.fireDate).hour == 8)
        #expect(components(morning.fireDate).minute == 0)
        #expect(morning.fireDate > now)

        // A core forty days late is still chased, measured from now rather than from the deadline.
        let longOverdue = makeItem(dueDate: TestClock.date(year: 2026, month: 1, day: 31))
        let stale = try onlyRequest(plan(longOverdue, options: makeOptions()), kind: .overdue)
        #expect(components(stale.fireDate).day == 13)
        #expect(stale.fireDate > now)
    }

    // MARK: - Awaiting credit

    @Test("Awaiting credit fires the configured number of days after the core went back")
    func awaitingCreditFiresTheConfiguredDelayAfterTheReturn() throws {
        let returned = TestClock.date(year: 2026, month: 3, day: 10, hour: 16, minute: 45)
        let item = makeItem(status: .returnedAwaitingCredit, dueDate: nil, returnedDate: returned)

        let requests = plan(item, options: makeOptions(awaitingCreditDelayDays: 7))
        let awaiting = try onlyRequest(requests, kind: .awaitingCredit)

        // Measured from the start of the return day, not from the hour it was handed over.
        #expect(components(awaiting.fireDate).year == 2026)
        #expect(components(awaiting.fireDate).month == 3)
        #expect(components(awaiting.fireDate).day == 17)
        #expect(components(awaiting.fireDate).hour == 8)
        #expect(components(awaiting.fireDate).minute == 0)
        #expect(awaiting.leadDays == nil)

        // A different delay moves it by exactly that many days.
        let shorter = try onlyRequest(plan(item, options: makeOptions(awaitingCreditDelayDays: 5)),
                                      kind: .awaitingCredit)
        #expect(components(shorter.fireDate).day == 15)
        #expect(components(shorter.fireDate).hour == 8)
        #expect(shorter.fireDate > now)

        // A delay short enough to land behind `now` produces nothing rather than a late alert.
        #expect(plan(item, options: makeOptions(awaitingCreditDelayDays: 1)).isEmpty)
    }

    @Test("A credit that has already been recorded ends the chase")
    func aRecordedCreditEndsTheChase() {
        let returned = TestClock.date(year: 2026, month: 3, day: 10)
        let options = makeOptions(awaitingCreditDelayDays: 7)

        let credited = makeItem(status: .returnedAwaitingCredit,
                                dueDate: nil,
                                returnedDate: returned,
                                actualCredit: Money(cents: 12_345))
        #expect(plan(credited, options: options).isEmpty)

        // Short-paid counts too: the amount is recorded, so this is a dispute, not a silence.
        let shortPaid = makeItem(status: .returnedAwaitingCredit,
                                 dueDate: nil,
                                 returnedDate: returned,
                                 actualCredit: Money(cents: 5_000))
        #expect(plan(shortPaid, options: options).isEmpty)

        // With no hand-off date there is nothing to measure from, so nothing is invented.
        let neverReturned = makeItem(status: .returnedAwaitingCredit, dueDate: nil, returnedDate: nil)
        #expect(plan(neverReturned, options: options).isEmpty)
    }

    // MARK: - Dispute follow-up

    @Test("A disputed core is followed up the configured number of days after the credit date")
    func aDisputedCoreIsFollowedUpAfterTheCreditDate() throws {
        let options = makeOptions(disputeFollowUpDelayDays: 4)
        let item = makeItem(status: .disputed,
                            dueDate: nil,
                            returnedDate: TestClock.date(year: 2026, month: 3, day: 8),
                            creditedDate: TestClock.date(year: 2026, month: 3, day: 11),
                            actualCredit: Money(cents: 5_000))

        let followUp = try onlyRequest(plan(item, options: options), kind: .disputeFollowUp)
        #expect(components(followUp.fireDate).year == 2026)
        #expect(components(followUp.fireDate).month == 3)
        #expect(components(followUp.fireDate).day == 15)
        #expect(components(followUp.fireDate).hour == 8)
        #expect(components(followUp.fireDate).minute == 0)

        // With no credit date the return date is the day the dispute began.
        let noCreditDate = makeItem(status: .disputed,
                                    dueDate: nil,
                                    returnedDate: TestClock.date(year: 2026, month: 3, day: 10))
        let fromReturn = try onlyRequest(plan(noCreditDate, options: options), kind: .disputeFollowUp)
        #expect(components(fromReturn.fireDate).day == 14)

        // And with neither, the day the core came off the vehicle.
        let bare = makeItem(status: .disputed, dueDate: nil)
        let fromReceipt = try onlyRequest(plan(bare, options: options), kind: .disputeFollowUp)
        #expect(components(fromReceipt.fireDate).day == 16)

        // Only a disputed core gets this reminder.
        let open = makeItem(status: .returnedAwaitingCredit,
                            dueDate: nil,
                            returnedDate: TestClock.date(year: 2026, month: 3, day: 10),
                            creditedDate: TestClock.date(year: 2026, month: 3, day: 11))
        #expect(plan(open, options: options).contains { $0.kind == .disputeFollowUp } == false)
    }

    // MARK: - Never into the past

    @Test("A moment that has already passed is dropped rather than fired late")
    func aMomentThatHasAlreadyPassedIsDropped() throws {
        let options = makeOptions()

        // Due in one day: the seven-, three-, and one-day leads are all behind midday today.
        let dueTomorrow = makeItem(dueDate: TestClock.date(year: 2026, month: 3, day: 13))
        let requests = plan(dueTomorrow, options: options)
        #expect(requests.map(\.kind) == [.dueToday])

        // Every kind, every item: nothing the planner returns is ever behind `now`.
        let everything = [
            makeItem(status: .awaitingCore, dueDate: dueFriday),
            makeItem(status: .readyToReturn, dueDate: TestClock.date(year: 2026, month: 2, day: 1)),
            makeItem(status: .returnedAwaitingCredit,
                     dueDate: dueFriday,
                     returnedDate: TestClock.date(year: 2026, month: 3, day: 9)),
            makeItem(status: .disputed,
                     dueDate: nil,
                     creditedDate: TestClock.date(year: 2026, month: 3, day: 1))
        ]
        for item in everything {
            for request in plan(item, options: options) {
                #expect(request.fireDate > now,
                        "A reminder must never be queued for a moment that has already passed.")
            }
        }

        // A dispute whose whole follow-up window closed weeks ago produces nothing at all.
        let staleDispute = makeItem(status: .disputed,
                                    dueDate: nil,
                                    creditedDate: TestClock.date(year: 2026, month: 1, day: 5))
        #expect(plan(staleDispute, options: makeOptions(disputeFollowUpDelayDays: 3)).isEmpty)

        // A lead of zero belongs to `.dueToday`, so the whole-ledger planner drops it from the leads.
        #expect(ReminderPlanner.normalizedLeadDays([0, -3, 7, 7, 1]) == [7, 1])
    }
}
