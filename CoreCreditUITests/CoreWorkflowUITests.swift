//
//  CoreWorkflowUITests.swift
//  CoreCreditUITests
//
//  The end-to-end smoke flow the product brief mandates:
//
//      create vendor -> add core -> mark ready -> create return batch
//      -> record receipt/reference -> mark credited -> verify dashboard zero
//
//  Everything here is manual entry. The editor's "Scan barcode" button is never touched, no photo
//  is ever attached, and the subscription engine is the in-memory stub — so the suite depends on
//  neither camera permission nor live StoreKit.
//

import XCTest

final class CoreWorkflowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - The mandated flow

    func testCoreTravelsFromVendorCreationToZeroMoneyAtRisk() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "Stage 1 — an empty, onboarded shop opens on the tabs") { _ in
            requireExists(element(app, A11yID.Dashboard.root), "the Dashboard")
            // Nothing has been logged, so there must be no headline figure to read yet.
            requireAbsent(element(app, A11yID.Dashboard.moneyAtRisk),
                          "the money-at-risk figure on an empty ledger")
        }

        createNAPA(in: app)
        addAlternator(in: app)

        XCTContext.runActivity(named: "Stage 4 — the dashboard counts the new core") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            // 86.50 is asserted as the digit groups "86" and "50" rather than as "$86.50".
            // `MoneyLabel` publishes only `Money.accessibilityText(currencyCode:)`, which
            // Foundation builds from the simulator's locale and storefront ("86 US dollars and
            // 50 cents"), so an exact string would be asserting Foundation's formatting rather
            // than the app's arithmetic.
            requireMoneyDigits(element(app, A11yID.Dashboard.moneyAtRisk),
                               ["86", "50"],
                               "money at risk after logging one 86.50 core")
        }

        markAlternatorReady(in: app)
        try createReturnBatch(in: app)

        XCTContext.runActivity(named: "Stage 7 — the core waits on a credit and still counts") { _ in
            requireExists(element(app, A11yID.Returns.awaitingCredit), "the awaiting-credit section")

            // The section card carries its identifier whether or not the queue has anything in it,
            // so existence alone proves nothing. These two are only rendered when the queue is
            // populated.
            requireExists(element(app, labelled: "Total still owed"),
                          "the outstanding total in the awaiting-credit queue")
            requireExists(button(app, labelContaining: "Record credit for Alternator"),
                          "the queue's Record credit action for the alternator")

            tapTab(A11yID.Tab.dashboard, in: app)
            requireMoneyDigits(element(app, A11yID.Dashboard.moneyAtRisk),
                               ["86", "50"],
                               "money at risk after the core went back but before any credit")
        }

        XCTContext.runActivity(named: "Stage 8 — the vendor credit lands in full") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            openCoreDetail(titled: "Alternator", in: app)

            tapWhenHittable(control(app, A11yID.Detail.recordCredit),
                            "the Record vendor credit button",
                            in: app)

            clearAndType("86.50",
                         into: textField(app, A11yID.Credit.amount),
                         "the credited amount field",
                         in: app)
            clearAndType("CM-8841",
                         into: textField(app, A11yID.Credit.reference),
                         "the credit memo field",
                         in: app)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Credit.save), "the Save credit button", in: app)

            // The sheet swaps its form for a result card once the credit is written.
            tapWhenHittable(button(app, labelContaining: "Done"),
                            "the Done button on the credit result",
                            in: app)

            requireLabel(element(app, A11yID.Detail.status),
                         equals: "Credited",
                         "the core's status badge")
        }

        XCTContext.runActivity(named: "Stage 9 — money at risk has dropped to zero") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)

            // The dashboard says it in words as well as in figures, and this assertion waits, so
            // it doubles as the gate that the header has re-rendered before the digits are read.
            requireExists(
                app.staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Nothing is open"))
                    .firstMatch,
                "the \"nothing is open\" summary line"
            )

            let moneyAtRisk = element(app, A11yID.Dashboard.moneyAtRisk)
            requireExists(moneyAtRisk, "the money-at-risk figure")

            let reported = accessibilityText(of: moneyAtRisk)
            XCTAssertTrue(reported.contains("0"),
                          "Money at risk reported \"\(reported)\", which shows no zero.")
            XCTAssertFalse(reported.contains("86"),
                           "Money at risk still reported \"\(reported)\" after a full credit.")
        }
    }

    // MARK: - The short-credit path

    func testShortCreditOpensADisputeForTheShortfall() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)

        createNAPA(in: app)
        addAlternator(in: app)
        markAlternatorReady(in: app)
        try createReturnBatch(in: app)

        XCTContext.runActivity(named: "The vendor credits 75.00 against an 86.50 charge") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            openCoreDetail(titled: "Alternator", in: app)

            tapWhenHittable(control(app, A11yID.Detail.recordCredit),
                            "the Record vendor credit button",
                            in: app)

            clearAndType("75.00",
                         into: textField(app, A11yID.Credit.amount),
                         "the credited amount field",
                         in: app)
            clearAndType("CM-8841",
                         into: textField(app, A11yID.Credit.reference),
                         "the credit memo field",
                         in: app)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Credit.save), "the Save credit button", in: app)
            tapWhenHittable(button(app, labelContaining: "Done"),
                            "the Done button on the credit result",
                            in: app)
        }

        XCTContext.runActivity(named: "The core reads Disputed and shows the 11.50 shortfall") { _ in
            requireLabel(element(app, A11yID.Detail.status),
                         equals: "Disputed",
                         "the core's status badge")

            // The discrepancy row is one accessibility element whose label is "Short by $11.50".
            // Same reasoning as the dashboard figure: the currency symbol and separators come from
            // the locale, so only the digit groups are asserted.
            let shortfall = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Short by"))
                .firstMatch
            requireExists(shortfall, "the short-credit discrepancy row")

            let reported = shortfall.label
            XCTAssertTrue(reported.contains("11"),
                          "The discrepancy read \"\(reported)\", which does not contain \"11\".")
            XCTAssertTrue(reported.contains("50"),
                          "The discrepancy read \"\(reported)\", which does not contain \"50\".")
        }

        XCTContext.runActivity(named: "Only the shortfall stays in money at risk") { _ in
            tapTab(A11yID.Tab.dashboard, in: app)
            requireMoneyDigits(element(app, A11yID.Dashboard.moneyAtRisk),
                               ["11", "50"],
                               "money at risk after a short credit")

            let reported = accessibilityText(of: element(app, A11yID.Dashboard.moneyAtRisk))
            XCTAssertFalse(reported.contains("86"),
                           "Money at risk still reported the full charge: \"\(reported)\".")
        }
    }

    // MARK: - Stages shared by both tests

    /// Stage 2 — Settings ▸ Vendors ▸ add "NAPA" with a 30-day return window.
    private func createNAPA(in app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTContext.runActivity(named: "Stage 2 — the shop adds the vendor NAPA") { _ in
            tapTab(A11yID.Tab.settings, in: app, file: file, line: line)
            requireExists(element(app, A11yID.Settings.root), "the Settings list", file: file, line: line)

            tapWhenHittable(control(app, A11yID.Settings.vendors),
                            "the Vendors row in Settings",
                            in: app,
                            file: file,
                            line: line)
            tapWhenHittable(control(app, A11yID.Settings.addVendor),
                            "the Add vendor button",
                            in: app,
                            file: file,
                            line: line)

            clearAndType("NAPA",
                         into: textField(app, A11yID.Settings.vendorName),
                         "the vendor name field",
                         in: app,
                         file: file,
                         line: line)
            // Typed rather than stepped, so the window is 30 because the test said so and not
            // because the app happened to default to it.
            clearAndType("30",
                         into: textField(app, A11yID.Settings.vendorWindow),
                         "the vendor return-window field",
                         in: app,
                         file: file,
                         line: line)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Settings.vendorSave),
                            "the vendor Save button",
                            in: app,
                            file: file,
                            line: line)

            requireExists(element(app, labelled: "NAPA"),
                          "the NAPA row in the vendor list",
                          file: file,
                          line: line)
        }
    }

    /// Stage 3 — Dashboard ▸ Add core, filled in entirely by hand.
    private func addAlternator(in app: XCUIApplication,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTContext.runActivity(named: "Stage 3 — an alternator core is logged by hand") { _ in
            tapTab(A11yID.Tab.dashboard, in: app, file: file, line: line)
            tapWhenHittable(control(app, A11yID.Dashboard.addCore),
                            "the Add core button",
                            in: app,
                            file: file,
                            line: line)

            clearAndType("Alternator",
                         into: textField(app, A11yID.Editor.partName),
                         "the part name field",
                         in: app,
                         file: file,
                         line: line)
            clearAndType("03-1887",
                         into: textField(app, A11yID.Editor.partNumber),
                         "the part number field",
                         in: app,
                         file: file,
                         line: line)
            clearAndType("INV-552",
                         into: textField(app, A11yID.Editor.invoice),
                         "the invoice field",
                         in: app,
                         file: file,
                         line: line)
            clearAndType("1024",
                         into: textField(app, A11yID.Editor.repairOrder),
                         "the repair order field",
                         in: app,
                         file: file,
                         line: line)
            dismissKeyboard(in: app)

            clearAndType("86.50",
                         into: textField(app, A11yID.Editor.amount),
                         "the expected credit field",
                         in: app,
                         file: file,
                         line: line)
            dismissKeyboard(in: app)

            // The vendor is a `Menu`, not a text field: tap the row, then the vendor.
            tapWhenHittable(control(app, A11yID.Editor.vendor),
                            "the vendor picker",
                            in: app,
                            file: file,
                            line: line)
            tapMenuItem("NAPA", in: app, file: file, line: line)

            tapWhenHittable(control(app, A11yID.Editor.save),
                            "the editor's Save button",
                            in: app,
                            file: file,
                            line: line)

            // The editor is a sheet; a successful save dismisses it.
            requireAbsent(control(app, A11yID.Editor.save),
                          "the core editor after saving",
                          timeout: UITestTimeout.standard,
                          file: file,
                          line: line)
        }
    }

    /// Stage 5 — open the core and move it to Ready to return.
    private func markAlternatorReady(in app: XCUIApplication,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTContext.runActivity(named: "Stage 5 — the old unit is on the shelf") { _ in
            tapTab(A11yID.Tab.cores, in: app, file: file, line: line)
            openCoreDetail(titled: "Alternator", in: app, file: file, line: line)

            requireLabel(element(app, A11yID.Detail.status),
                         equals: "Awaiting old core",
                         "the core's status badge before it is staged",
                         file: file,
                         line: line)

            tapWhenHittable(control(app, A11yID.Detail.markReady),
                            "the Ready to return status move",
                            in: app,
                            file: file,
                            line: line)

            requireLabel(element(app, A11yID.Detail.status),
                         equals: "Ready to return",
                         "the core's status badge after staging",
                         file: file,
                         line: line)
        }
    }

    /// Stage 6 — Returns ▸ create the NAPA batch and record its slip number.
    private func createReturnBatch(in app: XCUIApplication,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        try XCTContext.runActivity(named: "Stage 6 — the core goes back on a NAPA return") { _ in
            tapTab(A11yID.Tab.returns, in: app, file: file, line: line)
            requireExists(element(app, A11yID.Returns.root), "the Returns screen", file: file, line: line)

            // Keyed on the vendor: the ready section renders one of these buttons per vendor group,
            // so the identifier names the group it belongs to.
            tapWhenHittable(control(app, A11yID.Returns.createBatch(vendor: "NAPA")),
                            "the Create return batch button for NAPA",
                            in: app,
                            file: file,
                            line: line)

            // `ReturnsModel.beginBatch(for:)` hands the whole vendor group to the sheet as its
            // preselection, so the core is already ticked. Tapping the row here would *remove* it
            // from the return, so the selection is asserted rather than performed.
            let selectionRow = app.buttons
                .matching(NSPredicate(format: "label == %@", "Alternator"))
                .firstMatch
            requireExists(selectionRow, "the alternator's selection row on the return sheet",
                          file: file, line: line)
            let selectionState = try XCTUnwrap(
                selectionRow.value as? String,
                "The alternator's selection row reported no accessibility value.",
                file: file,
                line: line
            )
            XCTAssertEqual(selectionState,
                           "Included in this return",
                           "The alternator was not selected for the return batch.",
                           file: file,
                           line: line)

            clearAndType("RET-991",
                         into: textField(app, A11yID.Returns.reference),
                         "the return reference field",
                         in: app,
                         file: file,
                         line: line)
            dismissKeyboard(in: app)

            tapWhenHittable(control(app, A11yID.Returns.confirm),
                            "the Create return button",
                            in: app,
                            file: file,
                            line: line)

            // Confirming dismisses the sheet and drops the core into the credit queue.
            requireAbsent(control(app, A11yID.Returns.confirm),
                          "the return sheet after confirming",
                          timeout: UITestTimeout.standard,
                          file: file,
                          line: line)
        }
    }
}
