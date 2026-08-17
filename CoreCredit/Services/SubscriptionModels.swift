//
//  SubscriptionModels.swift
//  CoreCredit
//
//  The subscription layer's vocabulary. No StoreKit types cross this boundary, so the paywall,
//  the controller, and the tests all speak the same plain value types whether the real store,
//  the stub, or a fixture is behind them.
//

import Foundation

// MARK: - SubscriptionProduct

/// One purchasable subscription option, already reduced to what the paywall draws.
///
/// `displayPrice` is **always** the string StoreKit returned for the shopper's storefront. The app
/// never formats, guesses, or hard-codes a price: prices live in App Store Connect (and, for local
/// testing, in `StoreKit/CoreCredit.storekit`) and nowhere else. `price` carries the same figure as
/// a `Decimal` purely so the annual saving can be computed; it is never rendered directly, because
/// a raw decimal has no currency symbol and no locale.
struct SubscriptionProduct: Identifiable, Equatable, Sendable {

    /// The App Store product identifier.
    var id: String

    /// Localized product name from the store, e.g. "Pro Monthly".
    var displayName: String

    /// Localized product description from the store.
    var description: String

    /// Localized, storefront-correct price string. Always straight from StoreKit.
    var displayPrice: String

    /// Billing cadence, derived from the store's subscription period.
    var period: SubscriptionPeriod

    /// A short human sentence describing an introductory offer, when the store advertises one.
    var introductoryOffer: String?

    /// Whether the subscription is shared through Family Sharing.
    var isFamilyShareable: Bool

    /// The numeric price in the storefront's currency. Used only for the annual-saving
    /// calculation — never shown to anyone, because it carries no currency or locale.
    var price: Decimal

    init(
        id: String,
        displayName: String,
        description: String,
        displayPrice: String,
        period: SubscriptionPeriod,
        introductoryOffer: String? = nil,
        isFamilyShareable: Bool = false,
        price: Decimal = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.period = period
        self.introductoryOffer = introductoryOffer
        self.isFamilyShareable = isFamilyShareable
        self.price = price
    }
}

// MARK: - SubscriptionPeriod

/// Billing cadence, narrowed to the two the app actually sells.
///
/// Anything else the store reports maps to `.unknown` rather than being guessed at, so a
/// misconfigured product shows a neutral label instead of a wrong one.
enum SubscriptionPeriod: String, Equatable, Sendable {
    case monthly
    case annual
    case unknown

    var displayName: String {
        switch self {
        case .monthly: return "Monthly"
        case .annual: return "Annual"
        case .unknown: return "Subscription"
        }
    }

    /// Suffix appended after the store's price string, e.g. `displayPrice` + "/month".
    var perPeriodSuffix: String {
        switch self {
        case .monthly: return "/month"
        case .annual: return "/year"
        case .unknown: return ""
        }
    }

    /// Spoken form of `perPeriodSuffix`, so VoiceOver does not read a slash.
    var spokenPeriodSuffix: String {
        switch self {
        case .monthly: return "per month"
        case .annual: return "per year"
        case .unknown: return ""
        }
    }

    /// Display order on the paywall: monthly first, annual second, anything unrecognised last.
    var sortIndex: Int {
        switch self {
        case .monthly: return 0
        case .annual: return 1
        case .unknown: return 2
        }
    }
}

// MARK: - ProductLoadState

/// Where the product fetch stands.
///
/// `.failed` carries a shop-floor sentence, not a StoreKit error code — the paywall shows it
/// verbatim next to a Retry button.
enum ProductLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isFailed: Bool {
        switch self {
        case .failed: return true
        case .idle, .loading, .loaded: return false
        }
    }

    var isLoading: Bool {
        switch self {
        case .loading: return true
        case .idle, .loaded, .failed: return false
        }
    }

    var errorMessage: String? {
        switch self {
        case .failed(let message): return message
        case .idle, .loading, .loaded: return nil
        }
    }
}

// MARK: - PurchasePhase

/// Where a purchase attempt stands, from the UI's point of view.
///
/// `.pendingApproval` is deliberately *not* a failure: an Ask to Buy purchase sits here until a
/// family organiser approves it, and the shop keeps working in the meantime.
enum PurchasePhase: Equatable, Sendable {
    case idle
    case purchasing(productID: String)
    case pendingApproval
    case cancelled
    case failed(String)
    case succeeded

    /// The product currently being bought, when one is in flight.
    var purchasingProductID: String? {
        switch self {
        case .purchasing(let productID): return productID
        case .idle, .pendingApproval, .cancelled, .failed, .succeeded: return nil
        }
    }

    /// True while StoreKit still owns the outcome and the buttons must stay disabled.
    var isInProgress: Bool {
        switch self {
        case .purchasing: return true
        case .idle, .pendingApproval, .cancelled, .failed, .succeeded: return false
        }
    }

    var failureMessage: String? {
        switch self {
        case .failed(let message): return message
        case .idle, .purchasing, .pendingApproval, .cancelled, .succeeded: return nil
        }
    }
}

// MARK: - PurchaseResult

/// What a single purchase attempt resolved to.
enum PurchaseResult: Equatable, Sendable {
    case success
    case pending
    case cancelled
    case failed(String)
}

// MARK: - SubscriptionEngine

/// The store behind the paywall.
///
/// Two implementations ship: `StoreKitSubscriptionEngine` talks to the App Store, and
/// `StubSubscriptionEngine` answers from memory for previews and UI tests. Everything above this
/// protocol is store-agnostic, which is what lets the whole subscription flow be tested on a
/// simulator with no StoreKit configuration at all.
///
/// The protocol is main-actor isolated because both implementations are: StoreKit's
/// `Product.purchase()` is itself main-actor work, and the controller that drives this is a
/// `@MainActor` observable object feeding SwiftUI.
@MainActor
protocol SubscriptionEngine: AnyObject {

    /// Fetches the given product identifiers from the store.
    ///
    /// Throws when the store is unreachable. Returning an empty array is *not* an error at this
    /// level — it means the identifiers are unknown to the store, which the controller reports as
    /// a load failure with its own wording.
    func loadProducts(identifiers: [String]) async throws -> [SubscriptionProduct]

    /// Starts a purchase and waits for the store to resolve it.
    func purchase(productID: String) async throws -> PurchaseResult

    /// The entitlement the store can prove right now. Never throws: an unreadable store answers
    /// `.free`, and the caller decides whether that is authoritative enough to act on.
    func currentEntitlement() async -> Entitlement

    /// Asks the store to re-sync purchases for the signed-in Apple Account.
    func restorePurchases() async throws

    /// Emits a fresh entitlement whenever StoreKit reports a transaction update.
    func entitlementUpdates() -> AsyncStream<Entitlement>
}
