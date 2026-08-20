//
//  RestoreAndBarcodeUITests.swift
//  CoreCreditUITests
//
//  The two things this release added that a person can actually tap: restoring a backup, and the
//  scanned-barcode card on a core.
//
//  Neither test completes a restore. A restore replaces the whole ledger, and driving the system
//  file importer from XCUITest means driving Files — another process, with its own layout, its own
//  iCloud state, and no guarantee a backup file is sitting anywhere it can reach. What *is* worth
//  asserting, and is fully deterministic, is the part that protects the shop: the entry point
//  exists, and **nothing is destroyed before a file has been chosen and confirmed**. The decode,
//  the validation, the replacement, and the rollback are covered exhaustively in
//  `CoreCreditTests/BackupRestoreTests.swift`, where they can be driven with real payloads.
//
//  Every launch passes `-uiTesting`: in-memory store, stub subscriptions, recorded notifications,
//  no animations, no camera.
//

import XCTest

final class RestoreAndBarcodeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Restore

    /// The entry point exists, says what it does, and destroys nothing on its own.
    func testRestoreIsOfferedAndDestroysNothingUntilAFileIsChosen() throws {
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "Data & export offers a restore") { _ in
            tapTab(A11yID.Tab.settings, in: app)

            // By identifier, not by a label fragment matched against `buttons`. A `NavigationLink`
            // inside a `List` publishes as a cell rather than a button, so the label query could
            // never resolve — which is what failed here the first time this suite was executed.
            // `control(_:_:)` looks through buttons, then cells, then anything.
            tapWhenHittable(control(app, A11yID.Settings.dataExport),
                            "the Data & export row",
                            in: app)

            let restore = control(app, A11yID.Data.restore)
            XCTAssertTrue(scrollUntilHittable(restore, in: app),
                          "Restore from backup was never reachable on Data & export.")

            // The preflight is what stands between a tap and a replaced ledger. It cannot exist
            // before a file has been read.
            requireAbsent(element(app, A11yID.Data.restorePreflight),
                          "the restore preflight, before any file has been chosen")
        }

        XCTContext.runActivity(named: "The ledger is untouched") { _ in
            // The seeded demonstration ledger is still there. If merely opening the screen could
            // cost a shop its records, nothing else about the feature would matter.
            tapTab(A11yID.Tab.cores, in: app)
            requireExists(element(app, A11yID.Cores.list), "the cores list")
            requireExists(coreRow(app, titled: "Alternator"), "the seeded alternator row")
        }
    }

    // MARK: - Barcode

    /// A core that carries a scanned payload shows it, labelled as a barcode rather than as a part
    /// number, with a way to copy it and a way to forget it.
    func testAScannedBarcodeIsShownSeparatelyFromThePartNumber() throws {
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        tapTab(A11yID.Tab.cores, in: app)
        openCoreDetail(titled: "Alternator", in: app)
        requireExists(element(app, A11yID.Detail.root), "the core detail screen")

        XCTContext.runActivity(named: "The payload is shown, and it is not the part number") { _ in
            // The seeded alternator carries a UPC-A (reported by Vision as EAN-13) that is
            // deliberately different from its part number, 03-1887.
            let copy = control(app, A11yID.Detail.copyBarcode)
            XCTAssertTrue(scrollUntilHittable(copy, in: app),
                          "The scanned-barcode card never became reachable on a core that has one.")

            requireExists(element(app, labelled: "Copy barcode value"), "the copy action")
            requireExists(control(app, A11yID.Detail.clearBarcode), "the clear action")
        }

        XCTContext.runActivity(named: "Copying leaves the record alone") { _ in
            tapWhenHittable(control(app, A11yID.Detail.copyBarcode),
                            "the copy barcode action",
                            in: app)

            // Copying is not a mutation. The card, and the core, are still exactly as they were.
            requireExists(control(app, A11yID.Detail.clearBarcode),
                          "the clear action after a copy")
            requireExists(element(app, A11yID.Detail.root), "the core detail screen after a copy")
        }

        XCTContext.runActivity(named: "Clearing asks first, and backing out changes nothing") { _ in
            tapWhenHittable(control(app, A11yID.Detail.clearBarcode),
                            "the clear barcode action",
                            in: app)

            // A confirmation dialog, not an immediate delete. Backing out has to leave the payload
            // in place — this is evidence, and the app removes evidence only when asked twice.
            let keep = button(app, labelContaining: "Keep it")
            if keep.waitForExistence(timeout: UITestTimeout.short) {
                keep.tap()
            }

            requireExists(control(app, A11yID.Detail.clearBarcode),
                          "the clear action after declining the confirmation")
        }
    }

    /// A core with no scanned payload has no barcode card at all — the overwhelmingly common case,
    /// since every hand-typed core is one.
    func testACoreWithNoBarcodeShowsNoBarcodeCard() throws {
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        tapTab(A11yID.Tab.cores, in: app)
        // Only the first seeded core carries a payload; the starter does not.
        openCoreDetail(titled: "Starter", in: app)
        requireExists(element(app, A11yID.Detail.root), "the core detail screen")

        // Scroll the whole screen so the assertion is about absence, not about being off-screen.
        app.swipeUp()
        app.swipeUp()

        requireAbsent(control(app, A11yID.Detail.copyBarcode),
                      "the copy-barcode action on a core that was typed in by hand")
        requireAbsent(control(app, A11yID.Detail.clearBarcode),
                      "the clear-barcode action on a core that was typed in by hand")
    }
}
