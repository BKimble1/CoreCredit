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
//  3. The mark is a square canvas, so it is centred rather than stretched.
//  4. The colour the launch screen paints really is the app's own accent — the icon's blue. If
//     those drift, the app opens in one colour and then becomes another one.
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

@Suite("The load-in screen is wired up, and it is painted in the app's own colour")
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

        #expect(launchScreen["UIColorName"] as? String == Palette.launchBackgroundAssetName)
        #expect(launchScreen["UIImageName"] as? String == Palette.launchMarkAssetName)
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
        let mark = UIImage(named: Palette.launchMarkAssetName)
        #expect(mark != nil,
                "LaunchMark is missing. The launch screen would paint the background and no mark.")

        let background = UIColor(named: Palette.launchBackgroundAssetName)
        #expect(background != nil,
                "LaunchBackground is missing. The static launch screen would fall back to a plain "
                    + "system background — a white flash in light appearance, which is the exact "
                    + "thing this screen exists to remove.")
    }

    @Test("The mark's canvas is square, so it is centred rather than stretched")
    @MainActor
    func theMarkCanvasIsSquare() throws {
        let mark = try #require(UIImage(named: Palette.launchMarkAssetName))

        // The launch screen fits this canvas to the screen. A square canvas with the mark centred
        // and the padding baked in is what keeps the mark centred and correctly sized; a tight
        // crop would be stretched across the full width.
        #expect(mark.size.width == mark.size.height,
                "LaunchMark must be a square canvas, not a tight crop of the mark.")
        #expect(mark.size.width > 0)
    }

    // MARK: - It is the app's own colour

    @Test("The launch screen is painted in the app's own accent, the icon's blue")
    @MainActor
    func theLaunchColourIsTheAppsAccent() throws {
        let asset = try #require(UIColor(named: Palette.launchBackgroundAssetName))

        // Compared in light, where `accent` holds the icon's value exactly. `accent` lifts in dark
        // so it can be read on a dark card; the launch screen does not, because it is the app
        // introducing itself rather than a surface being read — a brand that changed colour by
        // time of day would be a different app twice a day.
        let light = UITraitCollection(userInterfaceStyle: .light)
        let assetComponents = LaunchScreenTests.components(of: asset, in: light)
        let accentComponents = LaunchScreenTests.components(of: UIColor(Palette.accent), in: light)

        #expect(LaunchScreenTests.isSameColour(assetComponents, accentComponents),
                "The LaunchBackground asset and the app's accent have drifted apart, so the app "
                    + "opens in one colour and then becomes a different one.")
    }

    @Test("There is one launch layer, not two")
    @MainActor
    func thereIsNoSecondLaunchLayer() throws {
        // A second, animated SwiftUI layer over the static screen was tried and removed: handing
        // over from an image to a live view a frame later was visible, and a launch screen that
        // draws attention to itself has failed at the one thing it is for. The static screen does
        // the whole job, so this only has to hold its two assets in place.
        let raw = Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any]
        let launchScreen = try #require(raw)
        #expect(launchScreen["UIImageName"] as? String == Palette.launchMarkAssetName)
        #expect(UIImage(named: Palette.launchMarkAssetName) != nil)
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
