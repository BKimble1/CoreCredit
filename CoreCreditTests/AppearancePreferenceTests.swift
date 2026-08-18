//
//  AppearancePreferenceTests.swift
//  CoreCreditTests
//
//  The appearance switch: what a fresh install gets, what a chosen value survives, and what
//  happens when the stored value is nonsense.
//
//  CoreCredit forces an appearance, which most apps should not. The reason is in
//  `AppearancePreference`: the light scheme is the one built for the job, and a phone left on Dark
//  because it is easier to read in bed is not a statement about a parts counter. So `.light` is
//  the default *deliberately*, and this file is what stops that decision decaying into an accident.
//

import Foundation
import SwiftUI
import Testing
@testable import CoreCredit

@Suite("The appearance preference defaults to Light, persists, and cannot be corrupted into nothing")
struct AppearancePreferenceTests {

    /// A throwaway defaults suite per test, so nothing here can read or write the real one.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "corecredit.tests.appearance." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - The default

    @Test("A fresh install opens in Light, not in whatever the phone is set to")
    @MainActor
    func aFreshInstallIsLight() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let controller = AppearanceController(defaults: defaults)
        #expect(controller.preference == .light)
        #expect(AppearancePreference.default == .light)
    }

    @Test("Light and Dark force a scheme; Match device defers to the system")
    func theSchemeMappingIsWhatItSays() {
        #expect(Palette.colorScheme(for: .light) == .light)
        #expect(Palette.colorScheme(for: .dark) == .dark)
        #expect(Palette.colorScheme(for: .system) == nil,
                "`nil` is what hands the decision back to iOS. Anything else forces an appearance.")
    }

    // MARK: - Persistence

    @Test("A choice survives the next launch")
    @MainActor
    func aChoiceSurvivesRelaunch() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = AppearanceController(defaults: defaults)
        first.preference = .dark

        // A second controller over the same defaults is what the next cold start looks like.
        let second = AppearanceController(defaults: defaults)
        #expect(second.preference == .dark)
    }

    @Test("Every option round-trips, including the one that means 'don't force anything'")
    @MainActor
    func everyOptionRoundTrips() throws {
        for option in AppearancePreference.allCases {
            let (defaults, name) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: name) }

            AppearanceController(defaults: defaults).preference = option
            #expect(AppearanceController(defaults: defaults).preference == option)
        }
    }

    // MARK: - Nothing can leave the app with no appearance

    @Test("An unreadable stored value falls back to Light rather than to nothing")
    @MainActor
    func aCorruptStoredValueFallsBack() throws {
        for junk in ["", "  ", "LIGHT", "sepia", "system\n", "0"] {
            let (defaults, name) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: name) }

            defaults.set(junk, forKey: AppearanceController.storageKey)
            #expect(AppearanceController(defaults: defaults).preference == .light,
                    "A stored value of \(junk.debugDescription) should fall back to the default.")
        }

        #expect(AppearancePreference.named(nil) == .light)
    }

    // MARK: - The Settings screen has something to show

    @Test("Every option is offered, exactly once, and each says what it does")
    func everyOptionIsOfferedOnce() {
        let order = AppearancePreference.displayOrder
        #expect(Set(order) == Set(AppearancePreference.allCases),
                """
                The Settings screen lists displayOrder, so an option missing from it is an option nobody can \
                choose.
                """)
        #expect(order.count == AppearancePreference.allCases.count, "An option is listed twice.")
        #expect(order.first == .light, "The default should be the first thing offered.")

        for option in order {
            #expect(option.displayName.isEmpty == false)
            #expect(option.explanation.isEmpty == false)
            #expect(option.symbolName.isEmpty == false)
        }
    }

    @Test("The Settings identifiers are stable and one per option")
    func theSettingsIdentifiersAreStable() {
        #expect(A11y.Settings.appearance == "settings.appearance")
        #expect(A11y.Appearance.root == "appearance.root")

        let identifiers = AppearancePreference.allCases.map { A11y.Appearance.option($0.rawValue) }
        #expect(Set(identifiers).count == identifiers.count, "Two options share an identifier.")
        #expect(identifiers.contains("appearance.option.light"))
        #expect(identifiers.contains("appearance.option.dark"))
        #expect(identifiers.contains("appearance.option.system"))
    }
}
