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

        // Each `accept` is bound to a `let` before it is asserted on, and must stay that way.
        // `accept` is `mutating`, and `#expect` expands its argument into a closure that captures
        // the expression immutably — calling a mutating member inside it does not compile
        // ("cannot use mutating member on immutable value"). Hoisting also keeps the mutation
        // order explicit, which matters here because every call changes what the next one returns.
        let firstRead = deduplicator.accept(payload: "03-1887", symbology: code128, now: start)
        #expect(firstRead)

        // The camera reports the same symbol again a fraction of a second later. It is one part,
        // held still, not a second scan.
        let immediateRepeat = deduplicator.accept(payload: "03-1887",
                                                  symbology: code128,
                                                  now: start.addingTimeInterval(0.1))
        #expect(immediateRepeat == false)

        // And it is still the same part a minute later, after the cooldown is long past.
        let repeatAfterCooldown = deduplicator.accept(payload: "03-1887",
                                                      symbology: code128,
                                                      now: start.addingTimeInterval(60))
        #expect(repeatAfterCooldown == false)

        let acceptance = try #require(deduplicator.lastAcceptance)
        #expect(acceptance.payload == "03-1887")
        #expect(acceptance.symbology == code128)
        #expect(acceptance.acceptedAt == start)
        #expect(deduplicator.acceptedPayloads == ["03-1887"])
    }

    @Test("An empty payload is not a scan")
    func anEmptyPayloadIsNotAScan() {
        var deduplicator = ScanSessionDeduplicator()

        let emptyRead = deduplicator.accept(payload: "", symbology: code128, now: start)
        #expect(emptyRead == false)
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
        let firstRead = deduplicator.accept(payload: "03-1887", symbology: code128, now: start)
        #expect(firstRead)

        // A *different* code half a second later is a fumble across a shelf of labelled bins.
        let fumbleInsideWindow = deduplicator.accept(payload: "17-4420",
                                                     symbology: code128,
                                                     now: start.addingTimeInterval(0.5))
        #expect(fumbleInsideWindow == false)

        // The same code after the window is still refused — it was already dealt with.
        let sameCodeAfterWindow = deduplicator.accept(payload: "03-1887",
                                                      symbology: code128,
                                                      now: start.addingTimeInterval(1.25))
        #expect(sameCodeAfterWindow == false)

        // A different code after the window is a deliberate second scan, and is accepted. The
        // boundary is inclusive: exactly `cooldown` seconds after the last acceptance counts.
        let newCodeAtBoundary = deduplicator.accept(payload: "17-4420",
                                                    symbology: code128,
                                                    now: start.addingTimeInterval(1.25))
        #expect(newCodeAtBoundary)

        #expect(deduplicator.acceptedPayloads == ["03-1887", "17-4420"])
        #expect(deduplicator.lastAcceptance?.payload == "17-4420")
        #expect(deduplicator.lastAcceptance?.acceptedAt == start.addingTimeInterval(1.25))
    }

    @Test("A custom cooldown is honoured and a clock that jumps backwards makes the gate stricter")
    func aCustomCooldownIsHonouredAndABackwardClockIsConservative() {
        var deduplicator = ScanSessionDeduplicator(cooldown: 5)
        #expect(deduplicator.cooldown == 5)

        let firstRead = deduplicator.accept(payload: "03-1887", symbology: code128, now: start)
        #expect(firstRead)

        let insideCustomWindow = deduplicator.accept(payload: "17-4420",
                                                     symbology: code128,
                                                     now: start.addingTimeInterval(4.9))
        #expect(insideCustomWindow == false)

        let atCustomBoundary = deduplicator.accept(payload: "17-4420",
                                                   symbology: code128,
                                                   now: start.addingTimeInterval(5))
        #expect(atCustomBoundary)

        // A clock that jumped backwards should make the scanner conservative, not trigger-happy.
        let backwardsClock = deduplicator.accept(payload: "CAL-118",
                                                 symbology: code128,
                                                 now: start.addingTimeInterval(-3_600))
        #expect(backwardsClock == false)
    }

    // MARK: - Resetting

    @Test("Resetting forgets the session so the same code can be scanned again")
    func resettingForgetsTheSession() {
        var deduplicator = ScanSessionDeduplicator()

        let firstRead = deduplicator.accept(payload: "03-1887", symbology: code128, now: start)
        #expect(firstRead)

        let repeatBeforeReset = deduplicator.accept(payload: "03-1887",
                                                    symbology: code128,
                                                    now: start.addingTimeInterval(10))
        #expect(repeatBeforeReset == false)

        deduplicator.reset()

        #expect(deduplicator.lastAcceptance == nil)
        #expect(deduplicator.acceptedPayloads.isEmpty)
        // The cooldown is configuration, so it survives a reset.
        #expect(deduplicator.cooldown == ScanSessionDeduplicator.defaultCooldown)

        // With nothing remembered, the same code is a new scan again — immediately.
        let afterReset = deduplicator.accept(payload: "03-1887",
                                             symbology: code128,
                                             now: start.addingTimeInterval(10))
        #expect(afterReset)
    }
}
