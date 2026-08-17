//
//  StoreKitSubscriptionEngine.swift
//  CoreCredit
//
//  The real store. Deliberately does NOT import SwiftUI: SwiftUI also declares a type named
//  `Transaction`, and every `Transaction` in this file must be StoreKit's.
//

import Foundation
import StoreKit

/// Failures this engine reports in its own words.
///
/// File-scoped on purpose — nothing outside this file needs to match on these; the layers above
/// only ever see the sentence.
private enum StoreKitEngineError: LocalizedError {

    /// StoreKit handed back a transaction whose signature it could not vouch for.
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "The App Store couldn't verify that purchase."
        }
    }
}

/// The App Store implementation of `SubscriptionEngine`.
///
/// # What this does and does not do
///
/// Verification is **on-device StoreKit 2 verification only**. `VerificationResult` is checked with
/// `checkVerified(_:)` and nothing else: there is no server, no receipt upload, and no shared
/// secret. That is the whole security model, and it is the right one for a local-first app with no
/// backend — a shop's ledger never leaves the device.
///
/// Prices are never computed here. `displayPrice` is copied straight from `Product.displayPrice`,
/// which is already localized and storefront-correct.
@MainActor
final class StoreKitSubscriptionEngine: SubscriptionEngine {

    /// The `Product` values from the last successful load, keyed by identifier.
    ///
    /// `Product.purchase()` can only be called on a `Product`, so a purchase requires a prior
    /// successful load. Grace-period detection also reads from here.
    private var cachedProducts: [String: Product] = [:]

    /// The long-lived task draining `Transaction.updates`.
    private var updatesTask: Task<Void, Never>?

    /// The continuation feeding `entitlementUpdates()`, kept so a restore can push a fresh value.
    private var updatesContinuation: AsyncStream<Entitlement>.Continuation?

    init() { }

    deinit {
        updatesTask?.cancel()
        updatesContinuation?.finish()
    }

    // MARK: - Loading

    func loadProducts(identifiers: [String]) async throws -> [SubscriptionProduct] {
        let storeProducts = try await Product.products(for: identifiers)

        // A retry that comes back empty must not throw away a working cache — the previously
        // loaded products are still purchasable.
        if storeProducts.isEmpty == false {
            var cache: [String: Product] = [:]
            for product in storeProducts {
                cache[product.id] = product
            }
            cachedProducts = cache
        }

        return storeProducts.map { StoreKitSubscriptionEngine.makeSubscriptionProduct(from: $0) }
    }

    // MARK: - Purchasing

    func purchase(productID: String) async throws -> PurchaseResult {
        guard let product = cachedProducts[productID] else {
            return .failed("That subscription option isn't available right now. Try again in a moment.")
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                return .success

            case .pending:
                return .pending

            case .userCancelled:
                return .cancelled

            default:
                // StoreKit added an outcome this build does not know about. Treat it as
                // unfinished rather than as a success.
                return .failed("The App Store didn't finish that purchase. Nothing was charged.")
            }
        } catch {
            return .failed(StoreKitSubscriptionEngine.readableMessage(for: error))
        }
    }

    // MARK: - Entitlement

    func currentEntitlement() async -> Entitlement {
        let ourProductIDs = Set(AppConfiguration.subscriptionProductIDs)
        var active: StoreKit.Transaction?

        for await result in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard ourProductIDs.contains(transaction.productID) else { continue }
            // A refunded or family-removed purchase is revoked and grants nothing.
            guard transaction.revocationDate == nil else { continue }

            if let current = active {
                if StoreKitSubscriptionEngine.effectiveExpiry(of: transaction)
                    > StoreKitSubscriptionEngine.effectiveExpiry(of: current) {
                    active = transaction
                }
            } else {
                active = transaction
            }
        }

        guard let transaction = active else { return Entitlement.free }

        let inGracePeriod = await isInGracePeriod(productID: transaction.productID)

        return Entitlement(
            tier: .pro,
            expirationDate: transaction.expirationDate,
            isInGracePeriod: inGracePeriod,
            lastVerified: Date(),
            activeProductID: transaction.productID
        )
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        let refreshed = await currentEntitlement()
        updatesContinuation?.yield(refreshed)
    }

    // MARK: - Updates

    func entitlementUpdates() -> AsyncStream<Entitlement> {
        // Only one drain task at a time. Calling this again replaces the previous stream.
        updatesTask?.cancel()
        updatesTask = nil
        updatesContinuation?.finish()
        updatesContinuation = nil

        // `AsyncStream`'s build closure runs synchronously during initialisation, so the
        // continuation and the task are both in place before the stream is returned.
        return AsyncStream { continuation in
            self.updatesContinuation = continuation

            let task = Task { [weak self] in
                for await update in StoreKit.Transaction.updates {
                    guard let self = self else { break }

                    // Finishing tells StoreKit the app has delivered the content. Unverified
                    // updates are deliberately left unfinished so they are redelivered.
                    if let transaction = try? self.checkVerified(update) {
                        await transaction.finish()
                    }

                    let refreshed = await self.currentEntitlement()
                    continuation.yield(refreshed)
                }
                continuation.finish()
            }

            self.updatesTask = task

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops observing transaction updates. Safe to call more than once.
    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        updatesContinuation?.finish()
        updatesContinuation = nil
    }

    // MARK: - Verification

    /// Unwraps a StoreKit verification result, throwing when the App Store could not vouch for it.
    ///
    /// This is the entire trust boundary. Anything that fails here is treated as if it did not
    /// exist, so a tampered payload can never grant Pro.
    private func checkVerified<T: Sendable>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let signedPayload):
            return signedPayload
        default:
            // `.unverified`, and anything StoreKit adds later that is not a clean verification.
            throw StoreKitEngineError.verificationFailed
        }
    }

    // MARK: - Grace period

    /// Whether the store says this product is in a billing grace or retry period.
    ///
    /// Read from the subscription group's status via the cached `Product`, rather than from a
    /// group-wide lookup, so this depends only on API the app already relies on for loading.
    /// When products have not been loaded yet the answer is `false` — the shop still has Pro
    /// (the transaction is in `currentEntitlements`), it just is not flagged as at-risk until the
    /// next successful product load.
    private func isInGracePeriod(productID: String) async -> Bool {
        guard let product = cachedProducts[productID],
              let subscription = product.subscription else { return false }
        guard let statuses = try? await subscription.status else { return false }

        for status in statuses {
            guard let transaction = try? checkVerified(status.transaction) else { continue }
            guard transaction.productID == productID else { continue }
            if status.state == .inGracePeriod || status.state == .inBillingRetryPeriod {
                return true
            }
        }
        return false
    }

    // MARK: - Mapping

    private static func effectiveExpiry(of transaction: StoreKit.Transaction) -> Date {
        transaction.expirationDate ?? Date.distantFuture
    }

    private static func makeSubscriptionProduct(from product: Product) -> SubscriptionProduct {
        SubscriptionProduct(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            period: periodForProduct(product),
            introductoryOffer: introductoryOfferText(for: product),
            isFamilyShareable: product.isFamilyShareable,
            price: product.price
        )
    }

    private static func periodForProduct(_ product: Product) -> SubscriptionPeriod {
        guard let subscriptionPeriod = product.subscription?.subscriptionPeriod else {
            return .unknown
        }
        switch subscriptionPeriod.unit {
        case .month where subscriptionPeriod.value == 1:
            return .monthly
        case .year where subscriptionPeriod.value == 1:
            return .annual
        default:
            return .unknown
        }
    }

    /// A short sentence describing the store's introductory offer, or `nil` when there is none.
    ///
    /// Every figure in the returned string comes from StoreKit.
    private static func introductoryOfferText(for product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer else { return nil }
        let span = durationText(offer.period, count: offer.periodCount)

        switch offer.paymentMode {
        case .freeTrial:
            return span + " free, then " + product.displayPrice
        case .payUpFront:
            return offer.displayPrice + " for the first " + span
        case .payAsYouGo:
            return offer.displayPrice + " each period for the first " + span
        default:
            return "Introductory offer for the first " + span
        }
    }

    /// "7 days", "1 month", "3 months" — the offer's period multiplied by how many of them run.
    private static func durationText(_ period: Product.SubscriptionPeriod, count: Int) -> String {
        let total = period.value * max(count, 1)
        let unitName: String
        switch period.unit {
        case .day: unitName = "day"
        case .week: unitName = "week"
        case .month: unitName = "month"
        case .year: unitName = "year"
        default: unitName = "period"
        }
        let plural = total == 1 ? "" : "s"
        return String(total) + " " + unitName + plural
    }

    /// Turns a thrown error into something a service writer can act on.
    private static func readableMessage(for error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "The purchase couldn't be completed. Check your connection and try again."
        }
        return "The purchase couldn't be completed. " + detail
    }
}
