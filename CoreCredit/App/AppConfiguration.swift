//
//  AppConfiguration.swift
//  CoreCredit
//

import Foundation
import UIKit

/// Single place to change the working name, identifiers, and placeholder URLs before release.
///
/// # Pre-release checklist — everything in this file that must change before submission
///
/// 1. `displayName` — the shipping product name. Must also be updated in the Xcode target's
///    `INFOPLIST_KEY_CFBundleDisplayName` build setting and in `CoreCredit.storekit`.
/// 2. `bundleIdentifier` — must match `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode target and the
///    App ID registered in the Apple Developer portal.
/// 3. `monthlyProductID` / `annualProductID` — must match, character for character, the product
///    identifiers in `StoreKit/CoreCredit.storekit` **and** in App Store Connect. A mismatch is
///    silent: StoreKit simply returns no products and the paywall shows its load-failure state.
/// 4. `subscriptionGroupIdentifier` — the numeric group ID App Store Connect assigns to the
///    subscription group. The placeholder here is the local `.storekit` file's value.
/// 5. `supportURLString`, `privacyURLString`, `termsURLString`, `supportEmail` — all four are
///    `example.com` placeholders. App Review rejects builds whose support and privacy URLs do
///    not resolve to real, reachable pages.
/// 6. `defaultCurrencyCode` — only if the shop's default ledger currency is not US dollars.
///    Individual shops can still override this in Settings; this is only the seed value.
/// 7. `urlScheme` — must match the `CFBundleURLSchemes` entry in the target's Info settings if
///    bin-tag QR deep links are enabled for the shipping build.
///
/// Nothing else in the app hard-codes any of these values. `appVersion` and `buildNumber` are
/// read from the bundle at runtime, so the marketing version and build number are edited in the
/// Xcode target, never here.
enum AppConfiguration {

    // MARK: Identity

    static let displayName = "CoreCredit"
    static let bundleIdentifier = "com.example.corecredit"

    // MARK: StoreKit — must match StoreKit/CoreCredit.storekit and App Store Connect

    static let monthlyProductID = "com.example.corecredit.pro.monthly"
    static let annualProductID  = "com.example.corecredit.pro.annual"
    static let subscriptionGroupIdentifier = "21500000"

    /// The full set of identifiers requested from StoreKit on launch.
    static var subscriptionProductIDs: [String] { [monthlyProductID, annualProductID] }

    // MARK: Placeholder URLs — owner must replace before submission

    static let supportURLString = "https://example.com/corecredit/support"
    static let privacyURLString = "https://example.com/corecredit/privacy"
    static let termsURLString   = "https://example.com/corecredit/terms"
    static let supportEmail     = "support@example.com"

    /// Used instead of force-unwrapping a `URL`. Navigating to it is harmless and obviously wrong,
    /// which is the point: a malformed placeholder should be visible, not a crash.
    static let fallbackURL = URL(fileURLWithPath: "/")

    static var supportURL: URL { URL(string: supportURLString) ?? fallbackURL }
    static var privacyURL: URL { URL(string: privacyURLString) ?? fallbackURL }
    static var termsURL: URL   { URL(string: termsURLString) ?? fallbackURL }

    // MARK: Policy

    /// How many *unresolved* cores a free shop may track at once. Existing records are never gated.
    static let freeUnresolvedItemLimit = 5
    static let defaultVendorReturnWindowDays = 30
    static let defaultReminderLeadDays = 3
    static let defaultReminderHour = 8
    static let defaultReminderMinute = 0
    static let defaultCurrencyCode = "USD"

    // MARK: Attachments

    /// Longest edge, in pixels, of a stored evidence photo after downsampling.
    static let attachmentMaxDimension: CGFloat = 2000
    static let attachmentJPEGQuality: CGFloat = 0.72
    /// Longest edge, in pixels, of the decoded thumbnail shown in attachment strips.
    static let thumbnailMaxDimension: CGFloat = 320

    // MARK: Exports

    /// Generated PDF/CSV/JSON files older than this are swept from the caches directory.
    static let exportRetention: TimeInterval = 24 * 60 * 60
    static let urlScheme = "corecredit"

    // MARK: Version

    /// `CFBundleShortVersionString`, falling back to "1.0" when the bundle has no value
    /// (unit-test hosts and some preview contexts).
    static var appVersion: String {
        bundleString(forKey: "CFBundleShortVersionString", fallback: fallbackAppVersion)
    }

    /// `CFBundleVersion`, falling back to "1".
    static var buildNumber: String {
        bundleString(forKey: "CFBundleVersion", fallback: fallbackBuildNumber)
    }

    /// Human-readable version for the About screen, e.g. `"1.0 (1)"`.
    static var versionDisplayString: String {
        appVersion + " (" + buildNumber + ")"
    }

    // MARK: Private

    private static let fallbackAppVersion = "1.0"
    private static let fallbackBuildNumber = "1"

    private static func bundleString(forKey key: String, fallback: String) -> String {
        guard let value = Bundle.main.infoDictionary?[key] as? String else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
