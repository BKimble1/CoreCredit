//
//  ReminderSchedulingTests.swift
//  CoreCreditTests
//
//  What actually reaches the queue: identifiers that replace rather than stack, a cap that is
//  honest about what it left out, copy that names nothing unless the shop asked it to, and a
//  permission that is never spent as a side effect of scheduling.
//
//  `RecordingNotificationScheduler` stands in for the notification centre throughout, and every
//  instant comes from `TestClock` — 12 March 2026, 12:00 UTC.
//

import Foundation
import Testing
import UserNotifications
@testable import CoreCredit

@Suite("Reminders queue deterministically, cap honestly, and say nothing the shop did not ask for")
struct ReminderSchedulingTests {

    // MARK: - Fixtures

    private let calendar = TestClock.calendar
    private let now = TestClock.referenceNow

    /// Friday 20 March 2026, eight days out.
    private let dueFriday = TestClock.date(year: 2026, month: 3, day: 20)

    /// 10 March 2026 — two days before `now`.
    private let handedBack = TestClock.date(year: 2026, month: 3, day: 10)

    private let vendorName = "Vendor Alpha"
    private let partName = "Widget core"
    private let partNumber = "ZX-0042"
    private let binLabel = "B7"
    private let expectedCredit = Money(cents: 12_345)

    /// The amount text the planner would embed, built through `Money.formatted` itself so the
    /// assertion is about the currency code the caller passed rather than the machine's region.
    private var amountText: String {
        Money(cents: 12_345).formatted(currencyCode: "USD")
    }

    private func makeItem(status: CoreStatus = .awaitingCore,
                          dueDate: Date? = nil,
                          returnedDate: Date? = nil,
                          creditedDate: Date? = nil,
                          actualCredit: Money? = nil) -> TestItem {
        var item = TestItem()
        item.partName = partName
        item.partNumber = partNumber
        item.vendorName = vendorName
        item.binLabel = binLabel
        item.expectedCredit = expectedCredit
        item.status = status
        item.dueDate = dueDate
        item.returnedDate = returnedDate
        item.creditedDate = creditedDate
        item.actualCredit = actualCredit
        return item
    }

    private func makeOptions(showsDetail: Bool = false,
                             includesWeeklySummary: Bool = false) -> ReminderPlanningOptions {
        ReminderPlanningOptions(dueSoonLeadDays: ReminderPlanner.defaultDueSoonLeadDays,
                                hour: 8,
                                minute: 0,
                                includesWeeklySummary: includesWeeklySummary,
                                showsDetail: showsDetail)
    }

    private func requests(for item: TestItem,
                          options: ReminderPlanningOptions) -> [CoreReminderRequest] {
        ReminderPlanner.requests(for: item, options: options, now: now, calendar: calendar)
    }

    private func queuePlan(for items: [TestItem],
                           options: ReminderPlanningOptions) -> ReminderQueuePlan {
        ReminderPlanner.queuePlan(for: items, options: options, now: now, calendar: calendar)
    }

    /// One core in every open state, between them producing all five per-item kinds.
    private func makeLedger() -> [TestItem] {
        [
            makeItem(status: .returnedAwaitingCredit, dueDate: dueFriday, returnedDate: handedBack),
            makeItem(status: .readyToReturn, dueDate: TestClock.date(year: 2026, month: 3, day: 11)),
            makeItem(status: .disputed,
                     dueDate: nil,
                     creditedDate: TestClock.date(year: 2026, month: 3, day: 11),
                     actualCredit: Money(cents: 5_000))
        ]
    }

    // MARK: - Identity

    @Test("Identifiers are deterministic, unique per kind and lead, and always end in the core's own id")
    func identifiersAreDeterministicAndUniquePerKindAndLead() throws {
        let item = makeItem(status: .returnedAwaitingCredit, dueDate: dueFriday, returnedDate: handedBack)
        let options = makeOptions()

        let first = requests(for: item, options: options)
        let second = requests(for: item, options: options)

        // Same inputs, same identifiers, in the same order.
        #expect(first.map(\.identifier) == second.map(\.identifier))
        #expect(first.count == 5)
        #expect(Set(first.map(\.identifier)).count == first.count)

        let prefix = CoreReminderRequest.identifierPrefix
        let uuid = item.identifier.uuidString

        // One identifier per (item, kind, lead) — three leads are three separate alerts.
        #expect(Set(first.map(\.identifier)) == [
            prefix + "dueSoon7-" + uuid,
            prefix + "dueSoon3-" + uuid,
            prefix + "dueSoon1-" + uuid,
            prefix + "dueToday-" + uuid,
            prefix + "awaitingCredit-" + uuid
        ])

        for request in first {
            // Derivable without a request in hand, which is what makes cancellation exact.
            #expect(request.identifier == CoreReminderRequest.identifier(for: request.itemID,
                                                                        kind: request.kind,
                                                                        leadDays: request.leadDays))
            #expect(request.identifier.hasPrefix(prefix))
            // The UUID is always the suffix, so it is recoverable from the identifier alone.
            #expect(request.identifier.hasSuffix("-" + uuid))
            #expect(CoreReminderRequest.identifier(request.identifier, belongsTo: item.identifier))
        }

        // A second core with the same kinds collides with nothing.
        var other = item
        other.identifier = UUID()
        let otherIdentifiers = Set(requests(for: other, options: options).map(\.identifier))
        #expect(otherIdentifiers.count == 5)
        #expect(Set(first.map(\.identifier)).isDisjoint(with: otherIdentifiers))
        #expect(CoreReminderRequest.identifier(prefix + "dueToday-" + uuid,
                                               belongsTo: other.identifier) == false)

        // The settings screen's throwaway alert shares the prefix, so `cancelAll` sweeps it up too.
        #expect(CoreReminderRequest.testIdentifier == prefix + "test")
    }

    @Test("Planning the same ledger twice queues no duplicate reminders")
    func planningTheSameLedgerTwiceQueuesNoDuplicates() async throws {
        let items = makeLedger()
        let options = makeOptions()
        let scheduler = RecordingNotificationScheduler()

        let plan = queuePlan(for: items, options: options)
        for request in plan.scheduled {
            try await scheduler.schedule(request)
        }

        let afterFirstPass = await scheduler.pendingIdentifiers()
        #expect(afterFirstPass.count == plan.scheduledCount)
        #expect(Set(afterFirstPass).count == afterFirstPass.count)

        // The write path re-plans the whole ledger on every save; a rebuild must replace, not stack.
        let replan = queuePlan(for: items, options: options)
        #expect(replan.scheduled.map(\.identifier) == plan.scheduled.map(\.identifier))
        for request in replan.scheduled {
            try await scheduler.schedule(request)
        }

        let afterSecondPass = await scheduler.pendingIdentifiers()
        #expect(afterSecondPass == afterFirstPass)
        #expect(scheduler.scheduledRequests.count == plan.scheduledCount)
        #expect(scheduler.authorizationRequestCount == 0)
    }

    // MARK: - Cancellation

    @Test("A core that closes has its reminders cancelled exactly, leaving every other core's alone")
    func closingACoreCancelsItsOwnRemindersExactly() async throws {
        let options = makeOptions()
        var closing = makeItem(status: .returnedAwaitingCredit,
                               dueDate: dueFriday,
                               returnedDate: handedBack)
        let untouched = makeItem(status: .awaitingCore, dueDate: dueFriday)

        let scheduler = RecordingNotificationScheduler()
        for request in queuePlan(for: [closing, untouched], options: options).scheduled {
            try await scheduler.schedule(request)
        }

        #expect(scheduler.scheduledRequests(for: closing.identifier).count == 5)
        #expect(scheduler.scheduledRequests(for: untouched.identifier).count == 4)

        // The vendor credit lands. A closed core has nothing left to chase.
        closing.status = .credited
        closing.actualCredit = expectedCredit
        closing.creditedDate = TestClock.date(year: 2026, month: 3, day: 12)
        #expect(requests(for: closing, options: options).isEmpty)

        // The production cancellation path narrows what is actually queued down to that core's
        // identifiers, rather than reconstructing them from settings that may have changed since.
        let pending = await scheduler.pendingIdentifiers()
        let doomed = CoreReminderRequest.identifiers(pending, belongingTo: [closing.identifier])
        #expect(doomed.count == 5)
        #expect(Set(doomed).isSubset(of: Set(pending)))

        await scheduler.cancel(itemIDs: [closing.identifier])

        #expect(scheduler.cancelledIDs == [closing.identifier])
        #expect(scheduler.scheduledRequests(for: closing.identifier).isEmpty)
        #expect(scheduler.scheduledRequests(for: untouched.identifier).count == 4)

        let afterCancel = await scheduler.pendingIdentifiers()
        #expect(afterCancel.count == 4)
        #expect(afterCancel.contains { CoreReminderRequest.identifier($0, belongsTo: closing.identifier) } == false)
        #expect(afterCancel.allSatisfy { CoreReminderRequest.identifier($0, belongsTo: untouched.identifier) })
    }

    // MARK: - Snooze

    /// Snooze is only *decided* here; it is only *performed* by `NotificationResponder.snooze(_:)`,
    /// which copies a delivered `UNNotificationRequest` and re-adds it to
    /// `UNUserNotificationCenter.current()`. That path takes a live notification response and a
    /// real notification centre, neither of which a unit test can construct, so the re-queue itself
    /// is deliberately **not** covered here — it belongs to a device or UI test. What is testable
    /// is the contract the re-queue depends on, which is asserted below.
    @Test("Snooze is a one-day move that reuses the reminder's own identifier")
    func snoozeIsAOneDayMoveThatReusesTheIdentifier() async throws {
        #expect(NotificationResponder.snoozeInterval == 24 * 60 * 60)
        #expect(ReminderNotificationAction.snoozeOneDay == "corecredit.action.snoozeOneDay")
        #expect(ReminderNotificationAction.viewItem == "corecredit.action.viewItem")
        #expect(ReminderNotificationAction.scanCore == "corecredit.action.scanCore")

        // Re-adding a request under an identifier that is already queued replaces it, which is
        // exactly what lets a snooze move an alert instead of stacking a second one.
        let item = makeItem(status: .awaitingCore, dueDate: dueFriday)
        let original = try #require(requests(for: item, options: makeOptions()).first { $0.kind == .dueToday })

        var snoozed = original
        snoozed.fireDate = original.fireDate.addingTimeInterval(NotificationResponder.snoozeInterval)
        #expect(snoozed.identifier == original.identifier)

        let scheduler = RecordingNotificationScheduler()
        try await scheduler.schedule(original)
        try await scheduler.schedule(snoozed)

        #expect(scheduler.scheduledRequests == [snoozed])
        let pending = await scheduler.pendingIdentifiers()
        #expect(pending == [original.identifier])
    }

    // MARK: - Privacy

    @Test("With detail off, no reminder names the vendor, the part, or any amount")
    func withDetailOffNoReminderNamesTheVendorThePartOrTheAmount() throws {
        // Off is the default: a shop has to opt in before a Lock Screen starts naming its vendors.
        #expect(ReminderPlanningOptions().showsDetail == false)

        let plan = queuePlan(for: makeLedger(),
                             options: makeOptions(showsDetail: false, includesWeeklySummary: true))

        // Every kind the app has is represented, so nothing escapes the check below.
        #expect(Set(plan.scheduled.map(\.kind)) == Set(ReminderKind.allCases))

        let forbidden = [vendorName, partName, partNumber, binLabel,
                         amountText, expectedCredit.plainDecimalString, "$", "\u{20AC}"]

        for request in plan.scheduled {
            for secret in forbidden {
                #expect(request.title.contains(secret) == false,
                        "A reminder title must not contain \(secret)")
                #expect(request.body.contains(secret) == false,
                        "A reminder body must not contain \(secret)")
            }
        }

        // The generic copy says which kind of attention is wanted, and nothing else.
        let titles = Set(plan.scheduled.map(\.title))
        #expect(titles == [
            "Core return due soon",
            "Core return due today",
            "Core return is overdue",
            "Vendor credit still outstanding",
            "Disputed credit needs a follow-up",
            "Weekly core review"
        ])

        let itemBodies = Set(plan.scheduled.filter { $0.kind.isAboutOneItem }.map(\.body))
        #expect(itemBodies == ["Open CoreCredit to review this core."])

        // The digest states a count of open cores, which is neither money nor a vendor.
        let summary = try #require(plan.scheduled.first { $0.kind == .weeklySummary })
        #expect(summary.body == "You have 3 open cores still to settle.")
    }

    @Test("With detail on, the copy names the part, the amount, the vendor, and the bin")
    func withDetailOnTheCopyNamesThePartTheAmountTheVendorAndTheBin() throws {
        let plan = queuePlan(for: makeLedger(),
                             options: makeOptions(showsDetail: true, includesWeeklySummary: true))

        let detailedBody = partName + " (" + partNumber + ") \u{2014} " + amountText
            + " to " + vendorName + ". Bin " + binLabel + "."

        for request in plan.scheduled where request.kind.isAboutOneItem {
            #expect(request.body == detailedBody)
            #expect(request.body.contains(vendorName))
            #expect(request.body.contains(partNumber))
            #expect(request.body.contains(amountText))
        }

        let awaiting = try #require(plan.scheduled.first { $0.kind == .awaitingCredit })
        #expect(awaiting.title == "Credit still owed by " + vendorName)

        let overdue = try #require(plan.scheduled.first { $0.kind == .overdue })
        #expect(overdue.title == "Core return overdue since Mar 11")

        let dueSoon = try #require(plan.scheduled.first { $0.kind == .dueSoon })
        #expect(dueSoon.title.hasPrefix("Core return due "))

        // The digest is about the whole ledger, so opting into detail changes nothing about it.
        let summary = try #require(plan.scheduled.first { $0.kind == .weeklySummary })
        #expect(summary.body == "You have 3 open cores still to settle.")
        #expect(summary.title == "Weekly core review")
    }

    // MARK: - Payload

    @Test("A reminder carries one core identifier and one route, and nothing else")
    func aReminderCarriesOnlyAnIdentifierAndARoute() throws {
        let items = makeLedger()
        let plan = queuePlan(for: items, options: makeOptions(includesWeeklySummary: true))
        let knownIDs = Set(items.map(\.identifier))

        for request in plan.scheduled where request.kind.isAboutOneItem {
            let itemID = try #require(request.itemID)
            #expect(knownIDs.contains(itemID))

            let route = try #require(request.route)
            #expect(route == ReminderRoute.item(itemID))
            #expect(route == "corecredit://item/" + itemID.uuidString)

            // The route is a link the app already understands — the same one a bin tag's QR carries.
            let url = try #require(URL(string: route))
            #expect(DeepLink.parse(url) == DeepLink.item(itemID))

            // Nothing about the ledger travels in the payload, whatever the banner says.
            #expect(route.contains(vendorName) == false)
            #expect(route.contains(partNumber) == false)
            #expect(route.contains(expectedCredit.plainDecimalString) == false)
        }

        // The digest names no core, so tapping it simply brings the app forward.
        let summary = try #require(plan.scheduled.first { $0.kind == .weeklySummary })
        #expect(summary.kind.isAboutOneItem == false)
        #expect(summary.itemID == nil)
        #expect(summary.route == nil)

        // The two — and only two — keys the payload is ever built from.
        #expect(ReminderUserInfoKey.itemID == "coreItemID")
        #expect(ReminderUserInfoKey.route == "route")

        // Item reminders carry actions; the digest and the test alert deliberately do not.
        #expect(ReminderNotificationCategory.itemReminder == "corecredit.reminder.item")
        #expect(ReminderNotificationCategory.summary == "corecredit.reminder.summary")
        #expect(ReminderRoute.scan == "corecredit://scan")
    }

    // MARK: - The queue cap

    @Test("The queue is capped, what did not fit is reported, and the soonest are the ones kept")
    func theQueueIsCappedAndNothingIsSilentlyLost() throws {
        // Twenty open cores, four reminders each: three leads plus the morning of the deadline.
        let items = (0..<20).map { _ in makeItem(status: .awaitingCore, dueDate: dueFriday) }
        let plan = queuePlan(for: items, options: makeOptions())

        #expect(ReminderPlanner.maximumScheduledReminders == 56)
        #expect(plan.scheduledCount == ReminderPlanner.maximumScheduledReminders)
        #expect(plan.scheduledCount + plan.droppedCount == 80)
        #expect(plan.droppedCount == 24)

        // Nothing is silently lost: everything that did not fit is handed back to the caller.
        let scheduledIdentifiers = Set(plan.scheduled.map(\.identifier))
        let droppedIdentifiers = Set(plan.dropped.map(\.identifier))
        #expect(scheduledIdentifiers.count == plan.scheduledCount)
        #expect(droppedIdentifiers.count == plan.droppedCount)
        #expect(scheduledIdentifiers.isDisjoint(with: droppedIdentifiers))

        // Soonest first, and everything left out is at or beyond the last moment kept.
        let dates = plan.scheduled.map(\.fireDate)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
        let lastKept = try #require(dates.last)
        #expect(plan.dropped.allSatisfy { $0.fireDate >= lastKept })

        // A ledger that fits drops nothing.
        let small = queuePlan(for: [makeItem(status: .awaitingCore, dueDate: dueFriday)],
                              options: makeOptions())
        #expect(small.scheduledCount == 4)
        #expect(small.dropped.isEmpty)

        // An explicit limit is honoured exactly, and a nonsensical one queues nothing at all.
        let three = ReminderPlanner.queuePlan(for: items, options: makeOptions(),
                                              now: now, calendar: calendar, limit: 3)
        #expect(three.scheduledCount == 3)
        #expect(three.droppedCount == 77)
        #expect(three.scheduled == Array(plan.scheduled.prefix(3)))

        let none = ReminderPlanner.queuePlan(for: items, options: makeOptions(),
                                             now: now, calendar: calendar, limit: -1)
        #expect(none.scheduled.isEmpty)
        #expect(none.droppedCount == 80)
    }

    @Test("Reminders sharing a moment are ordered by the documented kind priority")
    func remindersSharingAMomentAreOrderedByKindPriority() throws {
        // Five cores, five different reasons, all landing at 08:00 tomorrow morning.
        let overdueItem = makeItem(status: .readyToReturn,
                                   dueDate: TestClock.date(year: 2026, month: 3, day: 11))
        let dueTodayItem = makeItem(status: .awaitingCore,
                                    dueDate: TestClock.date(year: 2026, month: 3, day: 13))
        let dueSoonItem = makeItem(status: .awaitingCore,
                                   dueDate: TestClock.date(year: 2026, month: 3, day: 14))
        let awaitingItem = makeItem(status: .returnedAwaitingCredit,
                                    dueDate: nil,
                                    returnedDate: TestClock.date(year: 2026, month: 3, day: 6))
        let disputedItem = makeItem(status: .disputed,
                                    dueDate: nil,
                                    creditedDate: handedBack,
                                    actualCredit: Money(cents: 5_000))

        // Deliberately shuffled on the way in: the order out is the planner's, not the caller's.
        let plan = queuePlan(for: [disputedItem, awaitingItem, dueSoonItem, dueTodayItem, overdueItem],
                             options: makeOptions())

        let tomorrowMorning = TestClock.date(year: 2026, month: 3, day: 13, hour: 8, minute: 0)
        let tied = plan.scheduled.filter { $0.fireDate == tomorrowMorning }

        // Money already late outranks money about to be late, which outranks a courtesy heads-up.
        #expect(tied.map(\.kind) == [.overdue, .dueToday, .dueSoon, .awaitingCredit, .disputeFollowUp])
        #expect(tied.map(\.kind.priority) == [0, 1, 2, 3, 4])

        #expect(ReminderKind.allCases.sorted { $0.priority < $1.priority }
                == [.overdue, .dueToday, .dueSoon, .awaitingCredit, .disputeFollowUp, .weeklySummary])

        // The one later reminder sorts after every tied one.
        #expect(plan.scheduledCount == 6)
        let last = try #require(plan.scheduled.last)
        #expect(last.kind == .dueToday)
        #expect(last.fireDate == TestClock.date(year: 2026, month: 3, day: 14, hour: 8, minute: 0))
    }

    // MARK: - Permission

    @Test("A denied permission refuses every reminder and is never re-requested behind the shop's back")
    func aDeniedPermissionRefusesEveryReminderAndIsNeverReRequested() async throws {
        #expect(NotificationAuthorizationStatus.denied.allowsScheduling == false)
        #expect(NotificationAuthorizationStatus.notDetermined.allowsScheduling == false)
        #expect(NotificationAuthorizationStatus.unknown.allowsScheduling == false)
        #expect(NotificationAuthorizationStatus.authorized.allowsScheduling)
        #expect(NotificationAuthorizationStatus.provisional.allowsScheduling)
        #expect(NotificationAuthorizationStatus.ephemeral.allowsScheduling)

        let scheduler = RecordingNotificationScheduler(status: .denied)
        let plan = queuePlan(for: makeLedger(), options: makeOptions())
        #expect(plan.scheduled.isEmpty == false)

        for request in plan.scheduled {
            await #expect(throws: NotificationSchedulingError.notAuthorized) {
                try await scheduler.schedule(request)
            }
        }

        let status = await scheduler.authorizationStatus()
        #expect(status == .denied)
        #expect(scheduler.scheduledRequests.isEmpty)
        let pending = await scheduler.pendingIdentifiers()
        #expect(pending.isEmpty)

        // Permission is asked for in context, from the settings screen — never as a side effect.
        #expect(scheduler.authorizationRequestCount == 0)

        // The refusal is a sentence the shop can act on, not a silent no-op.
        let message = NotificationSchedulingError.notAuthorized.errorDescription
        #expect(message?.contains("Settings app") == true)

        // The throwaway test alert is refused for the same reason.
        await #expect(throws: NotificationSchedulingError.notAuthorized) {
            try await scheduler.scheduleTestNotification(after: 5)
        }
        #expect(scheduler.testNotificationDelays.isEmpty)

        // Turning notifications on in the Settings app is enough; nothing has to prompt again.
        scheduler.setAuthorizationStatus(.authorized)
        for request in plan.scheduled {
            try await scheduler.schedule(request)
        }
        #expect(scheduler.scheduledRequests.count == plan.scheduledCount)
        #expect(scheduler.authorizationRequestCount == 0)
    }
}
