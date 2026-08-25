//
//  PaywallUITests.swift
//  CoreCreditUITests
//
//  The free-tier gate, and the promise that sits underneath it: adding a *new* core past the limit
//  is the only thing Pro buys. Everything already in the ledger stays viewable and editable on any
//  plan.
//
//  Every launch here uses the stub subscription engine (`-uiTesting`), so no test touches live
//  StoreKit, no StoreKit configuration file is required, and no purchase is ever started — the
//  product rows and the restore button are asserted on, never tapped.
//

import XCTest

final class PaywallUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - The gate

    func testSixthCoreOnFreeTierPresentsThePaywallWithBothPlansAndRestore() throws {
        // `fiveUnresolved` seeds the demonstration ledger, which holds exactly five *unresolved*
        // cores — the free limit — so the very next "add" is the one that is blocked.
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        tapTab(A11yID.Tab.cores, in: app)
        tapWhenHittable(control(app, A11yID.Cores.addButton), "the Cores add button", in: app)

        requireExists(element(app, A11yID.Paywall.root), "the paywall")
        requireExists(element(app, A11yID.Paywall.monthly), "the monthly subscription row")
        requireExists(element(app, A11yID.Paywall.annual), "the annual subscription row")
        // Restore sits below the fold on a phone. It is rendered in a plain `VStack`, not a lazy
        // one, so it exists in the hierarchy without being scrolled to — and it must not be
        // tapped, which would start a restore.
        requireExists(element(app, A11yID.Paywall.restore), "the restore purchases button")

        // The editor must not have opened behind the sheet.
        requireAbsent(textField(app, A11yID.Editor.partName),
                      "the core editor, which the paywall replaced")
    }

    // MARK: - Nothing already logged is locked away

    func testDismissingThePaywallLeavesTheExistingFiveViewableAndEditable() throws {
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "The paywall appears and is dismissed") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            tapWhenHittable(control(app, A11yID.Cores.addButton), "the Cores add button", in: app)

            requireExists(element(app, A11yID.Paywall.root), "the paywall")
            tapWhenHittable(control(app, A11yID.Paywall.close), "the paywall's close button", in: app)
            requireDismissed(element(app, A11yID.Paywall.root), "the dismissed paywall")
        }

        XCTContext.runActivity(named: "The ledger is still there and still opens") { _ in
            requireExists(element(app, A11yID.Cores.list), "the cores list")

            // "Alternator" is the first core in the seeded demonstration ledger.
            tapWhenHittable(coreRow(app, titled: "Alternator"),
                            "the alternator row in the seeded ledger",
                            in: app)
            requireExists(element(app, A11yID.Detail.root), "the core detail screen")
            requireExists(element(app, A11yID.Detail.status), "the core's status badge")
        }

        XCTContext.runActivity(named: "And still edits — free tier gates creation only") { _ in
            tapWhenHittable(button(app, labelContaining: "Edit core"),
                            "the Edit core action",
                            in: app)

            let partName = textField(app, A11yID.Editor.partName)
            requireExists(partName, "the editor's part name field, opened on an existing core")
            XCTAssertTrue(partName.isEnabled,
                          "An existing core's part name field was not editable on the free tier.")
            requireAbsent(element(app, A11yID.Paywall.root),
                          "the paywall, which must never gate an edit")

            // Leave the record exactly as it was found.
            tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel button", in: app)
            requireExists(element(app, A11yID.Detail.root), "the core detail screen after cancelling")
        }
    }

    // MARK: - Pro

    func testProTierOpensTheEditorInsteadOfThePaywall() throws {
        let app = launchApp(seed: .fiveUnresolved, tier: .pro, skipOnboarding: true)

        tapTab(A11yID.Tab.cores, in: app)
        tapWhenHittable(control(app, A11yID.Cores.addButton), "the Cores add button", in: app)

        requireExists(textField(app, A11yID.Editor.partName),
                      "the core editor, which Pro reaches directly")
        requireAbsent(element(app, A11yID.Paywall.root), "the paywall, which Pro must never see")

        tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel button", in: app)
    }

    // MARK: - Store unavailable

    func testStoreKitFailureShowsAnErrorWithRetryAndLeavesTheAppUsable() throws {
        let app = launchApp(seed: .fiveUnresolved,
                            tier: .free,
                            skipOnboarding: true,
                            storeKitFailure: true)

        XCTContext.runActivity(named: "The paywall opens into its store-unavailable state") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            tapWhenHittable(control(app, A11yID.Cores.addButton), "the Cores add button", in: app)

            requireExists(element(app, A11yID.Paywall.root), "the paywall")

            // `ErrorBanner` prefixes its spoken label with "Error. ", so the banner is matched on
            // that rather than on the failure sentence, which belongs to the controller.
            requireExists(
                app.staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Error."))
                    .firstMatch,
                "the paywall's store-failure banner"
            )
            requireExists(button(app, labelContaining: "Try again"),
                          "the retry affordance on the store-failure banner")

            // No product loaded, so there is nothing purchasable to show.
            requireAbsent(element(app, A11yID.Paywall.monthly),
                          "a monthly row, which cannot exist without a loaded product")

            // The close button is never blocked by a store problem.
            requireExists(element(app, A11yID.Paywall.close), "the paywall's close button")
        }

        XCTContext.runActivity(named: "The rest of the app stays reachable") { _ in
            tapWhenHittable(control(app, A11yID.Paywall.close), "the paywall's close button", in: app)
            requireDismissed(element(app, A11yID.Paywall.root), "the dismissed paywall")

            requireExists(element(app, A11yID.Cores.list), "the cores list")

            tapTab(A11yID.Tab.settings, in: app)
            requireExists(element(app, A11yID.Settings.root), "the Settings list")

            tapTab(A11yID.Tab.dashboard, in: app)
            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard")
            requireExists(element(app, A11yID.Dashboard.moneyAtRisk),
                          "the money-at-risk figure, still computed with the store unavailable")
        }
    }
}
