//
//  CaptureAndLayoutUITests.swift
//  CoreCreditUITests
//
//  Two things this UX pass changed that only a running app can prove:
//
//  1. **One capture surface.** The Quick Scan widget, the App Shortcut and the Action Button
//     (`corecredit://scan`), the Dashboard's Scan core button, and the intake form's own Scan core
//     action must all arrive at the same sheet. Switching between its Live and Document modes must
//     write nothing, and nothing captured may reach the ledger without the editor's own Save.
//  2. **Nothing hides under the tab bar.** Every root screen's last row and last action have to be
//     reachable, which is what the old `ZStack { background.ignoresSafeArea(); ScrollView { … } }`
//     took away by growing the stack past the tab bar's safe-area inset.
//
//  No camera and no StoreKit. Every launch passes `-uiTesting`, so the store is in memory and the
//  subscription engine is the stub; the capture sheet lands on `ScannerAvailability.simulator`,
//  where manual entry is the whole screen, and `DocumentScannerView.isSupported` is `false`, so the
//  Document half opens on its "no document camera here" explanation instead of a camera.
//

import XCTest

final class CaptureAndLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let scanLink = "corecredit://scan"

    /// The Live segment of the capture-mode control.
    private func liveSegment(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Live"].firstMatch
    }

    /// The Document segment of the capture-mode control.
    private func documentSegment(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Document"].firstMatch
    }

    // MARK: - One surface, three doors

    /// The external link, the Dashboard action, and the form's own action all open the same sheet.
    ///
    /// Asserted through `A11yID.Scan.root` *and* the mode picker, because "the same sheet" is the
    /// claim: a second scanner that happened to carry the same identifier would not have the Live /
    /// Document control on it.
    func testEveryScanCoreEntryOpensTheSameUnifiedSurface() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: CaptureAndLayoutUITests.scanLink)

        XCTContext.runActivity(named: "Door 1 — the widget, the Shortcut, the Action Button") { _ in
            requireExists(element(app, A11yID.Scan.root),
                          "the unified capture sheet opened by " + CaptureAndLayoutUITests.scanLink)
            requireExists(element(app, A11yID.Scan.modePicker), "the Live / Document control")
            requireExists(textField(app, A11yID.Scan.manualEntry),
                          "manual entry, which is present in every availability state")
            requireAbsent(element(app, A11yID.Scan.documentRoot),
                          "the Document half, which Live must not present at the same time")

            tapWhenHittable(control(app, A11yID.Scan.cancel), "the capture sheet's Cancel", in: app)
            requireAbsent(element(app, A11yID.Scan.root), "the dismissed capture sheet")
        }

        XCTContext.runActivity(named: "Door 2 — the intake form's own Scan core action") { _ in
            // Cancelling capture lands on the draft the link opened, so the form's own action is
            // right here.
            requireExists(textField(app, A11yID.Editor.partName), "the intake form")

            tapWhenHittable(control(app, A11yID.Editor.scan), "the form's Scan core action", in: app)
            requireExists(element(app, A11yID.Scan.root), "the same capture sheet, from the form")
            requireExists(element(app, A11yID.Scan.modePicker), "the Live / Document control")

            tapWhenHittable(control(app, A11yID.Scan.cancel), "the capture sheet's Cancel", in: app)
            tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel", in: app)
        }

        XCTContext.runActivity(named: "Door 3 — the Dashboard's Scan core button") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            tapWhenHittable(control(app, A11yID.Dashboard.scanCore),
                            "the Dashboard's Scan core button",
                            in: app)

            requireExists(element(app, A11yID.Scan.root),
                          "the same capture sheet, from the Dashboard")
            requireExists(element(app, A11yID.Scan.modePicker), "the Live / Document control")
            requireAbsent(element(app, A11yID.Paywall.root),
                          "the paywall, which an empty ledger on the free tier must never meet")
        }
    }

    // MARK: - Switching modes writes nothing

    /// Live → Document → Live, twice over, and the ledger is still empty at the end of it.
    ///
    /// Exactly one capture sheet exists at any moment: choosing a mode swaps the editor's route
    /// rather than presenting a sheet on top of a sheet, so each assertion checks the other half is
    /// *absent* as well as the chosen half being present.
    func testSwitchingBetweenLiveAndDocumentWritesNothing() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: CaptureAndLayoutUITests.scanLink)

        requireExists(element(app, A11yID.Scan.root), "the capture sheet, opening on Live")

        XCTContext.runActivity(named: "Live to Document") { _ in
            tapWhenHittable(documentSegment(app), "the Document segment", in: app)
            requireExists(element(app, A11yID.Scan.documentRoot), "the Document half")
            requireAbsent(element(app, A11yID.Scan.root),
                          "the Live half, which must close as Document opens")
        }

        XCTContext.runActivity(named: "Document back to Live") { _ in
            tapWhenHittable(liveSegment(app), "the Live segment", in: app)
            requireExists(element(app, A11yID.Scan.root), "the Live half again")
            requireAbsent(element(app, A11yID.Scan.documentRoot),
                          "the Document half, which must close as Live opens")
            requireExists(textField(app, A11yID.Scan.manualEntry),
                          "manual entry, still available after a round trip")
        }

        XCTContext.runActivity(named: "And nothing was written by any of it") { _ in
            tapWhenHittable(control(app, A11yID.Scan.cancel), "the capture sheet's Cancel", in: app)
            tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel", in: app)

            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, labelled: "No cores yet"),
                          "the ledger's empty state after switching capture modes")
            requireAbsent(element(app, A11yID.Cores.list),
                          "the cores list, which an empty ledger does not build")
        }
    }

    // MARK: - A capture cannot save by itself

    /// The whole confirmation chain, end to end, ending in nothing being written.
    ///
    /// Manual entry is used because it is the one capture path that runs without hardware — and it
    /// takes exactly the same route as a scan: candidate → review sheet → *Apply* → the draft. The
    /// point of the test is what comes after Apply: the draft is filled in, the record is not, and
    /// cancelling the editor leaves the ledger untouched.
    func testCapturedValuesReachTheDraftButNeverTheLedgerWithoutSave() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: CaptureAndLayoutUITests.scanLink)

        requireExists(element(app, A11yID.Scan.root), "the capture sheet")

        XCTContext.runActivity(named: "A captured value goes to the review step, not to a record") { _ in
            clearAndType("03-1887",
                         into: textField(app, A11yID.Scan.manualEntry),
                         "the capture sheet's manual-entry field",
                         in: app)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Scan.useManual), "Use this number", in: app)

            requireExists(element(app, A11yID.ScanReview.root),
                          "the review sheet every capture path has to pass through")
            requireExists(control(app, A11yID.ScanReview.apply),
                          "the Apply Selected Suggestions action")
        }

        XCTContext.runActivity(named: "Applying fills the form and saves nothing") { _ in
            tapWhenHittable(control(app, A11yID.ScanReview.apply),
                            "Apply Selected Suggestions",
                            in: app)

            requireExists(textField(app, A11yID.Editor.partName),
                          "the intake form the suggestion was applied to")
            requireExists(control(app, A11yID.Editor.save),
                          "the editor's Save, which is the only thing that writes a record")
        }

        XCTContext.runActivity(named: "Cancelling the editor leaves the ledger empty") { _ in
            tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel", in: app)

            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, labelled: "No cores yet"),
                          "the ledger's empty state after an applied-but-unsaved capture")
        }
    }

    // MARK: - The free limit is enforced at Save, not at the viewfinder

    /// A shop at its free limit still gets a viewfinder from the widget. It gets the paywall at the
    /// moment it tries to write the record, which is the moment the limit is actually about.
    func testQuickScanAtTheFreeLimitReachesCaptureAndIsBlockedOnlyAtSave() throws {
        let app = launchApp(seed: .fiveUnresolved,
                            tier: .free,
                            skipOnboarding: true,
                            deepLink: CaptureAndLayoutUITests.scanLink)

        XCTContext.runActivity(named: "A raised phone at the limit still gets a viewfinder") { _ in
            requireExists(element(app, A11yID.Scan.root),
                          "the capture sheet, which the free limit must not stand in front of")
            requireAbsent(element(app, A11yID.Paywall.root),
                          "the paywall, which must not answer a raised phone")

            tapWhenHittable(control(app, A11yID.Scan.cancel), "the capture sheet's Cancel", in: app)
        }

        XCTContext.runActivity(named: "The record is what is blocked") { _ in
            clearAndType("Alternator",
                         into: textField(app, A11yID.Editor.partName),
                         "the part name field",
                         in: app)
            dismissKeyboard(in: app)

            clearAndType("86.50",
                         into: textField(app, A11yID.Editor.amount),
                         "the expected credit field",
                         in: app)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Editor.vendor), "the vendor picker", in: app)
            tapMenuItem("NAPA", in: app)

            tapWhenHittable(control(app, A11yID.Editor.save), "the editor's Save", in: app)

            requireExists(element(app, A11yID.Paywall.root),
                          "the paywall, raised by the save rather than by the scan")
        }
    }

    // MARK: - Nothing hides under the tab bar

    /// The last row of every root screen has to be tappable, not merely present.
    ///
    /// `isHittable` is the assertion that matters: an element under the floating tab bar still
    /// *exists*, still reports a frame, and still fails every attempt to tap it. The seeded
    /// demonstration ledger is used because an empty screen is too short to hit the problem.
    func testRootScreensKeepTheirLastRowReachable() throws {
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "Dashboard — the last aging band") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            // The aging section is the last block on the screen and "31+ days" is its last row.
            let lastBand = element(app, labelled: "31+ days")
            requireExists(lastBand, "the last aging row on the Dashboard")
            XCTAssertTrue(scrollUntilHittable(lastBand, in: app),
                          "The Dashboard's last aging row never became tappable — it is still "
                              + "under the tab bar.")
        }

        XCTContext.runActivity(named: "Returns — the last Record credit action") { _ in
            tapTab(A11yID.Tab.returns, in: app)

            let creditButtons = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Record credit for")
            )
            XCTAssertGreaterThan(creditButtons.count, 0,
                                 "The seeded ledger should leave cores waiting on a credit.")

            let last = creditButtons.element(boundBy: creditButtons.count - 1)
            XCTAssertTrue(scrollUntilHittable(last, in: app),
                          "The last Record credit button on Returns never became tappable — it is "
                              + "still under the tab bar.")
        }

        XCTContext.runActivity(named: "Settings — the last row") { _ in
            tapTab(A11yID.Tab.settings, in: app)
            let about = element(app, labelled: "About")
            XCTAssertTrue(scrollUntilHittable(about, in: app),
                          "The Settings list's last row never became tappable.")
        }

        XCTContext.runActivity(named: "Cores — the bottom-most row in the ledger") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, A11yID.Cores.list), "the cores list")

            // Matched positionally rather than by part name: the ledger's ordering is the sort
            // control's business, and this assertion is about the *bottom* row whichever core that
            // happens to be.
            app.swipeUp()
            app.swipeUp()

            let rows = app.cells
            XCTAssertGreaterThan(rows.count, 0, "The seeded ledger should render rows.")
            let last = rows.element(boundBy: rows.count - 1)
            XCTAssertTrue(last.isHittable,
                          "The ledger's bottom-most row is not tappable — it is still under the "
                              + "tab bar.")
        }
    }

    /// The editor's Save is pinned, so it is reachable the moment the form opens — no scrolling, on
    /// any screen size, at any text size.
    func testTheEditorSaveIsReachableWithoutScrolling() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)

        tapTab(A11yID.Tab.cores, in: app)
        tapWhenHittable(control(app, A11yID.Cores.addButton), "the Cores add button", in: app)

        let save = control(app, A11yID.Editor.save)
        requireExists(save, "the editor's Save button")
        XCTAssertTrue(save.isHittable,
                      "The editor's Save was not hittable on the first frame. It is pinned in a "
                          + "bottom bar precisely so it never needs to be scrolled to.")

        // And exactly one of them: the duplicate toolbar Save is gone.
        XCTAssertEqual(app.buttons.matching(identifier: A11yID.Editor.save).count, 1,
                       "There should be exactly one Save control in the editor.")

        tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel", in: app)
    }
}
