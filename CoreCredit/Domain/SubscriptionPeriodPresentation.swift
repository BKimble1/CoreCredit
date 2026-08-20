//
//  SubscriptionPeriodPresentation.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — no StoreKit, no SwiftUI.
//

import Foundation

/// One rendered row of subscription period information: a label and the date beside it.
struct SubscriptionPeriodRow: Equatable, Sendable {

    /// The wording to the left, e.g. `"Current period ends"`.
    var label: String

    /// The formatted date to the right, e.g. `"Aug 19, 2026"`.
    var value: String
}

/// How CoreCredit talks about the end of a paid subscription period.
///
/// # Why this is a type and not two lines inside a view
///
/// A shop owner bought a monthly subscription and then read a date that did not look like a month
/// away. That is what an accelerated test environment produces, and it is *correct* — but only if
/// the app is careful never to dress that date up as something it is not. The wording is therefore
/// a thing this repository can assert on, rather than a string literal buried in a `body`.
///
/// # The two rules
///
/// **1. The date is the store's, never ours.** This type formats `Entitlement.expirationDate`,
/// which comes verbatim from `StoreKit.Transaction.expirationDate`. Nothing here — and nothing
/// anywhere in the app — computes "one month after the purchase". In the sandbox a month is five
/// minutes and in TestFlight it is a day; a calculated date would be a confident lie in both, and
/// would still be wrong in production the first time Apple moved a renewal for a billing retry,
/// a plan change, or a grace period.
///
/// **2. The wording is environment-neutral.** "Renews on…" is a promise about the future that the
/// app is not entitled to make: auto-renew may already be switched off, the subscription may be in
/// billing retry, or the period may be an accelerated test one. "Current period ends" states only
/// what the transaction actually says — when the access that has been paid for runs out. Whether
/// another period follows is the App Store's business, and the App Store's own screens say so.
enum SubscriptionPeriodPresentation {

    /// Wording for a period that has not run out yet.
    static let futureLabel = "Current period ends"

    /// Wording for a period whose end has already passed.
    ///
    /// Reachable in normal use: during billing retry and grace period the store still reports the
    /// entitlement as active while `expirationDate` sits in the past. Saying "ends" there is
    /// simply the wrong tense, and the screen already explains the retry beside it.
    static let pastLabel = "Current period ended"

    /// The row to draw, or `nil` when there is no date to show.
    ///
    /// `nil` covers a free shop and a Pro entitlement the store reported without an expiry. Both
    /// mean "there is nothing truthful to say here", and an absent row says that better than an
    /// empty one or a guess.
    static func row(for entitlement: Entitlement,
                    now: Date,
                    locale: Locale = .current,
                    timeZone: TimeZone = .current) -> SubscriptionPeriodRow? {
        guard let expiration = entitlement.expirationDate else { return nil }

        return SubscriptionPeriodRow(
            label: expiration < now ? pastLabel : futureLabel,
            value: formattedDate(expiration, locale: locale, timeZone: timeZone)
        )
    }

    /// Day-precision, localized, no time component.
    ///
    /// `DateFormatter` rather than a `FormatStyle` so the locale and time zone are both explicit
    /// parameters: a test that pins them is asserting on the wording and the day, not on whatever
    /// region the machine running it happens to be set to.
    ///
    /// The time is omitted deliberately. A renewal date is a day to a shop owner, and a
    /// minute-precise timestamp on this row would invite exactly the reading this type exists to
    /// avoid — that the app knows the instant the next charge lands.
    static func formattedDate(_ date: Date,
                              locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
