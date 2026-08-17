//
//  EntitlementPolicyTests.swift
//  CoreCreditTests
//
//  Required scenarios 5 and 6:
//    5. Credited and Written off items do not count toward the five-item free limit.
//    6. A sixth unresolved item triggers the paywall, but the first five stay viewable, editable,
//       and exportable.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("The free tier limits new open cores and never gates existing records")
struct EntitlementPolicyTests {

    // MARK: - Policy arithmetic

    @Test("Free can create up to the limit and Pro is never blocked")
    func freeStopsAtTheLimitAndProNeverDoes() {
        #expect(EntitlementPolicy.freeUnresolvedLimit == 5)
        #expect(EntitlementPolicy.freeUnresolvedLimit == AppConfiguration.freeUnresolvedItemLimit)

        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 0, tier: .free))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 4, tier: .free))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 5, tier: .free) == false)
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 99, tier: .free) == false)

        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 5, tier: .pro))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 5_000, tier: .pro))
    }

    @Test("Remaining free slots count down and never go negative")
    func remainingFreeSlotsNeverGoNegative() {
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: 0, tier: .free) == 5)
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: 4, tier: .free) == 1)
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: 5, tier: .free) == 0)
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: 12, tier: .free) == 0)
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: 12, tier: .pro) == nil)
    }

    @Test("A blocking paywall trigger appears only at the limit")
    func blockingTriggerAppearsOnlyAtTheLimit() {
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: 4, tier: .free) == nil)
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: 5, tier: .free)
            == .freeLimitReached(limit: 5))
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: 5, tier: .pro) == nil)
    }

    @Test("Existing records are never gated, on either tier")
    func existingRecordsAreNeverGated() {
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .free))
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .pro))
    }

    @Test("Paywall copy names the reason and promises existing records stay available")
    func paywallCopyExplainsItself() {
        let limit = PaywallTrigger.freeLimitReached(limit: 5)
        #expect(limit.id == "freeLimitReached-5")
        #expect(limit.headline == "You've reached the free limit of 5 open cores")
        #expect(limit.subheadline.contains("view, edit, and export"))

        let voluntary = PaywallTrigger.voluntary
        #expect(voluntary.id == "voluntary")
        #expect(voluntary.headline == "Upgrade to Pro")
        #expect(voluntary.subheadline.isEmpty == false)
    }

    @Test("Tier and entitlement defaults")
    func tierAndEntitlementDefaults() {
        #expect(SubscriptionTier.free.displayName == "Free")
        #expect(SubscriptionTier.pro.displayName == "Pro")
        #expect(Entitlement.free.tier == .free)
        #expect(Entitlement.free.isPro == false)
        #expect(Entitlement(tier: .pro).isPro)
    }

    // MARK: - Scenario 5

    @MainActor
    @Test("Credited and written-off cores do not count toward the five-item free limit")
    func closedCoresDoNotCountTowardTheFreeLimit() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        var created: [CoreItem] = []
        for index in 1...5 {
            created.append(try makeItem(context: context,
                                        service: service,
                                        partName: "Core \(index)",
                                        amountCents: 1_000 + Int64(index),
                                        vendor: vendor))
        }

        let atTheLimit = try service.unresolvedCount()
        #expect(atTheLimit == 5)
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: atTheLimit, tier: .free) == false)

        let toCredit = try #require(created.first)
        let toWriteOff = try #require(created.last)

        try creditInFull(toCredit, service: service, reference: "CM-9001")
        try service.writeOff(toWriteOff, reason: "Vendor scrapped it")

        #expect(toCredit.status == .credited)
        #expect(toWriteOff.status == .writtenOff)

        let remainingUnresolved = try service.unresolvedCount()
        #expect(remainingUnresolved == 3)
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: remainingUnresolved, tier: .free))
        #expect(EntitlementPolicy.remainingFreeSlots(unresolvedCount: remainingUnresolved, tier: .free) == 2)
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: remainingUnresolved, tier: .free) == nil)

        // The closed cores are still in the ledger — they simply stopped consuming a slot.
        let stored = try service.allItems()
        #expect(stored.count == 5)
        #expect(RiskCalculator.unresolvedCount(stored) == 3)
    }

    // MARK: - Scenario 6

    @MainActor
    @Test("A sixth unresolved core trips the paywall but the first five stay editable and exportable")
    func aSixthCoreTripsThePaywallWithoutLockingTheFirstFive() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        var created: [CoreItem] = []
        for index in 1...5 {
            created.append(try makeItem(context: context,
                                        service: service,
                                        partName: "Core \(index)",
                                        amountCents: 8_650,
                                        vendor: vendor,
                                        invoiceReference: "INV-55\(index)"))
        }

        let unresolved = try service.unresolvedCount()
        #expect(unresolved == 5)

        // Creating the sixth is what is blocked — and only for the free tier.
        let trigger = try #require(EntitlementPolicy.blockingTrigger(unresolvedCount: unresolved, tier: .free))
        #expect(trigger == .freeLimitReached(limit: 5))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: unresolved, tier: .free) == false)
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: unresolved, tier: .pro))
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: unresolved, tier: .pro) == nil)

        // Viewing and editing the first five is never gated.
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .free))

        let first = try #require(created.first)
        var draft = service.draft(for: first)
        draft.partName = "Alternator, rebuilt"
        draft.notes = "Edited while over the free limit."
        try service.update(first, from: draft, vendor: first.vendor, bin: first.bin)

        #expect(first.partName == "Alternator, rebuilt")
        #expect(first.notes == "Edited while over the free limit.")
        #expect(first.timeline.contains(where: { $0.type == .edited }))

        // Exporting the first five is never gated either.
        let snapshots = created.map { SnapshotBuilder.snapshot($0) }
        let csv = CSVLedgerExporter.makeCSV(items: snapshots, currencyCode: "USD")
        let rows = csvRows(csv)

        #expect(rows.count == 6)                 // header plus the five existing cores
        #expect(csv.contains("Alternator, rebuilt"))
        #expect(csv.contains("INV-551"))
        #expect(csv.contains("INV-555"))
        #expect(csv.contains("86.50"))
    }

    // MARK: - Entitlement cache

    @Test("The entitlement cache round-trips through a private defaults suite")
    func entitlementCacheRoundTrips() throws {
        let suiteName = "com.example.corecredit.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            EntitlementCache.clear(defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(EntitlementCache.load(from: defaults) == Entitlement.free)

        let pro = Entitlement(
            tier: .pro,
            expirationDate: TestClock.date(year: 2027, month: 1, day: 1),
            isInGracePeriod: false,
            lastVerified: TestClock.referenceNow,
            activeProductID: AppConfiguration.annualProductID
        )
        EntitlementCache.save(pro, to: defaults)

        let loaded = EntitlementCache.load(from: defaults)
        #expect(loaded.tier == .pro)
        #expect(loaded.isPro)
        #expect(loaded.isInGracePeriod == false)
        #expect(loaded.activeProductID == AppConfiguration.annualProductID)
        #expect(loaded.expirationDate != nil)

        EntitlementCache.clear(defaults)
        #expect(EntitlementCache.load(from: defaults) == Entitlement.free)
    }

    @Test("An entitlement cached in one defaults suite never leaks into another")
    func cachesAreScopedToTheirSuite() throws {
        let firstName = "com.example.corecredit.tests." + UUID().uuidString
        let secondName = "com.example.corecredit.tests." + UUID().uuidString
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            EntitlementCache.clear(first)
            EntitlementCache.clear(second)
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }

        EntitlementCache.save(Entitlement(tier: .pro), to: first)

        #expect(EntitlementCache.load(from: first).isPro)
        #expect(EntitlementCache.load(from: second) == Entitlement.free)
    }

    // MARK: - Deterministic engine

    @MainActor
    @Test("The stub subscription engine answers from the tier it was given")
    func stubEngineAnswersFromItsTier() async {
        let engine = StubSubscriptionEngine(tier: .free)
        let free = await engine.currentEntitlement()
        #expect(free.tier == .free)
        #expect(free.isPro == false)

        engine.tier = .pro
        let pro = await engine.currentEntitlement()
        #expect(pro.isPro)
        #expect(pro.activeProductID == AppConfiguration.annualProductID)
    }

    @MainActor
    @Test("The stub subscription engine only sells the configured product identifiers")
    func stubEngineOnlySellsKnownProducts() async throws {
        let engine = StubSubscriptionEngine(tier: .free)

        let products = try await engine.loadProducts(identifiers: AppConfiguration.subscriptionProductIDs)
        #expect(products.count == 2)
        #expect(products.contains(where: { $0.id == AppConfiguration.monthlyProductID }))
        #expect(products.contains(where: { $0.id == AppConfiguration.annualProductID }))

        let unknown = try await engine.purchase(productID: "com.example.nope")
        #expect(unknown == .failed("That subscription option isn't available right now."))
        #expect(engine.tier == .free)

        let bought = try await engine.purchase(productID: AppConfiguration.annualProductID)
        #expect(bought == .success)
        #expect(engine.tier == .pro)
    }
}
