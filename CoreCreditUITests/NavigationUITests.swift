//
//  NavigationUITests.swift
//  CoreCreditUITests
//
//  The shell: four destinations, the onboarding gate in front of them, and the empty states a
//  brand-new shop actually sees.
//

import XCTest

final class NavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tabs

    func testEveryTabIsReachableAndShowsItsRoot() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "Dashboard") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard root")
            requireExists(app.navigationBars["Dashboard"], "the Dashboard navigation bar")
        }

        XCTContext.runActivity(named: "Cores") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            // Asserted through the ledger's own root identifier rather than through its navigation
            // bar, whose title is an English display string. `element(_:_:)` uses `firstMatch`,
            // which `CoreListView` needs: it is instantiated in five places, so a filtered list
            // pushed from the Dashboard carries the same identifier.
            requireExists(element(app, A11yID.Cores.root), "the Cores root")
            requireExists(control(app, A11yID.Cores.addButton), "the Cores add button")

            // `.searchable` injects a system search field that no `.accessibilityIdentifier` can
            // reach — an identifier written beside the modifier lands on the view it is attached
            // to, not on the field. `searchFields` is the supported way in.
            requireExists(searchField(app), "the ledger's search field")
        }

        XCTContext.runActivity(named: "Returns") { _ in
            tapTab(A11yID.Tab.returns, in: app)
            requireExists(element(app, A11yID.Returns.root), "the Returns root")
            requireExists(app.navigationBars["Returns"], "the Returns navigation bar")
        }

        XCTContext.runActivity(named: "Settings") { _ in
            tapTab(A11yID.Tab.settings, in: app)
            requireExists(element(app, A11yID.Settings.root), "the Settings root")
            requireExists(app.navigationBars["Settings"], "the Settings navigation bar")
            requireExists(control(app, A11yID.Settings.vendors), "the Vendors row")
        }

        XCTContext.runActivity(named: "And back to the Dashboard") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard root on return")
        }
    }

    // MARK: - Empty states

    func testEmptyLedgerShowsItsEmptyStatesAndNoFabricatedFigures() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "The Dashboard explains itself instead of showing zeroes") { _ in
            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard root")
            // Matched on the accessibility label rather than through the identifier subscript,
            // because a plain SwiftUI `Text` carries no identifier of its own.
            requireExists(element(app, labelled: "No core money at risk"),
                          "the Dashboard's empty-state heading")

            // The headline figure and the overdue tile belong to the populated layout. An empty
            // ledger must not render them at all — a zeroed-out header would be a figure the shop
            // never entered.
            requireAbsent(element(app, A11yID.Dashboard.moneyAtRisk),
                          "the money-at-risk figure on an empty ledger")
            requireAbsent(element(app, A11yID.Dashboard.overdueAmount),
                          "the overdue tile on an empty ledger")

            // The one thing an empty dashboard does offer.
            requireExists(control(app, A11yID.Dashboard.addCore), "the Add core button")
        }

        XCTContext.runActivity(named: "The ledger is empty, not filtered") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, labelled: "No cores yet"),
                          "the ledger's empty-state heading")
            requireAbsent(element(app, A11yID.Cores.list),
                          "the cores list, which is not built for an empty ledger")

            // No seeded or demonstration record has leaked into a fresh shop.
            requireAbsent(coreRow(app, titled: "Alternator"), "a fabricated core row")
        }

        XCTContext.runActivity(named: "Returns has nothing staged and nothing outstanding") { _ in
            tapTab(A11yID.Tab.returns, in: app)
            requireExists(element(app, A11yID.Returns.root), "the Returns root")
            requireExists(element(app, labelled: "Nothing ready to return"),
                          "the Returns staging empty state")
            requireExists(element(app, labelled: "Nothing outstanding"),
                          "the awaiting-credit empty state")
        }
    }

    // MARK: - Onboarding

    func testFirstLaunchRunsOnboardingAndLandsOnTheTabs() throws {
        // `-uiTestSeed empty` marks its profile onboarded, and so does `-uiTestSkipOnboarding`, so
        // the only launch that actually reaches the gate is `none`: seed nothing, and there is no
        // shop profile for `RootView` to call onboarded.
        let app = launchApp(seed: .noSeed, tier: .free, skipOnboarding: false)

        requireExists(element(app, A11yID.Onboarding.root), "the onboarding flow")
        requireAbsent(element(app, A11yID.Dashboard.root),
                      "the Dashboard, which onboarding must stand in front of")

        // The primary button is one control whose identifier switches: `onboarding.next` on the
        // first four steps, `onboarding.finish` on the last. The progress header — a single
        // accessibility element labelled "Step n of 5" — is what each tap is checked against, so
        // no step is skipped by a tap that landed early.
        requireExists(element(app, labelled: "Step 1 of 5"), "the first onboarding step")

        XCTContext.runActivity(named: "Three explanatory pages") { _ in
            for step in 2...4 {
                tapWhenHittable(control(app, A11yID.Onboarding.next),
                                "the onboarding Next button on step \(step - 1)",
                                in: app)
                requireExists(element(app, labelled: "Step \(step) of 5"),
                              "onboarding step \(step)")
            }
        }

        XCTContext.runActivity(named: "The shop names itself") { _ in
            clearAndType("Miller's Diesel Service",
                         into: textField(app, A11yID.Onboarding.shopName),
                         "the shop name field",
                         in: app)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Onboarding.next),
                            "the onboarding Continue button on the shop details step",
                            in: app)
            requireExists(element(app, labelled: "Step 5 of 5"), "the final onboarding step")
        }

        XCTContext.runActivity(named: "Finishing lands on the main tabs") { _ in
            // The vendor step is optional and left blank; `onboarding.finish` saves the profile
            // either way. `onboarding.skip` is the other way out of this step and is not used here.
            tapWhenHittable(control(app, A11yID.Onboarding.finish),
                            "the Finish setup button",
                            in: app)

            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard after setup")
            requireAbsent(element(app, A11yID.Onboarding.root), "the completed onboarding flow")

            // The tab bar is live, not just the first screen behind a dismissed sheet.
            tapTab(A11yID.Tab.settings, in: app)
            requireExists(element(app, A11yID.Settings.root), "the Settings root after setup")
        }
    }
}
