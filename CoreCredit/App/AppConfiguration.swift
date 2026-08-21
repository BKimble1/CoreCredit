//
//  AppConfiguration.swift
//  CoreCredit
//

import Foundation
import UIKit

/// Single place to change the working name, identifiers, and placeholder URLs before release.
///
/// # Pre-release checklist — everything in this file that had to change before submission
///
/// All of it is now supplied. The list is kept because each item explains *why* the value matters
/// and what breaks silently if it drifts.
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
/// 5. `supportURLString`, `privacyURLString`, `termsURLString`, `supportEmail` — SET. The three
///    pages are published on the owner's own domain, `corecredit.idlery.com`. The exact HTML that
///    host is expected to serve is generated into `docs/legal-public/` from the same JSON the app
///    reads on device, so the published wording and the on-device wording cannot drift.
///
///    **Not verified from this repository.** The session that moved these addresses could not
///    reach the host — its network policy blocks it — so nothing here has seen the pages answer.
///    App Review rejects a build whose support or privacy URL does not resolve, and that
///    rejection costs a review cycle. Open all three in a browser before every submission, and
///    again whenever the hosting moves.
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

    // MARK: - Publisher and public addresses
    //
    // All supplied. The app is written so that a *stand-in* is never printed to the screen —
    // `isPlaceholder(_:)` below decides that at runtime and hides any row that would otherwise show
    // one — and that machinery stays in place as a guard, not because anything here is provisional.
    //
    // The three URLs are live, static, public pages served over HTTPS from a repository that holds
    // nothing but those pages. They are generated from the same JSON the app reads natively out of
    // `CoreCredit/Resources/Legal/`, by `docs/tools/render_legal_pages.py`, so the published wording
    // and the on-device wording cannot drift apart. The app never fetches them; they exist because
    // App Review needs an address it can open.

    /// The legal entity that publishes CoreCredit. This is the name that appears in the legal
    /// documents, on the public pages, and as the App Store seller — never an individual's name.
    static let companyName = "Idlery Services LLC"

    /// Shown on the About screen and in the bundled documents.
    static let copyrightNotice = "Copyright 2026 Idlery Services LLC"

    static let supportURLString = "https://corecredit.idlery.com/support"
    static let privacyURLString = "https://corecredit.idlery.com/privacy"
    static let termsURLString   = "https://corecredit.idlery.com/terms"
    static let supportEmail     = "support@idlery.com"

    /// Version 1 ships to the United States App Store storefront only. Stated here because the
    /// legal documents say so and a claim in a legal document should have exactly one source.
    static let distributionTerritory = "United States"

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
