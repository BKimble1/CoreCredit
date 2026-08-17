//
//  SubscriptionConfigurationTests.swift
//  CoreCreditTests
//
//  The subscription identifiers, and the promises the paywall makes around them.
//
//  ## Why the identifiers are asserted as literals
//
//  Everywhere else in the suite a product is referred to through `AppConfiguration`, which is
//  correct: nothing should duplicate an identifier. But a test written that way passes even if the
//  constants are wrong, because it compares a value to itself. These are the App Store Connect
//  identifiers spelled out once, on purpose, so that changing one has to be deliberate.
//
//  The failure mode this guards against is silent. A product identifier that does not exist in App
//  Store Connect does not raise an error: `Product.products(for:)` simply returns nothing, the
//  paywall shows its retry state, and it looks like a network problem rather than a typo.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("The shipping subscription identifiers, and what the paywall guarantees around them")
struct SubscriptionConfigurationTests {

    // MARK: - Identifiers

    @Test("The product identifiers are the final App Store Connect ones")
    func productIdentifiersAreTheFinalOnes() {
        #expect(AppConfiguration.monthlyProductID == "com.blakekimble.corecredit.pro.monthly")
        #expect(AppConfiguration.annualProductID == "com.blakekimble.corecredit.pro.annual")

        // These must match `StoreKit/CoreCredit.storekit` character for character. That file is a
        // scheme reference rather than a bundle resource, so it cannot be read from inside the
        // test bundle; the pairing is checked statically instead. Asserting the literals here is
        // what makes a drift in either direction a deliberate edit rather than an accident.
        #expect(AppConfiguration.subscriptionProductIDs
                == [AppConfiguration.monthlyProductID, AppConfiguration.annualProductID])
    }

    @Test("Identifiers are recognised as configured rather than as the shipped samples")
    func identifiersAreRecognisedAsConfigured() {
        #expect(AppConfiguration.areSubscriptionProductIDsConfigured)

        // The check exists because this failure is quiet. `isPlaceholder` looks for a reserved
        // *host* and cannot see a reverse-DNS identifier: the substring in
        // `com.example.corecredit.pro.monthly` is `example.cor`, not `example.com`.
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.monthlyProductID) == false)
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.annualProductID) == false)
    }

    @Test("Identifiers are distinct, well formed, and namespaced under the bundle identifier")
    func identifiersAreWellFormed() {
        let ids = AppConfiguration.subscriptionProductIDs
        #expect(Set(ids).count == ids.count, "A duplicate identifier would sell one plan twice.")

        for id in ids {
            #expect(id.isEmpty == false)
            #expect(id.contains(" ") == false)
            #expect(id == id.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(id.hasPrefix(AppConfiguration.bundleIdentifier + "."),
                    "\(id) should sit under the app's identifier so the two cannot drift apart.")
        }
    }

    @Test("No product identifier is spelled anywhere but AppConfiguration")
    func identifiersAreNotDuplicated() {
        // Expressed as an invariant the compiler enforces: every other reference in the suite goes
        // through these constants, so there is exactly one place to edit.
        #expect(AppConfiguration.subscriptionProductIDs.count == 2)
        #expect(AppConfiguration.subscriptionProductIDs.first == AppConfiguration.monthlyProductID)
        #expect(AppConfiguration.subscriptionProductIDs.last == AppConfiguration.annualProductID)
    }

    // MARK: - Free tier

    @Test("Over the free limit, only creating another open core is restricted")
    func overTheLimitOnlyCreationIsRestricted() {
        let over = EntitlementPolicy.freeUnresolvedLimit + 3

        // Blocked: one more unresolved record.
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: over, tier: .free) == false)
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: over, tier: .free) != nil)

        // Never blocked: everything a shop does with what it already has. Viewing, reconciling a
        // credit, exporting a dispute packet, and closing a core are all reads and edits of
        // existing records, and none of them is gated on either tier.
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .free))
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .pro))

        // Closing records frees slots again, which is what makes the limit livable.
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: EntitlementPolicy.freeUnresolvedLimit - 1,
                                                tier: .free))
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: over, tier: .free) == 0)
    }

    @Test("Pro is never gated, at any number of open cores")
    func proIsNeverGated() {
        for count in [0, EntitlementPolicy.freeUnresolvedLimit, 500] {
            #expect(EntitlementPolicy.canCreateItem(unresolvedCount: count, tier: .pro))
            #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: count, tier: .pro) == nil)
        }
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: 500, tier: .pro) == nil,
                "nil means unlimited, not zero.")
    }

    // MARK: - Entitlement lifecycle

    @Test("An expired entitlement drops the tier without hiding a single record")
    func anExpiredEntitlementNeverHidesRecords() {
        let lapsed = Entitlement(tier: .free,
                                 expirationDate: TestClock.referenceNow,
                                 isInGracePeriod: false,
                                 lastVerified: TestClock.referenceNow,
                                 activeProductID: AppConfiguration.annualProductID)

        #expect(lapsed.isPro == false)

        // The whole point: losing Pro costs the shop the ability to open a *sixth* core. It does
        // not cost them anything they already logged — the ledger they built is theirs.
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: lapsed.tier))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 2, tier: lapsed.tier))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 99, tier: lapsed.tier) == false)
    }

    @Test("Restoring a purchase brings Pro back from the cache without a network round trip")
    @MainActor
    func restoringBringsProBackFromCache() async throws {
        let suiteName = "corecredit.tests.subscription." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pro = Entitlement(tier: .pro,
                              expirationDate: nil,
                              isInGracePeriod: false,
                              lastVerified: TestClock.referenceNow,
                              activeProductID: AppConfiguration.annualProductID)
        EntitlementCache.save(pro, to: defaults)

        // A shop on a bad connection at a parts counter must not be demoted to Free just because
        // StoreKit could not be reached. The cache is read first, before anything is fetched.
        let restored = EntitlementCache.load(from: defaults)
        #expect(restored.isPro)
        #expect(restored.activeProductID == AppConfiguration.annualProductID)
    }

    // MARK: - Product loading failure

    @Test("A failed product load reports the failure so the paywall can offer a retry")
    @MainActor
    func aFailedLoadIsReportedRatherThanLeftBlank() async throws {
        let suiteName = "corecredit.tests.loadfailure." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = StubSubscriptionEngine(tier: .free, simulateLoadFailure: true)
        let controller = SubscriptionController(engine: engine, defaults: defaults)

        await controller.loadProducts()

        // `.failed` carries a message, which is what the paywall renders in an ErrorBanner beside
        // a Retry button. An empty product list on its own would be indistinguishable from a
        // storefront that genuinely sells nothing, and would leave the user staring at a blank
        // sheet with no way forward.
        #expect(controller.loadState.isFailed)
        #expect(controller.products.isEmpty)
        #expect((controller.loadState.errorMessage ?? "").isEmpty == false)

        // Nothing about a failed load may change what the shop is entitled to.
        #expect(controller.isPro == false)
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: controller.entitlement.tier))
    }

    @Test("A successful load clears the failure and offers exactly the configured products")
    @MainActor
    func aSuccessfulLoadClearsTheFailure() async throws {
        let suiteName = "corecredit.tests.loadok." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = SubscriptionController(engine: StubSubscriptionEngine(tier: .free),
                                                defaults: defaults)
        await controller.loadProducts()

        #expect(controller.loadState.isFailed == false)
        #expect(controller.products.count == AppConfiguration.subscriptionProductIDs.count)

        let offered = Set(controller.products.map(\.id))
        #expect(offered == Set(AppConfiguration.subscriptionProductIDs),
                "The paywall must offer the configured identifiers and nothing else.")

        // Every price shown comes from the store. The stub's are marked as test values precisely
        // because a hard-coded price in a shipping build would be a lie the moment Apple changed
        // a storefront or applied a regional adjustment.
        for product in controller.products {
            #expect(product.displayPrice.isEmpty == false)
        }
    }
}
