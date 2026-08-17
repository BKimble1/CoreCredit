//
//  ReminderPlanner.swift
//  CoreCredit
//
//  Pure. Foundation only. No system clock, no `Calendar.current`, no notification framework.
//

import Foundation

// MARK: - Options

/// Every setting the planner needs, gathered into one value.
///
/// Passing a value rather than a `ShopProfile` keeps the planner free of SwiftData and keeps it
/// testable with a literal: nothing here has to be fetched, saved, or observed.
struct ReminderPlanningOptions: Equatable, Sendable {

    /// How many days before a deadline to warn, one request per entry. Zero and negative entries
    /// are dropped, because the morning of the deadline belongs to `.dueToday`.
    var dueSoonLeadDays: [Int]

    /// Local hour of day every reminder fires at. Clamped to `0...23`.
    var hour: Int

    /// Local minute. Clamped to `0...59`.
    var minute: Int

    /// Days after a core goes back to the vendor before CoreCredit asks about the credit.
    var awaitingCreditDelayDays: Int

    /// Days after a credit was recorded short before CoreCredit asks about the dispute.
    var disputeFollowUpDelayDays: Int

    /// Whether the opt-in weekly digest is wanted. Off by default.
    var includesWeeklySummary: Bool

    /// Which weekday the digest lands on, `1` = Sunday through `7` = Saturday.
    var weeklySummaryWeekday: Int

    /// When `false` (the default), notification copy names nothing: no vendor, no money, no part.
    /// See `ShopProfile.showsDetailInNotifications`.
    var showsDetail: Bool

    /// The shop's currency, used only when `showsDetail` is on.
    var currencyCode: String

    init(dueSoonLeadDays: [Int] = ReminderPlanner.defaultDueSoonLeadDays,
         hour: Int = AppConfiguration.defaultReminderHour,
         minute: Int = AppConfiguration.defaultReminderMinute,
         awaitingCreditDelayDays: Int = ReminderPlanner.defaultAwaitingCreditDelayDays,
         disputeFollowUpDelayDays: Int = ReminderPlanner.defaultDisputeFollowUpDelayDays,
         includesWeeklySummary: Bool = false,
         weeklySummaryWeekday: Int = ReminderPlanner.defaultWeeklySummaryWeekday,
         showsDetail: Bool = false,
         currencyCode: String = AppConfiguration.defaultCurrencyCode) {
        self.dueSoonLeadDays = dueSoonLeadDays
        self.hour = hour
        self.minute = minute
        self.awaitingCreditDelayDays = awaitingCreditDelayDays
        self.disputeFollowUpDelayDays = disputeFollowUpDelayDays
        self.includesWeeklySummary = includesWeeklySummary
        self.weeklySummaryWeekday = weeklySummaryWeekday
        self.showsDetail = showsDetail
        self.currencyCode = currencyCode
    }
}

// MARK: - Queue plan

/// The result of planning a whole ledger: what will be queued, and what would not fit.
///
/// `dropped` is never thrown away silently. `ReminderCoordinator` turns its count into a line the
/// notification settings screen shows, because a shop with 200 open cores deserves to know that
/// the device is only holding the nearest handful of alerts.
struct ReminderQueuePlan: Equatable, Sendable {

    /// Requests that fit under the queue cap, soonest first.
    var scheduled: [CoreReminderRequest]

    /// Requests that did not fit, in the same order.
    var dropped: [CoreReminderRequest]

    init(scheduled: [CoreReminderRequest], dropped: [CoreReminderRequest]) {
        self.scheduled = scheduled
        self.dropped = dropped
    }

    var scheduledCount: Int { scheduled.count }
    var droppedCount: Int { dropped.count }
}

// MARK: - Planner

/// Decides **which** reminders a core needs and **when** each one should fire.
///
/// Everything time-dependent arrives as a parameter (`now`, `calendar`), so the **decision** — fire
/// or not, and at exactly which instant — is identical on any machine in any time zone. That
/// determinism is the whole point of splitting the planner away from `UserNotificationScheduler`:
/// the decision is unit-tested, the delivery is not.
///
/// # Content is generic unless the shop asks otherwise
///
/// A notification banner is readable by whoever is holding the phone, and on a Lock Screen it is
/// readable by whoever is standing near it. So the default copy names nothing. The title says only
/// which kind of attention is wanted — "Core return due soon", "Core return is overdue", "Vendor
/// credit still outstanding" — and the body is always "Open CoreCredit to review this core."
/// Turning `ReminderPlanningOptions.showsDetail` on opts into the detailed wording — part, amount,
/// vendor, bin — which is what a shop that keeps the phone behind the counter will want.
///
/// The one deliberately locale-dependent part is the money inside a detailed body, which is
/// formatted for `Locale.current`. A notification is read by a person, so it should use that
/// person's number formatting; only the fire date and the identifier are locale-independent.
enum ReminderPlanner {

    // MARK: - Limits and defaults

    /// A zero-day lead is legitimate: "remind me on the morning it is due". The whole-ledger
    /// planner routes that case through `.dueToday` instead, so the two cannot collide.
    static let minimumLeadDays = 0

    /// One year, matching `DueDateCalculator.maximumWindowDays`. The planner stays permissive on
    /// purpose; the notification settings screen offers a narrower, friendlier range.
    static let maximumLeadDays = 365

    /// Warn a week out, again three days out, again the day before.
    static let defaultDueSoonLeadDays = [7, 3, 1]

    /// A week is long enough that a vendor's paperwork has genuinely had its chance.
    static let defaultAwaitingCreditDelayDays = 7

    /// Long enough for a counter call to have been returned; short enough to still matter.
    static let defaultDisputeFollowUpDelayDays = 3

    /// Monday, so the week's chasing gets planned before it gets away.
    static let defaultWeeklySummaryWeekday = 2

    /// Shortest and longest sensible follow-up delays.
    static let minimumDelayDays = 1
    static let maximumDelayDays = 90

    /// iOS keeps **64** pending local notifications per app and silently discards the rest. This
    /// sits under that ceiling so an alert the app schedules outside the planner — the settings
    /// screen's test notification, a snoozed reminder the responder re-adds — still has room.
    static let maximumScheduledReminders = 56

    // MARK: - Whole ledger

    /// Plans every reminder the ledger needs, trims the result to the queue cap, and reports what
    /// did not fit.
    ///
    /// Ordering is "soonest first, then most urgent": requests are sorted by fire date, ties broken
    /// by `ReminderKind.priority` (overdue before due-today before due-soon before awaiting-credit
    /// before dispute follow-up before the weekly digest), and finally by identifier so the result
    /// is total and reproducible. The first `limit` entries are kept.
    static func queuePlan<Item: CoreItemRepresenting>(for items: [Item],
                                                      options: ReminderPlanningOptions,
                                                      now: Date,
                                                      calendar: Calendar,
                                                      limit: Int = ReminderPlanner.maximumScheduledReminders) -> ReminderQueuePlan {
        var candidates: [CoreReminderRequest] = []
        var openItemCount = 0

        for item in items {
            if item.status.isUnresolved { openItemCount += 1 }
            candidates.append(contentsOf: requests(for: item, options: options, now: now, calendar: calendar))
        }

        if options.includesWeeklySummary,
           let summary = weeklySummaryRequest(openItemCount: openItemCount,
                                              options: options,
                                              now: now,
                                              calendar: calendar) {
            candidates.append(summary)
        }

        let ordered = candidates.sorted(by: isOrderedBefore)
        let safeLimit = limit < 0 ? 0 : limit

        guard ordered.count > safeLimit else {
            return ReminderQueuePlan(scheduled: ordered, dropped: [])
        }
        return ReminderQueuePlan(scheduled: Array(ordered.prefix(safeLimit)),
                                 dropped: Array(ordered.dropFirst(safeLimit)))
    }

    // MARK: - One item

    /// Every reminder one core currently deserves, in no particular order.
    ///
    /// Returns an empty array when:
    /// - the core is closed (`credited` / `writtenOff`) — nothing left to chase;
    /// - nothing about it is due, awaiting a credit, or disputed;
    /// - every computed fire date is already in the past. A late alert is worse than none, and the
    ///   overdue state is already surfaced on the dashboard.
    static func requests(for item: some CoreItemRepresenting,
                         options: ReminderPlanningOptions,
                         now: Date,
                         calendar: Calendar) -> [CoreReminderRequest] {

        guard item.status.isUnresolved else { return [] }

        var results: [CoreReminderRequest] = []

        if let dueDate = item.dueDate {
            for lead in normalizedLeadDays(options.dueSoonLeadDays) {
                if let request = dueSoonRequest(for: item,
                                                dueDate: dueDate,
                                                leadDays: lead,
                                                options: options,
                                                now: now,
                                                calendar: calendar) {
                    results.append(request)
                }
            }

            if let request = dueTodayRequest(for: item,
                                             dueDate: dueDate,
                                             options: options,
                                             now: now,
                                             calendar: calendar) {
                results.append(request)
            }

            if let request = overdueRequest(for: item,
                                            dueDate: dueDate,
                                            options: options,
                                            now: now,
                                            calendar: calendar) {
                results.append(request)
            }
        }

        if let request = awaitingCreditRequest(for: item, options: options, now: now, calendar: calendar) {
            results.append(request)
        }

        if let request = disputeFollowUpRequest(for: item, options: options, now: now, calendar: calendar) {
            results.append(request)
        }

        return results
    }

    // MARK: - Single-lead due-soon

    /// The detailed due-soon reminder for one lead, or `nil` when it should not exist.
    ///
    /// The app itself plans through `queuePlan(for:options:now:calendar:)`; this narrower entry
    /// point exists because it is the smallest thing worth asserting on — one item, one lead, one
    /// moment — and it is what the reminder tests pin the fire-date and wording rules with. It
    /// always produces the **detailed** wording, so an assertion on the body is not also an
    /// assertion about the shop's privacy setting.
    ///
    /// The fire date is `startOfDay(dueDate)` minus `leadDays`, moved to `hour:minute`, built
    /// entirely through the injected `calendar`.
    ///
    /// - Parameters:
    ///   - item: the core to warn about.
    ///   - leadDays: how many days before the deadline to fire. Clamped to `0...365`.
    ///   - hour: local hour of day, clamped to `0...23`.
    ///   - minute: local minute, clamped to `0...59`.
    ///   - now: the current instant — supplied, never read from the clock.
    ///   - calendar: the calendar all date maths goes through.
    ///   - currencyCode: the shop's currency, used to format the amount in the body.
    static func plan(for item: some CoreItemRepresenting,
                     leadDays: Int,
                     hour: Int,
                     minute: Int,
                     now: Date,
                     calendar: Calendar,
                     currencyCode: String) -> CoreReminderRequest? {

        guard item.status.isUnresolved else { return nil }
        guard let dueDate = item.dueDate else { return nil }

        var options = ReminderPlanningOptions()
        options.hour = hour
        options.minute = minute
        options.showsDetail = true
        options.currencyCode = currencyCode

        return dueSoonRequest(for: item,
                              dueDate: dueDate,
                              leadDays: leadDays,
                              options: options,
                              now: now,
                              calendar: calendar)
    }

    // MARK: - Weekly summary

    /// The opt-in digest, or `nil` when it is switched off, when nothing is open, or when the next
    /// occurrence of the chosen weekday cannot be built.
    ///
    /// Not a per-item reminder: it carries no item identifier and no deep link, so tapping it
    /// simply brings the app forward. The only figure it states is a count of open cores, which is
    /// neither money nor a vendor name.
    static func weeklySummaryRequest(openItemCount: Int,
                                     options: ReminderPlanningOptions,
                                     now: Date,
                                     calendar: Calendar) -> CoreReminderRequest? {

        guard options.includesWeeklySummary else { return nil }
        guard openItemCount > 0 else { return nil }
        guard let fireDate = nextWeekdayFireDate(weekday: options.weeklySummaryWeekday,
                                                 after: now,
                                                 options: options,
                                                 calendar: calendar) else { return nil }

        let noun = openItemCount == 1 ? " open core" : " open cores"
        return CoreReminderRequest(
            itemID: nil,
            kind: .weeklySummary,
            title: "Weekly core review",
            body: "You have " + String(openItemCount) + noun + " still to settle.",
            fireDate: fireDate,
            route: nil
        )
    }

    // MARK: - Per-kind builders

    private static func dueSoonRequest(for item: some CoreItemRepresenting,
                                       dueDate: Date,
                                       leadDays: Int,
                                       options: ReminderPlanningOptions,
                                       now: Date,
                                       calendar: Calendar) -> CoreReminderRequest? {

        let dueStartOfDay = calendar.startOfDay(for: dueDate)
        let clampedLead = clamp(leadDays, minimum: minimumLeadDays, maximum: maximumLeadDays)

        guard let leadDay = calendar.date(byAdding: .day, value: -clampedLead, to: dueStartOfDay) else {
            return nil
        }
        guard let fireDate = moment(onDayOf: leadDay, options: options, calendar: calendar) else { return nil }
        guard fireDate > now else { return nil }

        let title: String
        if options.showsDetail {
            title = "Core return due "
                + relativeDueDescription(dueDate: dueStartOfDay, fireDate: fireDate, calendar: calendar)
        } else {
            title = "Core return due soon"
        }

        return CoreReminderRequest(
            itemID: item.identifier,
            kind: .dueSoon,
            leadDays: clampedLead,
            title: title,
            body: body(for: item, options: options),
            fireDate: fireDate,
            route: ReminderRoute.item(item.identifier)
        )
    }

    private static func dueTodayRequest(for item: some CoreItemRepresenting,
                                        dueDate: Date,
                                        options: ReminderPlanningOptions,
                                        now: Date,
                                        calendar: Calendar) -> CoreReminderRequest? {

        let dueStartOfDay = calendar.startOfDay(for: dueDate)
        guard let fireDate = moment(onDayOf: dueStartOfDay, options: options, calendar: calendar) else {
            return nil
        }
        guard fireDate > now else { return nil }

        return CoreReminderRequest(
            itemID: item.identifier,
            kind: .dueToday,
            title: "Core return due today",
            body: body(for: item, options: options),
            fireDate: fireDate,
            route: ReminderRoute.item(item.identifier)
        )
    }

    /// Fires at the next `hour:minute` **after** `now` for a core whose window has already closed.
    ///
    /// Measuring from the deadline instead would be useless: a core forty days late would compute a
    /// fire date thirty-nine days in the past and be skipped, which is exactly the core that most
    /// needs chasing. Because the queue is rebuilt on every write and on every app launch, the
    /// nudge re-arms itself for as long as the core stays open.
    private static func overdueRequest(for item: some CoreItemRepresenting,
                                       dueDate: Date,
                                       options: ReminderPlanningOptions,
                                       now: Date,
                                       calendar: Calendar) -> CoreReminderRequest? {

        let dueStartOfDay = calendar.startOfDay(for: dueDate)
        guard dueStartOfDay < calendar.startOfDay(for: now) else { return nil }
        guard let fireDate = nextMoment(after: now, options: options, calendar: calendar) else { return nil }

        let title: String
        if options.showsDetail {
            title = "Core return overdue since " + shortDate(for: dueStartOfDay, calendar: calendar)
        } else {
            title = "Core return is overdue"
        }

        return CoreReminderRequest(
            itemID: item.identifier,
            kind: .overdue,
            title: title,
            body: body(for: item, options: options),
            fireDate: fireDate,
            route: ReminderRoute.item(item.identifier)
        )
    }

    /// Returned to the vendor, no credit recorded, and the grace period has run out.
    ///
    /// A core with no `returnedDate` produces nothing: there is no hand-off to measure from, and
    /// guessing one would put the reminder on a date that never happened.
    private static func awaitingCreditRequest(for item: some CoreItemRepresenting,
                                              options: ReminderPlanningOptions,
                                              now: Date,
                                              calendar: Calendar) -> CoreReminderRequest? {

        guard item.status == .returnedAwaitingCredit else { return nil }
        guard item.actualCredit == nil else { return nil }
        guard let returnedDate = item.returnedDate else { return nil }

        let delay = clamp(options.awaitingCreditDelayDays,
                          minimum: minimumDelayDays,
                          maximum: maximumDelayDays)
        let start = calendar.startOfDay(for: returnedDate)
        guard let day = calendar.date(byAdding: .day, value: delay, to: start) else { return nil }
        guard let fireDate = moment(onDayOf: day, options: options, calendar: calendar) else { return nil }
        guard fireDate > now else { return nil }

        let title: String
        if options.showsDetail, let vendorName = trimmedOrNil(item.vendorName) {
            title = "Credit still owed by " + vendorName
        } else {
            title = "Vendor credit still outstanding"
        }

        return CoreReminderRequest(
            itemID: item.identifier,
            kind: .awaitingCredit,
            title: title,
            body: body(for: item, options: options),
            fireDate: fireDate,
            route: ReminderRoute.item(item.identifier)
        )
    }

    /// A short credit that nobody has chased since.
    ///
    /// Measured from the credit date when there is one — that is the day the dispute began — and
    /// from the return or receipt date otherwise, matching `RiskCalculator.referenceDate(for:)`.
    private static func disputeFollowUpRequest(for item: some CoreItemRepresenting,
                                               options: ReminderPlanningOptions,
                                               now: Date,
                                               calendar: Calendar) -> CoreReminderRequest? {

        guard item.status == .disputed else { return nil }

        let delay = clamp(options.disputeFollowUpDelayDays,
                          minimum: minimumDelayDays,
                          maximum: maximumDelayDays)
        let reference = item.creditedDate ?? item.returnedDate ?? item.receivedDate
        let start = calendar.startOfDay(for: reference)
        guard let day = calendar.date(byAdding: .day, value: delay, to: start) else { return nil }
        guard let fireDate = moment(onDayOf: day, options: options, calendar: calendar) else { return nil }
        guard fireDate > now else { return nil }

        return CoreReminderRequest(
            itemID: item.identifier,
            kind: .disputeFollowUp,
            title: options.showsDetail ? "Follow up the short credit" : "Disputed credit needs a follow-up",
            body: body(for: item, options: options),
            fireDate: fireDate,
            route: ReminderRoute.item(item.identifier)
        )
    }

    // MARK: - Ordering

    /// Soonest first, then most urgent, then by identifier so the order is total.
    private static func isOrderedBefore(_ lhs: CoreReminderRequest, _ rhs: CoreReminderRequest) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority < rhs.kind.priority }
        return lhs.identifier < rhs.identifier
    }

    // MARK: - Lead days

    /// Sanitises the configured leads: duplicates removed, values above the maximum clamped,
    /// anything at or below zero dropped, longest lead first.
    ///
    /// Zero is dropped rather than clamped because the morning of the deadline is `.dueToday`'s
    /// slot. Keeping both would put two alerts on the same core at the same minute.
    static func normalizedLeadDays(_ leadDays: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []

        for value in leadDays {
            guard value > 0 else { continue }
            let clamped = clamp(value, minimum: minimumLeadDays, maximum: maximumLeadDays)
            guard !seen.contains(clamped) else { continue }
            seen.insert(clamped)
            result.append(clamped)
        }

        return result.sorted(by: >)
    }

    // MARK: - Moments

    /// `hour:minute` on the calendar day containing `date`.
    private static func moment(onDayOf date: Date,
                               options: ReminderPlanningOptions,
                               calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = clamp(options.hour, minimum: 0, maximum: 23)
        components.minute = clamp(options.minute, minimum: 0, maximum: 59)
        components.second = 0
        return calendar.date(from: components)
    }

    /// The first `hour:minute` strictly after `now` — today's if it is still ahead, tomorrow's
    /// otherwise.
    private static func nextMoment(after now: Date,
                                   options: ReminderPlanningOptions,
                                   calendar: Calendar) -> Date? {
        if let today = moment(onDayOf: now, options: options, calendar: calendar), today > now {
            return today
        }
        let startOfToday = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return nil }
        guard let tomorrowMoment = moment(onDayOf: tomorrow, options: options, calendar: calendar) else {
            return nil
        }
        return tomorrowMoment > now ? tomorrowMoment : nil
    }

    /// The next occurrence of `weekday` at `hour:minute`, strictly after `now`.
    ///
    /// Walks forward a day at a time rather than doing modular arithmetic, so a calendar that skips
    /// or repeats a day cannot produce a date that does not exist.
    private static func nextWeekdayFireDate(weekday: Int,
                                            after now: Date,
                                            options: ReminderPlanningOptions,
                                            calendar: Calendar) -> Date? {
        let target = clamp(weekday, minimum: 1, maximum: 7)
        let startOfToday = calendar.startOfDay(for: now)

        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            guard calendar.component(.weekday, from: day) == target else { continue }
            guard let fireDate = moment(onDayOf: day, options: options, calendar: calendar) else { continue }
            if fireDate > now { return fireDate }
        }
        return nil
    }

    // MARK: - Wording

    /// `"Friday"` / `"tomorrow"` / `"today"` / `"Mar 20"`.
    ///
    /// The phrasing is measured from the **fire date**, not from `now`, so the alert is still
    /// accurate on the day it actually lands in Notification Centre.
    private static func relativeDueDescription(dueDate: Date, fireDate: Date, calendar: Calendar) -> String {
        let days = DueDateCalculator.dayDifference(from: fireDate, to: dueDate, calendar: calendar)
        switch days {
        case ...0:
            // A zero-day lead fires on the morning of the deadline; a negative value cannot occur
            // because the lead days are clamped to be non-negative.
            return "today"
        case 1:
            return "tomorrow"
        case 2...6:
            return weekdayName(for: dueDate, calendar: calendar)
        default:
            return shortDate(for: dueDate, calendar: calendar)
        }
    }

    /// `"Friday"`, rendered through the calendar's own locale and time zone so a test using
    /// `FixedDateProvider.utcCalendar` gets the same English weekday everywhere.
    private static func weekdayName(for date: Date, calendar: Calendar) -> String {
        formatter(dateFormat: "EEEE", calendar: calendar).string(from: date)
    }

    /// `"Mar 20"` for deadlines far enough out that a weekday name would be ambiguous.
    private static func shortDate(for date: Date, calendar: Calendar) -> String {
        formatter(dateFormat: "MMM d", calendar: calendar).string(from: date)
    }

    /// A fresh formatter per call. Formatters are cheap next to a notification round-trip, and a
    /// local instance keeps this type free of shared mutable state.
    private static func formatter(dateFormat: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter
    }

    /// The generic body every reminder gets by default, or the detailed one when the shop has
    /// opted in.
    private static func body(for item: some CoreItemRepresenting,
                             options: ReminderPlanningOptions) -> String {
        guard options.showsDetail else { return genericBody }
        return detailedBody(for: item, currencyCode: options.currencyCode)
    }

    /// Names nothing. This is what lands on a Lock Screen unless the owner says otherwise.
    private static let genericBody = "Open " + AppConfiguration.displayName + " to review this core."

    /// `"Alternator (03-1887) — $86.50 to NAPA. Bin A3."`
    ///
    /// Every component is optional except the amount: a core with no part number, no vendor, and
    /// no bin still reads as a complete sentence.
    private static func detailedBody(for item: some CoreItemRepresenting, currencyCode: String) -> String {
        var sentence = trimmed(item.partName)
        if sentence.isEmpty { sentence = "Core" }

        let partNumber = trimmed(item.partNumber)
        if !partNumber.isEmpty {
            sentence += " (" + partNumber + ")"
        }

        sentence += " — " + item.expectedCredit.formatted(currencyCode: currencyCode)

        if let vendorName = item.vendorName {
            let vendor = trimmed(vendorName)
            if !vendor.isEmpty {
                sentence += " to " + vendor
            }
        }
        sentence += "."

        if let binLabel = item.binLabel {
            let bin = trimmed(binLabel)
            if !bin.isEmpty {
                sentence += " Bin " + bin + "."
            }
        }

        return sentence
    }

    // MARK: - Helpers

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedOrNil(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        if value < minimum { return minimum }
        if value > maximum { return maximum }
        return value
    }
}
