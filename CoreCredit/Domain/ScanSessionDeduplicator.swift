//
//  ScanSessionDeduplicator.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//
//  ## The problem
//
//  A live data-scanning session fires its callback many times a second while the symbol stays in
//  frame. Without suppression, holding a part in front of the camera for one second produces a
//  dozen "scan accepted" haptics, a dozen candidate sets, and a review sheet that re-renders under
//  the user's thumb. Worse, panning across a shelf of labelled bins re-accepts a code the user
//  already dealt with.
//
//  ## The rules
//
//  1. **One acceptance per payload per session.** Once a code has been accepted, it is done until
//     `reset()`. Panning back over it does nothing.
//  2. **A cooldown between acceptances.** Two *different* codes read within `cooldown` of each
//     other are one fumble, not two intentional scans.
//
//  The clock is a parameter, never a property: `accept(payload:symbology:now:)` takes `now`, so a
//  unit test can drive a whole session deterministically and the coordinator can feed it
//  `AppEnvironment.dateProvider`. Nothing in this file reads the wall clock.
//

import Foundation

/// One accepted scan, recorded so the cooldown has something to measure from.
struct ScanAcceptance: Equatable, Sendable {
    var payload: String
    var symbology: String
    var acceptedAt: Date

    init(payload: String, symbology: String, acceptedAt: Date) {
        self.payload = payload
        self.symbology = symbology
        self.acceptedAt = acceptedAt
    }
}

/// Decides whether a scan the camera just reported should be acted on.
///
/// A value type on purpose: the scanner coordinator owns one, a test can own one, and neither can
/// accidentally share mutable state with the other.
struct ScanSessionDeduplicator: Equatable, Sendable {

    /// 1.25 s — long enough to swallow the burst from a single symbol held in frame, short enough
    /// that a technician deliberately scanning a second part does not feel the app ignore them.
    static let defaultCooldown: TimeInterval = 1.25

    /// Minimum gap between two acceptances.
    let cooldown: TimeInterval

    /// The most recent acceptance, or `nil` before the first one.
    private(set) var lastAcceptance: ScanAcceptance?

    /// Every payload accepted since the last `reset()`.
    private(set) var acceptedPayloads: Set<String>

    init(cooldown: TimeInterval = ScanSessionDeduplicator.defaultCooldown) {
        self.cooldown = cooldown
        self.lastAcceptance = nil
        self.acceptedPayloads = []
    }

    /// Returns `true` — and records the scan — when it is new **and** the cooldown has elapsed.
    ///
    /// Returns `false`, recording nothing, when:
    /// - the payload is empty (a decode that produced nothing is not a scan);
    /// - the payload was already accepted in this session, whatever symbology it arrived under;
    /// - `now` is less than `cooldown` after the previous acceptance.
    ///
    /// A `now` that is *earlier* than the last acceptance also fails the cooldown test. That is
    /// deliberate: a clock that jumped backwards should make the scanner conservative, not
    /// trigger-happy.
    ///
    /// The boundary is inclusive — a scan exactly `cooldown` seconds after the previous one is
    /// accepted, because the guard is `elapsed >= cooldown`.
    mutating func accept(payload: String, symbology: String, now: Date) -> Bool {
        guard !payload.isEmpty else { return false }
        guard !acceptedPayloads.contains(payload) else { return false }

        if let last = lastAcceptance {
            let elapsed = now.timeIntervalSince(last.acceptedAt)
            guard elapsed >= cooldown else { return false }
        }

        acceptedPayloads.insert(payload)
        lastAcceptance = ScanAcceptance(payload: payload, symbology: symbology, acceptedAt: now)
        return true
    }

    /// Forgets everything, so the same code can be scanned again.
    ///
    /// Called when the user taps "Resume scanning" after cancelling a review, and when a new
    /// scanning session begins. `cooldown` is a configuration value and survives.
    mutating func reset() {
        lastAcceptance = nil
        acceptedPayloads = []
    }
}
