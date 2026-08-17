//
//  ScanDeduplicationTests.swift
//  CoreCreditTests
//
//  A live data-scanning session fires many times a second while a symbol stays in frame. Without
//  suppression, holding a part in front of the camera for one second produces a dozen haptics and a
//  review sheet that re-renders under the user's thumb.
//
//  `ScanSessionDeduplicator` takes `now` as a parameter rather than reading a clock, which is what
//  makes a whole session drivable from a test. Every instant below comes from `TestClock`; nothing
//  here calls `Date()`.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("The same code is accepted once, and a fumble inside the cooldown is not a second scan")
struct ScanDeduplicationTests {

    /// 12 March 2026, 09:00 UTC. Every other instant is derived from this one.
    private let start = TestClock.date(year: 2026, month: 3, day: 12, hour: 9, minute: 0)

    private let code128 = "VNBarcodeSymbologyCode128"

    // MARK: - Duplicate suppression

    @Test("The same stationary barcode does not fire twice")
    func theSameStationaryBarcodeDoesNotFireTwice() throws {
        var deduplicator = ScanSessionDeduplicator()

        #expect(deduplicator.accept(payload: "03-1887", symbology: code128, now: start))

        // The camera reports the same symbol again a fraction of a second later. It is one part,
        // held still, not a second scan.
        #expect(deduplicator.accept(payload: "03-1887",
                                    symbology: code128,
                                    now: start.addingTimeInterval(0.1)) == false)

        // And it is still the same part a minute later, after the cooldown is long past.
        #expect(deduplicator.accept(payload: "03-1887",
                                    symbology: code128,
                                    now: start.addingTimeInterval(60)) == false)

        let acceptance = try #require(deduplicator.lastAcceptance)
        #expect(acceptance.payload == "03-1887")
        #expect(acceptance.symbology == code128)
        #expect(acceptance.acceptedAt == start)
        #expect(deduplicator.acceptedPayloads == ["03-1887"])
    }

    @Test("An empty payload is not a scan")
    func anEmptyPayloadIsNotAScan() {
        var deduplicator = ScanSessionDeduplicator()

        #expect(deduplicator.accept(payload: "", symbology: code128, now: start) == false)
        #expect(deduplicator.lastAcceptance == nil)
        #expect(deduplicator.acceptedPayloads.isEmpty)
    }

    // MARK: - Cooldown

    @Test("The cooldown is measured against an injected clock, never the wall clock")
    func theCooldownIsMeasuredAgainstAnInjectedClock() {
        var deduplicator = ScanSessionDeduplicator()
        #expect(deduplicator.cooldown == ScanSessionDeduplicator.defaultCooldown)
        #expect(ScanSessionDeduplicator.defaultCooldown == 1.25)

        // The first read of the session is always accepted.
        #expect(deduplicator.accept(payload: "03-1887", symbology: code128, now: start))

        // A *different* code half a second later is a fumble across a shelf of labelled bins.
        #expect(deduplicator.accept(payload: "17-4420",
                                    symbology: code128,
                                    now: start.addingTimeInterval(0.5)) == false)

        // The same code after the window is still refused — it was already dealt with.
        #expect(deduplicator.accept(payload: "03-1887",
                                    symbology: code128,
                                    now: start.addingTimeInterval(1.25)) == false)

        // A different code after the window is a deliberate second scan, and is accepted. The
        // boundary is inclusive: exactly `cooldown` seconds after the last acceptance counts.
        #expect(deduplicator.accept(payload: "17-4420",
                                    symbology: code128,
                                    now: start.addingTimeInterval(1.25)))

        #expect(deduplicator.acceptedPayloads == ["03-1887", "17-4420"])
        #expect(deduplicator.lastAcceptance?.payload == "17-4420")
        #expect(deduplicator.lastAcceptance?.acceptedAt == start.addingTimeInterval(1.25))
    }

    @Test("A custom cooldown is honoured and a clock that jumps backwards makes the gate stricter")
    func aCustomCooldownIsHonouredAndABackwardClockIsConservative() {
        var deduplicator = ScanSessionDeduplicator(cooldown: 5)
        #expect(deduplicator.cooldown == 5)

        #expect(deduplicator.accept(payload: "03-1887", symbology: code128, now: start))
        #expect(deduplicator.accept(payload: "17-4420",
                                    symbology: code128,
                                    now: start.addingTimeInterval(4.9)) == false)
        #expect(deduplicator.accept(payload: "17-4420",
                                    symbology: code128,
                                    now: start.addingTimeInterval(5)))

        // A clock that jumped backwards should make the scanner conservative, not trigger-happy.
        #expect(deduplicator.accept(payload: "CAL-118",
                                    symbology: code128,
                                    now: start.addingTimeInterval(-3_600)) == false)
    }

    // MARK: - Resetting

    @Test("Resetting forgets the session so the same code can be scanned again")
    func resettingForgetsTheSession() {
        var deduplicator = ScanSessionDeduplicator()

        #expect(deduplicator.accept(payload: "03-1887", symbology: code128, now: start))
        #expect(deduplicator.accept(payload: "03-1887",
                                    symbology: code128,
                                    now: start.addingTimeInterval(10)) == false)

        deduplicator.reset()

        #expect(deduplicator.lastAcceptance == nil)
        #expect(deduplicator.acceptedPayloads.isEmpty)
        // The cooldown is configuration, so it survives a reset.
        #expect(deduplicator.cooldown == ScanSessionDeduplicator.defaultCooldown)

        // With nothing remembered, the same code is a new scan again — immediately.
        #expect(deduplicator.accept(payload: "03-1887",
                                    symbology: code128,
                                    now: start.addingTimeInterval(10)))
    }
}
