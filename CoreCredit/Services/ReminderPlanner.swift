//
//  ReminderPlanner.swift
//  CoreCredit
//
//  Pure. Foundation only. No system clock, no `Calendar.current`, no notification framework.
//

import Foundation

/// Decides **whether** a core needs a reminder and **when** it should fire.
///
/// Everything time-dependent arrives as a parameter (`now`, `calendar`), so the **decision** — fire
/// or not, and at exactly which instant — is identical on any machine in any time zone. That
/// determinism is the whole point of splitting the planner away from `UserNotificationScheduler`:
/// the decision is unit-tested, the delivery is not.
///
/// The one deliberately locale-dependent part is the money inside `body`, which is formatted for
/// `Locale.current`. A notification is read by a person, so it should use that person's number
/// formatting; only the fire date and the identifier are locale-independent. Tests that assert on
/// the body must build the expected substring through `Money.formatted(currencyCode:)` rather than
/// hard-coding `"$86.50"`.
///
/// The wording is written for a shop floor, not a spec sheet:
/// - title: `"Core return due Friday"`
/// - body:  `"Alternator (03-1887) — $86.50 to NAPA. Bin A3."`
enum ReminderPlanner {

    /// Builds the reminder for one item, or `nil` when it should not have one.
    ///
    /// Returns `nil` when:
    /// - the item is closed (`credited` / `writtenOff`) — nothing left to chase;
    /// - the item has no `dueDate` — there is no deadline to warn about;
    /// - the computed fire date is already in the past — a late alert is worse than none, and the
    ///   overdue state is already surfaced on the dashboard.
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

        let dueStartOfDay = calendar.startOfDay(for: dueDate)
        let clampedLead = clamp(leadDays, minimum: minimumLeadDays, maximum: maximumLeadDays)

        guard let leadDay = calendar.date(byAdding: .day, value: -clampedLead, to: dueStartOfDay) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: leadDay)
        components.hour = clamp(hour, minimum: 0, maximum: 23)
        components.minute = clamp(minute, minimum: 0, maximum: 59)
        components.second = 0

        guard let fireDate = calendar.date(from: components) else { return nil }
        guard fireDate > now else { return nil }

        return CoreReminderRequest(
            itemID: item.identifier,
            title: title(dueDate: dueStartOfDay, fireDate: fireDate, calendar: calendar),
            body: body(for: item, currencyCode: currencyCode),
            fireDate: fireDate
        )
    }

    // MARK: - Limits

    /// A zero-day lead is legitimate: "remind me on the morning it is due".
    static let minimumLeadDays = 0

    /// One year, matching `DueDateCalculator.maximumWindowDays`.
    static let maximumLeadDays = 365

    // MARK: - Wording

    /// `"Core return due Friday"` / `"Core return due tomorrow"` / `"Core return due Mar 20"`.
    ///
    /// The phrasing is measured from the **fire date**, not from `now`, so the alert is still
    /// accurate on the day it actually lands in Notification Centre.
    private static func title(dueDate: Date, fireDate: Date, calendar: Calendar) -> String {
        "Core return due " + relativeDueDescription(dueDate: dueDate, fireDate: fireDate, calendar: calendar)
    }

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

    /// `"Alternator (03-1887) — $86.50 to NAPA. Bin A3."`
    ///
    /// Every component is optional except the amount: a core with no part number, no vendor, and
    /// no bin still reads as a complete sentence.
    private static func body(for item: some CoreItemRepresenting, currencyCode: String) -> String {
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

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        if value < minimum { return minimum }
        if value > maximum { return maximum }
        return value
    }
}
