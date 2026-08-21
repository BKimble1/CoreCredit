//
//  SubscriptionController.swift
//  CoreCredit
//

import Foundation
import Observation

/// The app's single source of truth for what the shop has paid for.
///
/// Everything the UI needs — the entitlement, the products, whether the store answered, whether a
/// purchase is in flight — is on this one object, so no screen has to reason about StoreKit.
///
/// # Downgrade policy
///
/// The cached entitlement is written from exactly two places: `refreshEntitlement()` and the
/// `entitlementUpdates()` stream. Both are authoritative answers from the engine, which reads the
/// device's own transaction history and therefore works offline.
///
/// A failed **product load** or a failed **restore** never touches the entitlement. Those failures
/// mean "the store could not be reached", not "this shop is not subscribed", and treating them as
/// a downgrade is how a paying customer standing in a dead spot loses access to their own ledger.
@MainActor
@Observable
final class SubscriptionController {

    // MARK: - Observable state

    /// What the shop is entitled to right now. Seeded from the cache so it is correct at launch.
    private(set) var entitlement: Entitlement

    /// The subscription options to draw, monthly first. Retained across a failed reload.
    private(set) var products: [SubscriptionProduct] = []

    /// Whether the store answered.
    private(set) var loadState: ProductLoadState = .idle

    /// Where the current purchase attempt stands.
    private(set) var purchasePhase: PurchasePhase = .idle

    /// True while a restore is running. Kept separate from `purchasePhase` because a restore is
    /// not a purchase and must not be reported as one.
    private(set) var isRestoring = false

    // MARK: - Dependencies

    // `let` properties are not observed by `@Observable`, so they need no annotation. The two
    // mutable ones below are marked ignored because nothing in the UI should redraw when a
    // background task handle changes.
    private let engine: any SubscriptionEngine
    private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(engine: any SubscriptionEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        self.entitlement = EntitlementCache.load(from: defaults)
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Derived

    var isPro: Bool { entitlement.isPro }

    /// The monthly option, matched by identifier first and by cadence second so a store that
    /// reports an unexpected period still lands in the right row.
    var monthlyProduct: SubscriptionProduct? {
        if let exact = products.first(where: { $0.id == AppConfiguration.monthlyProductID }) {
            return exact
        }
        return products.first(where: { $0.period == .monthly })
    }

    var annualProduct: SubscriptionProduct? {
        if let exact = products.first(where: { $0.id == AppConfiguration.annualProductID }) {
            return exact
        }
        return products.first(where: { $0.period == .annual })
    }

    /// "Save 33%" — how much less a year of the annual plan costs than twelve monthly renewals.
    ///
    /// Computed entirely from the two StoreKit prices, so it is correct in every storefront and
    /// currency and cannot drift from what the store actually charges. Returns `nil` whenever
    /// either product is missing, the monthly price is zero or negative, or the annual plan is not
    /// in fact cheaper — a paywall must never invent a saving.
    var annualSavingsText: String? {
        guard let monthly = monthlyProduct, let annual = annualProduct else { return nil }

        let twelveMonths = monthly.price * 12
        guard twelveMonths > 0 else { return nil }

        let saved = twelveMonths - annual.price
        guard saved > 0 else { return nil }

        let fraction = NSDecimalNumber(decimal: saved / twelveMonths).doubleValue
        guard fraction.isFinite else { return nil }

        let percent = Int((fraction * 100).rounded())
        guard percent > 0 else { return nil }

        return "Save " + String(percent) + "%"
    }

    /// True while the store owns the outcome of something the user started.
    var isBusy: Bool { purchasePhase.isInProgress || isRestoring }

    // MARK: - Lifecycle

    /// Brings the controller up: cached entitlement first, then the store.
    ///
    /// Safe to call more than once; the transaction observer is only started once.
    func start() async {
        entitlement = EntitlementCache.load(from: defaults)

        if hasStarted == false {
            hasStarted = true
            beginObservingUpdates()
        }

        await loadProducts()
        await refreshEntitlement()
    }

    /// Stops observing transaction updates. Called when the environment is torn down.
    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        hasStarted = false
    }

    // MARK: - Products

    func loadProducts() async {
        loadState = .loading
        do {
            let loaded = try await engine.loadProducts(
                identifiers: AppConfiguration.subscriptionProductIDs
            )

            if loaded.isEmpty {
                // The store was reachable but knows nothing about these identifiers — almost
                // always a configuration mismatch rather than a device problem.
                loadState = .failed(SubscriptionController.noOptionsMessage)
            } else {
                products = loaded.sorted { $0.period.sortIndex < $1.period.sortIndex }
                loadState = .loaded
            }
        } catch {
            // Deliberately keeps any previously loaded products: they are still purchasable, and
            // the entitlement is untouched.
            loadState = .failed(SubscriptionController.loadFailureMessage)
        }
    }

    func retryLoadProducts() async {
        await loadProducts()
    }

    // MARK: - Purchasing

    func purchase(_ product: SubscriptionProduct) async {
        guard isBusy == false else { return }

        purchasePhase = .purchasing(productID: product.id)

        do {
            let result = try await engine.purchase(productID: product.id)
            switch result {
            case .success:
                await refreshEntitlement()
                purchasePhase = .succeeded
            case .pending:
                purchasePhase = .pendingApproval
            case .cancelled:
                purchasePhase = .cancelled
            case .failed(let message):
                purchasePhase = .failed(message)
            }
        } catch {
            purchasePhase = .failed(SubscriptionController.purchaseFailureMessage)
        }
    }

    /// Re-syncs purchases for the signed-in Apple Account.
    ///
    /// A failure here is reported and then forgotten. It never downgrades the entitlement.
    func restorePurchases() async {
        guard isBusy == false else { return }

        isRestoring = true
        purchasePhase = .idle

        do {
            try await engine.restorePurchases()
            await refreshEntitlement()
            isRestoring = false
            if entitlement.isPro {
                purchasePhase = .succeeded
            } else {
                purchasePhase = .failed(SubscriptionController.nothingToRestoreMessage)
            }
        } catch {
            // `AppStore.sync()` throwing does not mean there is nothing to restore. It is a request
            // that the App Store refresh its record, and it fails for reasons that have nothing to
            // do with this Apple Account's subscriptions — most reliably in the sandbox, where it
            // asks for a password and gives up. `Transaction.currentEntitlements` is the source of
            // truth and reads fine without it.
            //
            // So the entitlement decides, not the error: refresh, and if this account turns out to
            // be Pro, the restore did what the person asked for and saying otherwise in red is a
            // lie. Only an account that really has nothing gets the failure.
            await refreshEntitlement()
            isRestoring = false
            purchasePhase = entitlement.isPro
                ? .succeeded
                : .failed(SubscriptionController.restoreFailureMessage)
        }
    }

    // MARK: - Entitlement

    /// Asks the engine for the authoritative entitlement and caches the answer.
    func refreshEntitlement() async {
        let fresh = await engine.currentEntitlement()
        apply(fresh)
    }

    func clearPurchasePhase() {
        purchasePhase = .idle
    }

    // MARK: - Private

    private func beginObservingUpdates() {
        guard updatesTask == nil else { return }

        let stream = engine.entitlementUpdates()
        updatesTask = Task { [weak self] in
            for await updated in stream {
                guard let self = self else { return }
                self.apply(updated)
            }
        }
    }

    /// The only place the entitlement changes. Cache and memory stay in step by construction.
    private func apply(_ fresh: Entitlement) {
        entitlement = fresh
        EntitlementCache.save(fresh, to: defaults)
    }

    // MARK: - Copy

    private static let loadFailureMessage =
        "Couldn't reach the App Store. Check the connection and try again."

    private static let noOptionsMessage =
        "Subscription options aren't available right now. Try again in a moment."

    private static let purchaseFailureMessage =
        "The purchase couldn't be completed. Nothing was charged."

    private static let restoreFailureMessage =
        "Couldn't reach the App Store to restore purchases. Try again in a moment."

    private static let nothingToRestoreMessage =
        "No subscription was found for this Apple Account."
}
