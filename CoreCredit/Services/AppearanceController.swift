//
//  AppearanceController.swift
//  CoreCredit
//
//  Side-effect layer — remembers which appearance the shop chose.
//

import Foundation
import Observation

/// Holds the chosen `AppearancePreference` and writes it straight through to `UserDefaults`.
///
/// # Why this is not on `ShopProfile`
///
/// Everything else a shop configures lives in SwiftData on the profile, and this deliberately does
/// not. Three reasons, in order of how much they matter:
///
/// 1. **It is not shop data.** It never belongs in a CSV export, a JSON backup, or a dispute
///    packet. `ShopProfile` is a record of the business; this is a preference about a screen.
/// 2. **It must be readable before the store is.** The appearance is applied at the very root of
///    the scene, above the branch that decides between `StoreUnavailableView`, onboarding, and the
///    tab bar — so it has to work on a launch where SwiftData never opened at all.
/// 3. **A new SwiftData property costs a schema version and a migration stage** (see
///    `docs/SCAN_CONTRACTS.md` rule 8). That is the right price for a core's data and far too high
///    for a display switch.
///
/// It follows `EntitlementCache`'s pattern: `UserDefaults`, injectable so tests get their own
/// suite and never touch the real one.
@MainActor
@Observable
final class AppearanceController {

    /// The chosen appearance. Writing it persists immediately — there is no Save button on a
    /// setting whose whole effect is visible the instant it changes.
    var preference: AppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: AppearanceController.storageKey)
        }
    }

    /// Where the choice is written. `@ObservationIgnored` because the store is not state anybody
    /// observes — only `preference` is.
    @ObservationIgnored private let defaults: UserDefaults

    /// Namespaced under the app, like every other key this app owns.
    static let storageKey = "com.blakekimble.corecredit.appearance"

    /// - Parameter defaults: Where to read and write. Tests pass their own suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preference = AppearancePreference.named(
            defaults.string(forKey: AppearanceController.storageKey)
        )
    }
}
