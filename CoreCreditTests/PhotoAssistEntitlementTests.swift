//
//  PhotoAssistEntitlementTests.swift
//  CoreCreditTests
//
//  AI Photo Assist is Pro. These tests exist mostly to prove what that did *not* change.
//
//  Gating a new feature is easy to get wrong in one specific way: the gate quietly widens, and a
//  shop that could log a core yesterday cannot today. The rule in `EntitlementPolicy` has always
//  been that free is limited only in *creating new* unresolved cores, and that existing records are
//  never locked away. Adding a paid feature must leave both of those exactly where they were, so
//  most of what follows asserts the absence of a change.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("AI Photo Assist is Pro, and nothing else moved")
struct PhotoAssistEntitlementTests {

    @Test("Free cannot use the assistant; Pro can")
    func theAssistantIsPro() throws {
        #expect(EntitlementPolicy.canUsePhotoAssist(tier: .free) == false)
        #expect(EntitlementPolicy.canUsePhotoAssist(tier: .pro))
    }

    @Test("Tapping it on Free asks for an upgrade; on Pro it asks for nothing")
    func theTriggerAppearsOnlyForFree() throws {
        #expect(EntitlementPolicy.photoAssistTrigger(tier: .free) == .photoAssist)
        #expect(EntitlementPolicy.photoAssistTrigger(tier: .pro) == nil)
    }

    @Test("The paywall says what it is for, and does not claim anything was taken away")
    func theTriggerCopyIsHonest() throws {
        let trigger = PaywallTrigger.photoAssist

        #expect(trigger.id == "photoAssist")
        #expect(trigger.headline.isEmpty == false)
        #expect(trigger.subheadline.isEmpty == false)

        // The one thing this copy must do is reassure somebody that the ways they already enter a
        // core are still there. A paywall that reads as a removal is how an app loses a shop.
        let promise = trigger.subheadline.localizedLowercase
        #expect(promise.contains("free"),
                """
                The subheadline has to say plainly that scanning and manual entry stay free. \
                Without that sentence this reads as capability being withdrawn, which it is not.
                """)
    }

    // MARK: - What did not change

    @Test("The free limit on open cores is exactly what it was")
    func theFreeLimitIsUnchanged() throws {
        let limit = EntitlementPolicy.freeUnresolvedLimit

        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: limit - 1, tier: .free))
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: limit, tier: .free) == false)
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: limit + 99, tier: .pro))

        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: limit, tier: .free)
                == .freeLimitReached(limit: limit),
                "A blocked creation still shows the limit paywall, not the assistant's.")
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: limit, tier: .pro) == nil)
    }

    @Test("Existing records are still never gated, on either tier")
    func existingRecordsAreStillOpen() throws {
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .free))
        #expect(EntitlementPolicy.canViewEditExportExistingItems(tier: .pro))
    }

    @Test("The assistant's gate is not a creation gate")
    func theAssistantGateDoesNotBlockCreation() throws {
        // A free shop with room to spare can still create a core. Being unable to use photographs
        // has nothing to do with being able to log one by hand, and the two rules must not have
        // become entangled.
        #expect(EntitlementPolicy.canUsePhotoAssist(tier: .free) == false)
        #expect(EntitlementPolicy.canCreateItem(unresolvedCount: 0, tier: .free))
        #expect(EntitlementPolicy.blockingTrigger(unresolvedCount: 0, tier: .free) == nil)
    }

    @Test("There is no separate product: the gate asks about the tier, not about what was bought")
    func thereIsNoSecondProduct() throws {
        // Monthly and annual both resolve to `.pro`, and the assistant asks only about that. If a
        // third product identifier ever appears here, this feature has grown its own paywall.
        let monthly = Entitlement(tier: .pro,
                                  isInGracePeriod: false,
                                  activeProductID: AppConfiguration.monthlyProductID)
        let annual = Entitlement(tier: .pro,
                                 isInGracePeriod: false,
                                 activeProductID: AppConfiguration.annualProductID)

        #expect(EntitlementPolicy.canUsePhotoAssist(tier: monthly.tier))
        #expect(EntitlementPolicy.canUsePhotoAssist(tier: annual.tier))
    }
}
