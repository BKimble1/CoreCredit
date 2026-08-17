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
/// 3. `monthlyProductID` / `annualProductID` — SET. These are the final App Store Connect
///    identifiers and must stay in step with `StoreKit/CoreCredit.storekit`, character for
///    character. A mismatch is silent: StoreKit returns no products and the paywall falls back
///    to its retry state rather than reporting anything wrong.
/// 4. `subscriptionGroupIdentifier` — the local `.storekit` group number. Nothing reads it today,
///    so it is metadata; replace it if any code starts querying the group directly.
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
    static let bundleIdentifier = "com.blakekimble.corecredit"

    // MARK: StoreKit — must match StoreKit/CoreCredit.storekit and App Store Connect

    /// The final App Store Connect product identifiers.
    ///
    /// These are the single source of truth in Swift — nothing else in the app target spells a
    /// product identifier. They must match `StoreKit/CoreCredit.storekit` and App Store Connect
    /// character for character; a mismatch is silent, because StoreKit simply returns no products
    /// and the paywall falls back to its retry state rather than reporting anything wrong.
    static let monthlyProductID = "com.blakekimble.corecredit.pro.monthly"
    static let annualProductID  = "com.blakekimble.corecredit.pro.annual"

    /// The local `.storekit` group number. Nothing in the app reads this today — subscription
    /// status is resolved per product — so it is metadata rather than behaviour. Replace it with
    /// the real App Store Connect group ID if anything ever starts querying the group directly.
    static let subscriptionGroupIdentifier = "21500000"

    /// The full set of identifiers requested from StoreKit on launch.
    static var subscriptionProductIDs: [String] { [monthlyProductID, annualProductID] }

    // MARK: - OWNER-SUPPLIED VALUES — required before public release
    //
    // Everything between here and the end of this section is a stand-in. The app is written so that
    // a stand-in is *never printed to the screen*: the legal documents ship inside the app and are
    // read natively, and any screen that would otherwise show one of these addresses hides the row
    // and says plainly that a contact has not been set up yet.
    //
    // Replacing a value is the only step needed to make the matching UI appear — `isPlaceholder(_:)`
    // below decides that at runtime, so nothing else has to be edited.
    //
    // Still outstanding, and *not* invented anywhere in this codebase:
    //   * the legal name of the developer or company, and a postal address if one is required
    //   * a governing law and venue for the Terms of Use
    //   * a working support email address and support page
    //   * the published web addresses of the privacy policy and terms (App Review requires these to
    //     resolve; the in-app copies do not depend on them)
    // These appear in the bundled documents as `[TO BE SUPPLIED BY OWNER - …]` markers, and in
    // `docs/legal-public/*.html`, which are the pages to publish at the addresses below.

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

    /// True while a value is still one of the stand-ins shipped above.
    ///
    /// Deriving this rather than hard-coding a flag means every "not configured yet" message in the
    /// app disappears by itself the moment a real address is filled in — and, more importantly, that
    /// no screen can accidentally print `example.com` to a shop owner or an App Review reader.
    /// An empty or whitespace-only value counts as unconfigured too.
    /// The reserved domains RFC 2606 sets aside for documentation. Matching on the whole label
    /// rather than a bare substring matters: a real host such as `myexample.company` *contains*
    /// "example.com" and must not be mistaken for a stand-in.
    private static let placeholderHosts = ["example.com", "example.org", "example.net"]

    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }

        // A reserved host, as its own label: preceded by the start of the string, a dot, a slash,
        // or an `@`, and followed by the end, a slash, a colon, or a dot.
        for host in placeholderHosts where trimmed.contains(host) {
            var searchRange = trimmed.startIndex..<trimmed.endIndex
            while let found = trimmed.range(of: host, range: searchRange) {
                let beforeOK: Bool
                if found.lowerBound == trimmed.startIndex {
                    beforeOK = true
                } else {
                    let previous = trimmed[trimmed.index(before: found.lowerBound)]
                    beforeOK = previous == "." || previous == "/" || previous == "@"
                }
                let afterOK: Bool
                if found.upperBound == trimmed.endIndex {
                    afterOK = true
                } else {
                    let next = trimmed[found.upperBound]
                    afterOK = next == "/" || next == ":" || next == "."
                }
                if beforeOK && afterOK { return true }
                searchRange = found.upperBound..<trimmed.endIndex
            }
        }
        return false
    }

    /// Whether the StoreKit product identifiers are real rather than the sample ones.
    ///
    /// Deliberately separate from `isPlaceholder(_:)`, which looks for a reserved *host*. A
    /// product identifier is reverse-DNS, not a URL: the substring in
    /// `com.example.corecredit.pro.monthly` is `example.cor`, so a host test can never catch it.
    ///
    /// This matters because shipping the samples fails *quietly* — StoreKit returns no products
    /// and the paywall shows its retry state, which looks like a network problem rather than a
    /// configuration one. True for the identifiers above.
    static var areSubscriptionProductIDsConfigured: Bool {
        subscriptionProductIDs.allSatisfy { $0.hasPrefix("com.example.") == false }
    }

    /// Whether there is any way at all for a shop to reach support.
    static var isSupportContactConfigured: Bool {
        configuredSupportURL != nil || configuredSupportEmail != nil
    }

    /// The support page, or `nil` while it is still a stand-in.
    static var configuredSupportURL: URL? { configuredURL(supportURLString) }

    /// The published privacy policy page, or `nil` while it is still a stand-in.
    ///
    /// The in-app privacy policy does not need this: it is bundled and rendered natively. This is
    /// only for the case where the bundled copy could not be read.
    static var configuredPrivacyURL: URL? { configuredURL(privacyURLString) }

    /// The published terms page, or `nil` while it is still a stand-in.
    static var configuredTermsURL: URL? { configuredURL(termsURLString) }

    /// The support address, or `nil` while it is still a stand-in.
    static var configuredSupportEmail: String? {
        isPlaceholder(supportEmail) ? nil : supportEmail
    }

    private static func configuredURL(_ value: String) -> URL? {
        guard isPlaceholder(value) == false else { return nil }
        return URL(string: value)
    }

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
