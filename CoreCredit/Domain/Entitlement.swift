//
//  Entitlement.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — no StoreKit here.
//

import Foundation

/// Which tier the shop is on.
enum SubscriptionTier: String, Codable, Sendable, Equatable {
    case free
    case pro

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        }
    }
}

/// The app's own view of what the user has paid for.
///
/// Deliberately a plain `Codable` value so it can be cached in `UserDefaults` and restored while
/// offline. StoreKit types never cross into this layer.
struct Entitlement: Codable, Sendable, Equatable {

    var tier: SubscriptionTier

    /// When the current subscription period ends, if known.
    var expirationDate: Date?

    /// True while StoreKit reports a billing-retry grace period; the user keeps Pro access.
    var isInGracePeriod: Bool

    /// When this entitlement was last confirmed against StoreKit.
    var lastVerified: Date?

    /// The product identifier currently providing access, if any.
    var activeProductID: String?

    /// The default for a brand-new install, and the safe fallback whenever verification fails.
    static let free = Entitlement(tier: .free)

    /// Pro access is decided by `tier` alone. The subscription controller is responsible for
    /// downgrading `tier` when a subscription lapses, so every call site agrees on one answer.
    var isPro: Bool { tier == .pro }

    init(tier: SubscriptionTier,
         expirationDate: Date? = nil,
         isInGracePeriod: Bool = false,
         lastVerified: Date? = nil,
         activeProductID: String? = nil) {
        self.tier = tier
        self.expirationDate = expirationDate
        self.isInGracePeriod = isInGracePeriod
        self.lastVerified = lastVerified
        self.activeProductID = activeProductID
    }
}

/// Why the paywall is being shown. Drives the copy at the top of the sheet.
enum PaywallTrigger: Equatable, Sendable, Identifiable {

    /// The free tier's open-core limit blocked a new entry.
    case freeLimitReached(limit: Int)

    /// The user opened the paywall themselves from Settings.
    case voluntary

    /// The user tapped AI Photo Assist on the free tier.
    ///
    /// This trigger does not represent anything being taken away. Photographs were not an input to
    /// this app before the assistant existed, and manual entry, Live scan, and Document scan all
    /// remain open on the free tier exactly as they were.
    case photoAssist

    var id: String {
        switch self {
        case .freeLimitReached(let limit):
            return "freeLimitReached-\(limit)"
        case .voluntary:
            return "voluntary"
        case .photoAssist:
            return "photoAssist"
        }
    }

    var headline: String {
        switch self {
        case .freeLimitReached(let limit):
            return "You've reached the free limit of \(limit) open cores"
        case .voluntary:
            return "Upgrade to Pro"
        case .photoAssist:
            return "AI Photo Assist is part of Pro"
        }
    }

    var subheadline: String {
        switch self {
        case .freeLimitReached:
            return "Upgrade for unlimited open cores. Everything you have already logged stays "
                + "available to view, edit, and export."
        case .voluntary:
            return "Unlimited open cores, dispute packets, CSV and backup exports, and return "
                + "reminders."
        case .photoAssist:
            return "Read a part, a label, and an invoice from photos on this device, and review "
                + "every suggestion before it reaches the form. Scanning and manual entry stay "
                + "free."
        }
    }
}

/// The single place that decides what the free tier can do.
///
/// The rule is intentionally narrow: free is limited only in **creating new** unresolved items.
/// Records that already exist are never locked away, so a lapsed subscription can never hold a
/// shop's ledger hostage.
enum EntitlementPolicy {

    /// How many unresolved items a free shop may hold at once.
    static var freeUnresolvedLimit: Int { AppConfiguration.freeUnresolvedItemLimit }

    /// Pro is always allowed. Free is allowed while it holds fewer than the limit.
    static func canCreateItem(unresolvedCount: Int, tier: SubscriptionTier) -> Bool {
        if tier == .pro { return true }
        return unresolvedCount < freeUnresolvedLimit
    }

    /// How many more open cores a free shop can add. `nil` means unlimited (Pro).
    static func remainingFreeSlots(unresolvedCount: Int, tier: SubscriptionTier) -> Int? {
        if tier == .pro { return nil }
        let remaining = freeUnresolvedLimit - unresolvedCount
        return remaining > 0 ? remaining : 0
    }

    /// The paywall trigger to present, or `nil` when creation is allowed.
    static func blockingTrigger(unresolvedCount: Int, tier: SubscriptionTier) -> PaywallTrigger? {
        if canCreateItem(unresolvedCount: unresolvedCount, tier: tier) { return nil }
        return .freeLimitReached(limit: freeUnresolvedLimit)
    }

    /// AI Photo Assist is Pro-only, on either the monthly or the annual product.
    ///
    /// This does not narrow the free tier. The rule everywhere else in this type is that free is
    /// limited only in *creating new* unresolved items; the assistant is new capability rather than
    /// an existing capability being withdrawn, so gating it leaves every free-tier workflow exactly
    /// where it was. A free shop can still type a core in by hand, scan a barcode live, and scan a
    /// document — and can still open, edit, and export everything it has already logged.
    ///
    /// Deliberately asks only about the tier. Which product paid for that tier, and whether the
    /// subscription is in its grace period, are `Entitlement`'s business; by the time a tier is
    /// `.pro` those questions have already been answered.
    static func canUsePhotoAssist(tier: SubscriptionTier) -> Bool {
        tier == .pro
    }

    /// The paywall trigger to present when a free shop taps AI Photo Assist, or `nil` for Pro.
    static func photoAssistTrigger(tier: SubscriptionTier) -> PaywallTrigger? {
        canUsePhotoAssist(tier: tier) ? nil : .photoAssist
    }

    /// Existing records are never gated — always `true`, for both tiers.
    ///
    /// Kept as an explicit function rather than an implicit assumption so the rule is testable and
    /// impossible to quietly regress.
    static func canViewEditExportExistingItems(tier: SubscriptionTier) -> Bool {
        switch tier {
        case .free, .pro:
            return true
        }
    }
}
