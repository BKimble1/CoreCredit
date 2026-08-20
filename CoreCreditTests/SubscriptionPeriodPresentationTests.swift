//
//  SubscriptionPeriodPresentationTests.swift
//  CoreCreditTests
//
//  The one sentence CoreCredit says about a paid subscription period.
//
//  ## Why this suite exists
//
//  A shop owner bought the monthly plan and then read a renewal date that was not a month away.
//  Two things were true at once, and only one of them was CoreCredit's to fix.
//
//  The date was real. In the App Store sandbox a one-month subscription lasts five minutes by
//  default, and in TestFlight every duration renews in a day. StoreKit reported an expiry hours
//  away because the period genuinely was hours long. The word "Renews" came from Apple's own
//  Subscriptions screen, not from this app — `git log -S Renews` finds it in no commit on any
//  branch of this repository.
//
//  What *is* CoreCredit's to hold is the wording, and the promise never to compute a date. Those
//  are asserted here rather than left in a `body`, because both failure modes are silent: a
//  plausible-looking sentence and a plausible-looking date are indistinguishable from correct ones
//  until a paying customer reads them.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("How the app talks about the end of a paid subscription period")
struct SubscriptionPeriodPresentationTests {

    /// Fixed so an assertion is about the wording and the day, never about the machine's region.
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.gmt

    private static func pro(expiring expiration: Date?) -> Entitlement {
        Entitlement(tier: .pro,
                    expirationDate: expiration,
                    isInGracePeriod: false,
                    lastVerified: TestClock.referenceNow,
                    activeProductID: AppConfiguration.monthlyProductID)
    }

    private static func row(_ entitlement: Entitlement, now: Date) -> SubscriptionPeriodRow? {
        SubscriptionPeriodPresentation.row(for: entitlement,
                                           now: now,
                                           locale: locale,
                                           timeZone: timeZone)
    }

    // MARK: - The date is the store's

    @Test("The date shown is the transaction's expiry, not a month added to anything")
    func theDateIsTheStoresOwn() throws {
        // The exact shape of the reported issue: a monthly plan bought on 19 August whose period,
        // in a test environment, ends the same day. The app must show that day — the store's
        // answer — and must not "correct" it into 19 September.
        let purchased = TestClock.date(year: 2026, month: 8, day: 19, hour: 9)
        let acceleratedExpiry = TestClock.date(year: 2026, month: 8, day: 19, hour: 9, minute: 5)

        let row = try #require(Self.row(Self.pro(expiring: acceleratedExpiry), now: purchased))

        #expect(row.value == "Aug 19, 2026",
                "The row must render the expiry StoreKit reported, to the day.")
        #expect(row.value.contains("Sep") == false,
                "A computed 'one month later' date would be a confident lie in every environment.")
    }

    @Test("A real-world monthly period renders its real end date")
    func aProductionPeriodRendersItsOwnDate() throws {
        let now = TestClock.date(year: 2026, month: 8, day: 19)
        let expiry = TestClock.date(year: 2026, month: 9, day: 19)

        let row = try #require(Self.row(Self.pro(expiring: expiry), now: now))

        #expect(row.value == "Sep 19, 2026")
        #expect(row.label == SubscriptionPeriodPresentation.futureLabel)
    }

    // MARK: - The wording is environment-neutral

    @Test("The wording never promises a renewal the app cannot see")
    func theWordingNeverPromisesARenewal() throws {
        let now = TestClock.date(year: 2026, month: 8, day: 19)
        let future = try #require(Self.row(Self.pro(expiring: TestClock.date(year: 2026, month: 9, day: 19)),
                                           now: now))
        let past = try #require(Self.row(Self.pro(expiring: TestClock.date(year: 2026, month: 8, day: 1)),
                                         now: now))

        // Auto-renew may already be off, the subscription may be in billing retry, and the period
        // may be an accelerated test one. None of those are visible here, so none may be implied.
        let forbidden = ["Renews", "renews", "Renewal", "Next charge", "next charge",
                         "Next payment", "Next bill", "Auto-renews"]
        for entry in forbidden {
            #expect(future.label.contains(entry) == false,
                    "The period row must not promise a renewal it cannot verify.")
            #expect(past.label.contains(entry) == false,
                    "The period row must not promise a renewal it cannot verify.")
        }

        #expect(future.label == "Current period ends")
        #expect(past.label == "Current period ended",
                "A period that has already lapsed is described in the past tense.")
    }

    @Test("A period already behind us is not described as still ending")
    func alapsedPeriodUsesThePastTense() throws {
        // Billing retry and grace period both look like this: the store still reports the
        // entitlement, and the expiry it reports has already gone by.
        let now = TestClock.date(year: 2026, month: 8, day: 19)
        let lapsed = TestClock.date(year: 2026, month: 8, day: 18)

        let row = try #require(Self.row(Self.pro(expiring: lapsed), now: now))

        #expect(row.label == SubscriptionPeriodPresentation.pastLabel)
        #expect(row.value == "Aug 18, 2026")
    }

    @Test("The boundary instant still reads as the future")
    func theBoundaryInstantReadsAsFuture() throws {
        let instant = TestClock.date(year: 2026, month: 8, day: 19, hour: 9, minute: 5)
        let row = try #require(Self.row(Self.pro(expiring: instant), now: instant))

        #expect(row.label == SubscriptionPeriodPresentation.futureLabel,
                "Access is still paid for at the exact instant the period ends.")
    }

    // MARK: - Nothing to say is said as nothing

    @Test("No expiry means no row at all, rather than a blank or a guess")
    func noExpiryMeansNoRow() {
        let now = TestClock.referenceNow

        #expect(Self.row(Entitlement.free, now: now) == nil,
                "A free shop has no paid period to describe.")
        #expect(Self.row(Self.pro(expiring: nil), now: now) == nil,
                "Pro without a reported expiry is a gap in what the store said, not a zero.")
    }

    // MARK: - Formatting

    @Test("The date carries no time component")
    func theDateCarriesNoTime() {
        // A minute-precise timestamp would invite exactly the reading this type exists to avoid:
        // that the app knows the instant the next charge lands. It knows a day, from a transaction.
        let value = SubscriptionPeriodPresentation.formattedDate(
            TestClock.date(year: 2026, month: 8, day: 19, hour: 9, minute: 5),
            locale: Self.locale,
            timeZone: Self.timeZone
        )

        #expect(value == "Aug 19, 2026")
        #expect(value.contains(":") == false, "A clock time has no place on this row.")
    }

    // MARK: - The entitlement itself is never computed

    @Test("Pro is decided by the tier the store reported, not by comparing dates")
    func proIsDecidedByTierAlone() {
        // Deliberate: `isPro` must not start second-guessing StoreKit by expiring an entitlement
        // locally. `Transaction.currentEntitlements` already answers that question, on device and
        // offline, and it is the only answer that accounts for grace periods and billing retry.
        let lapsed = Self.pro(expiring: TestClock.date(year: 2020, month: 1, day: 1))
        #expect(lapsed.isPro, "Only the store may retire an entitlement.")

        let inGrace = Entitlement(tier: .pro,
                                  expirationDate: TestClock.date(year: 2020, month: 1, day: 1),
                                  isInGracePeriod: true,
                                  lastVerified: TestClock.referenceNow,
                                  activeProductID: AppConfiguration.monthlyProductID)
        #expect(inGrace.isPro)
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: inGrace.tier))
    }
}
