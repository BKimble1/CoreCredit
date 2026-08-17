//
//  DueDateCalculator.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// Turns a vendor's return window into a concrete deadline.
///
/// Every function takes the calendar as a parameter — nothing here reads `Calendar.current` — so
/// the same received date and window produce the same due date in every test and every time zone.
enum DueDateCalculator {

    /// Shortest window a vendor may be given. A zero-day window would make every core instantly
    /// overdue, which is never what the user meant.
    static let minimumWindowDays = 1

    /// Longest window a vendor may be given (one year).
    static let maximumWindowDays = 365

    /// Clamps a user-entered window into `minimumWindowDays ... maximumWindowDays`.
    static func clampWindowDays(_ days: Int) -> Int {
        if days < minimumWindowDays { return minimumWindowDays }
        if days > maximumWindowDays { return maximumWindowDays }
        return days
    }

    /// `startOfDay(receivedDate)` plus the clamped window, in whole calendar days.
    ///
    /// Normalising to the start of day first means two cores received on the same day always get
    /// the same deadline, whatever time of day they were entered.
    static func dueDate(receivedDate: Date, windowDays: Int, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: receivedDate)
        let clamped = clampWindowDays(windowDays)
        if let result = calendar.date(byAdding: .day, value: clamped, to: start) {
            return result
        }
        // Only reachable if the calendar cannot represent the date; fall back to plain arithmetic.
        return start.addingTimeInterval(TimeInterval(clamped) * 86_400)
    }

    /// Whole calendar days from `from` to `to`, both normalised to the start of their day.
    ///
    /// Negative when `to` precedes `from`. Because both ends are normalised, a difference of `0`
    /// means "the same calendar day", regardless of clock time.
    static func dayDifference(from: Date, to: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}
