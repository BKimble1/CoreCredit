//
//  DateProvider.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// Injected clock and calendar.
///
/// Nothing in the domain calls `Date()` or `Calendar.current` directly. Every due date, aging
/// bucket, and reminder is derived from an injected provider, so a test can freeze time and get
/// the same answer on any machine in any time zone.
protocol DateProvider: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

/// Production provider: the real wall clock plus the user's calendar.
struct SystemDateProvider: DateProvider {

    private let storedCalendar: Calendar

    /// - Parameter calendar: defaults to `.autoupdatingCurrent` so a mid-session time zone or
    ///   locale change is picked up without relaunching.
    init(calendar: Calendar = .autoupdatingCurrent) {
        self.storedCalendar = calendar
    }

    var now: Date { Date() }

    var calendar: Calendar { storedCalendar }
}

/// Deterministic provider for unit tests, previews, and UI-test seeding.
struct FixedDateProvider: DateProvider {

    /// Gregorian calendar pinned to UTC and the POSIX locale.
    ///
    /// Using UTC keeps `startOfDay(for:)` stable regardless of where the test runs, which is what
    /// makes the "due today is not overdue" boundary reproducible.
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = zone
        }
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    var now: Date
    var calendar: Calendar

    init(now: Date, calendar: Calendar = FixedDateProvider.utcCalendar) {
        self.now = now
        self.calendar = calendar
    }

    /// Convenience for tests: `FixedDateProvider(year: 2026, month: 3, day: 12)`.
    ///
    /// `hour` defaults to midday so that adding or subtracting a few hours in a test cannot
    /// accidentally roll the date over a day boundary.
    init(year: Int, month: Int, day: Int, hour: Int = 12,
         calendar: Calendar = FixedDateProvider.utcCalendar) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        self.calendar = calendar
        self.now = calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}
