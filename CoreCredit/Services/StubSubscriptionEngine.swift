//
//  StubSubscriptionEngine.swift
//  CoreCredit
//
//  Deterministic stand-in for the App Store. Never touches StoreKit.
//

import Foundation

/// The failure the stub raises when it is asked to simulate an unreachable store.
private enum StubSubscriptionError: LocalizedError {
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return "Simulated store failure."
        }
    }
}

/// A `SubscriptionEngine` that answers from memory.
///
/// This is what runs under `-uiTesting`, in SwiftUI previews, and in unit tests. It never links a
/// purchase to a real account and never reaches the network, so a UI test can walk the whole
/// paywall — including the load-failure retry path — on a plain simulator with no StoreKit
/// configuration selected.
///
/// It is not registered anywhere in a shipping code path; `AppEnvironment` picks it only when
/// `LaunchOptions.isUITesting` is set.
@MainActor
final class StubSubscriptionEngine: SubscriptionEngine {

    /// The tier every answer is derived from. Setting it pushes a new entitlement through
    /// `entitlementUpdates()`, which is how a test can simulate a lapse or an external upgrade.
    var tier: SubscriptionTier {
        didSet {
            guard tier != oldValue else { return }
            continuation?.yield(entitlementForCurrentTier())
        }
    }

    /// When true, `loadProducts(identifiers:)` throws so the paywall's retry path can be exercised.
    private let simulateLoadFailure: Bool

    private var continuation: AsyncStream<Entitlement>.Continuation?

    init(tier: SubscriptionTier, simulateLoadFailure: Bool = false) {
        self.tier = tier
        self.simulateLoadFailure = simulateLoadFailure
    }

    deinit {
        continuation?.finish()
    }

    // MARK: - SubscriptionEngine

    func loadProducts(identifiers: [String]) async throws -> [SubscriptionProduct] {
        if simulateLoadFailure {
            throw StubSubscriptionError.loadFailed
        }
        return [StubSubscriptionEngine.monthlyFixture, StubSubscriptionEngine.annualFixture]
            .filter { identifiers.contains($0.id) }
    }

    func purchase(productID: String) async throws -> PurchaseResult {
        guard AppConfiguration.subscriptionProductIDs.contains(productID) else {
            return .failed("That subscription option isn't available right now.")
        }
        tier = .pro
        return .success
    }

    func currentEntitlement() async -> Entitlement {
        entitlementForCurrentTier()
    }

    func restorePurchases() async throws {
        continuation?.yield(entitlementForCurrentTier())
    }

    func entitlementUpdates() -> AsyncStream<Entitlement> {
        continuation?.finish()
        continuation = nil

        // The build closure runs synchronously, so the first value is already buffered by the
        // time the caller starts iterating. The stream then stays open indefinitely.
        return AsyncStream { newContinuation in
            self.continuation = newContinuation
            newContinuation.yield(self.entitlementForCurrentTier())
        }
    }

    // MARK: - Private

    private func entitlementForCurrentTier() -> Entitlement {
        switch tier {
        case .free:
            return Entitlement.free
        case .pro:
            return Entitlement(
                tier: .pro,
                expirationDate: Date().addingTimeInterval(StubSubscriptionEngine.thirtyDays),
                isInGracePeriod: false,
                lastVerified: Date(),
                activeProductID: AppConfiguration.annualProductID
            )
        }
    }

    private static let thirtyDays: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - Fixtures

    // TEST VALUES ONLY.
    //
    // These prices are obviously fake and exist so previews and UI tests have something stable to
    // draw. They can never reach a shipping build: `StoreKitSubscriptionEngine` is the only engine
    // wired up outside `-uiTesting`, and it copies `displayPrice` straight from StoreKit. The real
    // prices live in App Store Connect and in `StoreKit/CoreCredit.storekit`, never in Swift.

    private static let monthlyFixture = SubscriptionProduct(
        id: AppConfiguration.monthlyProductID,
        displayName: "Pro Monthly",
        description: "Track an unlimited number of open core items. Billed monthly.",
        displayPrice: "$1.00 (test)",
        period: .monthly,
        introductoryOffer: nil,
        isFamilyShareable: false,
        price: Decimal(1)
    )

    private static let annualFixture = SubscriptionProduct(
        id: AppConfiguration.annualProductID,
        displayName: "Pro Annual",
        description: "Track an unlimited number of open core items. Billed once a year.",
        displayPrice: "$9.00 (test)",
        period: .annual,
        introductoryOffer: "7 days free, then $9.00 (test)",
        isFamilyShareable: false,
        price: Decimal(9)
    )
}
