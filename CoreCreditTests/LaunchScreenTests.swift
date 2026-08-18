//
//  LaunchScreenTests.swift
//  CoreCreditTests
//
//  The load-in screen fails **silently**, which is the whole reason this file exists.
//
//  A `UILaunchScreen` dictionary that names an asset the catalog does not have does not crash and
//  does not warn: iOS paints the background and leaves the image out, or paints a plain system
//  background and leaves everything out. The app still opens, so nothing in a build log or a test
//  run would ever mention it — the only symptom is that the app starts on a white flash again, and
//  the only way to notice is to be looking at a device at the moment of launch.
//
//  So the four things that can quietly come apart are pinned here:
//
//  1. The `UILaunchScreen` dictionary survived the Info.plist merge. `GENERATE_INFOPLIST_FILE` is
//     on, and re-enabling `INFOPLIST_KEY_UILaunchScreen_Generation` in the build settings would
//     merge an **empty** dictionary on top of the one in `Config/CoreCredit-Info.plist` and silently
//     replace it with nothing.
//  2. Both named assets exist in the catalog.
//  3. The mark is a square canvas, because both layers size it by the screen's short side and a
//     non-square canvas would land at different sizes in each.
//  4. The gradient's midpoint really is the flat colour the static screen paints. That equality is
//     what makes the handover between the two layers invisible.
//
//  These read the *app* bundle: `CoreCreditTests` is app-hosted (`TEST_HOST` is `CoreCredit.app`),
//  so `Bundle.main` here is the built app and its asset catalog and merged Info.plist are the real
//  shipping ones rather than a copy.
//

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CoreCredit

@Suite("The load-in screen is wired up, and its two layers agree with each other")
struct LaunchScreenTests {

    // MARK: - The Info.plist survived its merge

    @Test("The shipping Info.plist still declares a launch screen, and it names both assets")
    func theLaunchScreenIsDeclared() throws {
        let raw = Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen")
        let launchScreen = try #require(
            raw as? [String: Any],
            "UILaunchScreen is missing from the built Info.plist. The most likely cause is "
                + "INFOPLIST_KEY_UILaunchScreen_Generation being switched back on in the build "
                + "settings: it merges an empty dictionary over Config/CoreCredit-Info.plist."
        )

        #expect(launchScreen["UIColorName"] as? String == LaunchPalette.backgroundAssetName)
        #expect(launchScreen["UIImageName"] as? String == LaunchPalette.markAssetName)
    }

    @Test("The URL scheme is still in the same merged Info.plist")
    func theURLSchemeSurvivedTheSameMerge() throws {
        // Same file, same merge. If the launch screen were ever lost to a generated key, this is
        // the assertion that says whether the whole file went or only that one dictionary.
        let types = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(AppConfiguration.urlScheme))
    }

    // MARK: - The assets are really there

    @Test("Both launch assets resolve out of the shipping asset catalog")
    @MainActor
    func bothLaunchAssetsResolve() throws {
        let mark = UIImage(named: LaunchPalette.markAssetName)
        #expect(mark != nil,
                "LaunchMark is missing. The static launch screen would paint the background and "
                    + "no mark, and LaunchSplashView would render an empty image.")

        let background = UIColor(named: LaunchPalette.backgroundAssetName)
        #expect(background != nil,
                "LaunchBackground is missing. The static launch screen would fall back to a plain "
                    + "system background — a white flash in light appearance, which is the exact "
                    + "thing this screen exists to remove.")
    }

    @Test("The mark's canvas is square, so both layers place it identically")
    @MainActor
    func theMarkCanvasIsSquare() throws {
        let mark = try #require(UIImage(named: LaunchPalette.markAssetName))

        // The static launch screen aspect-fits this canvas; `LaunchSplashView` draws it at the
        // screen's short side. Both land the mark in the same place only while the canvas is
        // square and the mark is centred in it with the padding baked in.
        #expect(mark.size.width == mark.size.height,
                "LaunchMark must be a square canvas, not a tight crop of the mark.")
        #expect(mark.size.width > 0)
    }

    // MARK: - The two layers agree

    @Test("The gradient's midpoint is exactly the colour the static screen paints flat")
    @MainActor
    func theGradientMidpointMatchesTheStaticScreen() throws {
        let asset = try #require(UIColor(named: LaunchPalette.backgroundAssetName))
        let midpoint = UIColor(LaunchPalette.middle)

        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        // Both appearances, because a launch screen has no reading surface to adapt for: the brand
        // is the brand, and a colour that shifted in dark mode would make the handover visible on
        // exactly half of the devices it runs on.
        for (name, traits) in [("light", light), ("dark", dark)] {
            let assetComponents = LaunchScreenTests.components(of: asset, in: traits)
            let midComponents = LaunchScreenTests.components(of: midpoint, in: traits)
            #expect(LaunchScreenTests.isSameColour(assetComponents, midComponents),
                    "In \(name) appearance the LaunchBackground asset \(assetComponents) and the "
                        + "gradient midpoint \(midComponents) have drifted apart, so the static "
                        + "launch screen and the splash no longer meet on the same colour.")
        }
    }

    @Test("The load-in is short, and its parts add up to less than a second")
    func theLoadInIsShort() {
        // A launch screen nobody complains about is one nobody notices. If these ever add up to
        // something a person would describe as "waiting", the reason to have it has gone.
        let total = LaunchSplash.settleDuration + LaunchSplash.dwellDuration + LaunchSplash.fadeDuration
        #expect(total < 1.0, "The whole load-in is \(total)s, which is long enough to feel like a wait.")

        for duration in [LaunchSplash.settleDuration, LaunchSplash.dwellDuration, LaunchSplash.fadeDuration] {
            #expect(duration > 0)
        }
    }

    @Test("The mark fraction is a plausible splash proportion")
    func theMarkFractionIsSane() {
        // Baked into the asset as well as read here — see `LaunchSplashView.markFraction`. The
        // bound is wide on purpose: this catches a decimal point in the wrong place, not a taste
        // disagreement.
        #expect(LaunchSplashView.markFraction > 0.15)
        #expect(LaunchSplashView.markFraction < 0.6)
    }

    // MARK: - Helpers

    @MainActor
    private static func components(of color: UIColor,
                                   in traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    /// Compared with a tolerance, not for equality: the asset catalog round-trips its components
    /// through a stored sRGB representation, and a hand-written `Color` does not, so the last bit
    /// of a channel is not something to hold anybody to.
    private static func isSameColour(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where abs(left - right) > 0.01 {
            return false
        }
        return true
    }
}
