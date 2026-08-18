//
//  DeepLinkUITests.swift
//  CoreCreditUITests
//
//  The links something *outside* the app can send it: the Quick Scan widget, a Shortcut, the Action
//  Button, and a bin tag's printed QR code.
//
//  ## Why every link arrives at launch
//
//  `-uiTestDeepLink <url>` hands the URL to `AppEnvironment.init`, which passes it to
//  `DeepLinkRouter` before a single view exists. That is not a shortcut around the real path — it
//  *is* the real path, and the awkward one: on a cold start the URL always arrives before there is a
//  tab bar to switch or a sheet to present, which is exactly why `DeepLinkRouter` holds the link and
//  `MainTabView` consumes it on appear. XCUITest cannot ask the springboard to open a custom scheme
//  without driving Safari, so this is also the only way in.
//
//  ## No camera, no StoreKit, no notifications
//
//  Every launch here passes `-uiTesting`, so the store is in memory, the subscription engine is the
//  stub, the notification scheduler is the recorder, and animations are off. The scan sheet these
//  tests open lands on `ScannerAvailability.simulator` — there is no capture device in the
//  simulator, so manual entry is the whole screen and no permission prompt is reachable.
//

import XCTest

final class DeepLinkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Links under test

    private static let scanLink = "corecredit://scan"

    /// A syntactically valid UUID that no fixture creates. `SeedScenario.walkthrough` builds its
    /// records with fresh `UUID()`s, so this can never collide with a seeded core.
    private static let unknownItemID = "11111111-2222-3333-4444-555555555555"

    private static var unknownItemLink: String {
        "corecredit://item/" + DeepLinkUITests.unknownItemID
    }

    private static let malformedLink = "corecredit://nonsense"

    // MARK: - corecredit://scan

    /// The widget's whole purpose: raise the phone at a parts counter and be looking at a scanner.
    func testScanLinkOpensTheScannerOverANewDraft() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: DeepLinkUITests.scanLink)

        XCTContext.runActivity(named: "The shell answers a link that arrived before it existed") { _ in
            // `MainTabView.consumePendingDeepLink()` answers `.scan` with
            // `DashboardModel.beginQuickScan()`, which `ShellSheetHost` presents as
            // `CoreEditorView(mode: .create, initialRoute: .scan)` — one intake form with the
            // capture sheet already in front of it.
            requireExists(element(app, A11yID.Scan.root),
                          "the scan sheet opened by " + DeepLinkUITests.scanLink)
        }

        XCTContext.runActivity(named: "The capture flow is usable without a camera") { _ in
            // In the simulator `BarcodeScannerAvailabilityChecker.current()` returns `.simulator`,
            // and manual entry is present in every one of the sheet's six states, so nothing here
            // depends on camera permission.
            requireExists(textField(app, A11yID.Scan.manualEntry),
                          "the scanner's manual-entry field")
            requireExists(control(app, A11yID.Scan.cancel),
                          "the scanner's Cancel button")

            // The quick-scan route is the create editor with the scanner in front of it, so the
            // paywall is not part of this journey — `MainTabView` deliberately skips the free-limit
            // pre-check here and leaves the limit to `CoreEditorModel.save`.
            requireAbsent(element(app, A11yID.Paywall.root),
                          "the paywall, which a raised phone at a parts counter must never meet")
        }
    }

    /// The guarantee that makes the widget safe to tap by accident: a quick scan that is cancelled
    /// leaves the owner on the form they were always going to fill in, and writes nothing.
    func testCancellingQuickScanLeavesAUsableDraftAndSavesNothing() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: DeepLinkUITests.scanLink)

        requireExists(element(app, A11yID.Scan.root), "the scan sheet opened by the quick-scan link")

        XCTContext.runActivity(named: "Cancelling the camera lands on the draft, not on nothing") { _ in
            tapWhenHittable(control(app, A11yID.Scan.cancel),
                            "the scanner's Cancel button",
                            in: app)
            requireAbsent(element(app, A11yID.Scan.root), "the dismissed scan sheet")

            // `CoreEditorView` carries no root identifier of its own, so the form is asserted
            // through the controls it always builds: the first field and the save action.
            requireExists(textField(app, A11yID.Editor.partName),
                          "the intake form the scanner was presented over")
            requireExists(control(app, A11yID.Editor.save),
                          "the editor's Save button on the surviving draft")
        }

        XCTContext.runActivity(named: "Closing the draft writes nothing at all") { _ in
            tapWhenHittable(control(app, A11yID.Editor.cancel),
                            "the editor's Cancel button",
                            in: app)
            requireAbsent(textField(app, A11yID.Editor.partName), "the dismissed editor")

            // The link selected the Cores tab, so the ledger is what the dismissed sheet reveals.
            requireExists(element(app, labelled: "No cores yet"),
                          "the ledger's empty state after a cancelled quick scan")
            requireAbsent(element(app, A11yID.Cores.list),
                          "the cores list, which is not built for an empty ledger")
        }

        XCTContext.runActivity(named: "And the dashboard still has nothing to count") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            requireExists(element(app, labelled: "No core money at risk"),
                          "the Dashboard's empty state after a cancelled quick scan")
            // A zeroed-out header would be a figure the shop never entered; an empty ledger must
            // not render the headline at all.
            requireAbsent(element(app, A11yID.Dashboard.moneyAtRisk),
                          "the money-at-risk figure, which a cancelled scan must never create")
        }
    }

    // MARK: - corecredit://item/<uuid>

    /// A bin tag naming a core this ledger does not hold leaves the owner where they were.
    ///
    /// **The positive item-open path is covered by a unit test — `CoreCreditTests/DeepLinkTests.swift`
    /// — and deliberately not here.** A seeded core's `UUID` is created inside the app at launch by
    /// `ModelContainerFactory`, and nothing publishes it: it appears in `A11y.Cores.row(_:)` only as
    /// part of an identifier this process cannot predict, so a UI test has no way to name the record
    /// it wants opened. What a UI test *can* pin down deterministically is the other half of the
    /// contract, which is the half that involves a real shop's shelf: a tag can outlive the core it
    /// was printed for, and a link to a record that is gone must do nothing at all rather than dump
    /// the owner on an empty screen they did not ask for.
    func testUnknownItemLinkOpensTheAppNormally() throws {
        let app = launchApp(seed: .walkthrough,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: DeepLinkUITests.unknownItemLink)

        XCTContext.runActivity(named: "The app opens on the tabs, not on a dead end") { _ in
            requireExists(element(app, A11yID.Dashboard.root),
                          "the Dashboard after a well-formed link to a core that is not there")
            requireAbsent(element(app, A11yID.Detail.root),
                          "a core detail screen, which no record in this ledger matches")
            requireAbsent(element(app, A11yID.Root.deepLinkTarget),
                          "the shell's deep-link sheet, which an item link never opens")
        }

        XCTContext.runActivity(named: "The shell is live, not merely painted") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, A11yID.Cores.root), "the Cores root")
            // The seeded walkthrough ledger is intact — the unresolvable link changed nothing.
            requireExists(coreRow(app, titled: "Alternator"),
                          "the seeded alternator row in the walkthrough ledger")

            tapTab(A11yID.Tab.settings, in: app)
            requireExists(element(app, A11yID.Settings.root), "the Settings root")
        }
    }

    // MARK: - Junk

    /// A scanner hands over vendor barcodes and shipping labels all day. Declining is the ordinary
    /// answer, and it must cost the owner nothing.
    func testMalformedLinkIsIgnoredAndTheAppLandsOnTheTabs() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: DeepLinkUITests.malformedLink)

        XCTContext.runActivity(named: "Nothing was navigated and nothing was presented") { _ in
            requireExists(element(app, A11yID.Dashboard.root),
                          "the Dashboard after a link this build does not understand")
            requireAbsent(element(app, A11yID.Root.deepLinkTarget),
                          "the shell's deep-link sheet, which an unparsed link must never open")
            requireAbsent(element(app, A11yID.Scan.root),
                          "the scan sheet, which only " + DeepLinkUITests.scanLink + " opens")
        }

        XCTContext.runActivity(named: "Every destination is still reachable") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, A11yID.Cores.root), "the Cores root")

            tapTab(A11yID.Tab.returns, in: app)
            requireExists(element(app, A11yID.Returns.root), "the Returns root")

            tapTab(A11yID.Tab.settings, in: app)
            requireExists(element(app, A11yID.Settings.root), "the Settings root")

            tapTab(A11yID.Tab.dashboard, in: app)
            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard root on return")
        }
    }
}
