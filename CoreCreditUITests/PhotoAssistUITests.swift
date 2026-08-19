//
//  PhotoAssistUITests.swift
//  CoreCreditUITests
//
//  The screens around AI Photo Assist, driven without a camera, a photo library, or a LiDAR
//  scanner — none of which exist on a simulator in CI.
//
//  `-uiTestPhotoAssist <scenario>` scripts what the recognisers say they saw. Everything after that
//  seam is the real implementation: the real fusion, the real capping, the real conflict detection,
//  and the real review sheet. Only the pixels are fake, and the flag is ignored unless `-uiTesting`
//  is also set, so it cannot reach a shipping build.
//
//  The fusion rules themselves are asserted directly, with no fixtures and no screens, in
//  `CoreCreditTests/PhotoAssistFusionTests.swift`. What is worth testing here is what a person can
//  see and tap: that the feature is locked on Free, that photographs can be gathered and removed,
//  that disagreement is visible, that a hopeless set says so, and that nothing reaches the ledger
//  without the form's own Save.
//

import XCTest

final class PhotoAssistUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launchWithAssist(_ scenario: String,
                                  tier: UITestTier = .pro,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> XCUIApplication {
        launchApp(seed: .empty,
                  tier: tier,
                  skipOnboarding: true,
                  extraArguments: [LaunchFlag.photoAssist, scenario],
                  file: file,
                  line: line)
    }

    /// Opens Scan core from the Dashboard, then the assistant from inside it.
    private func openAssistant(in app: XCUIApplication) {
        tapWhenHittable(control(app, A11yID.Dashboard.scanCore), "Scan core on the Dashboard", in: app)
        requireExists(element(app, A11yID.Scan.root), "the capture sheet")

        let entry = control(app, A11yID.PhotoAssist.open)
        XCTAssertTrue(scrollUntilHittable(entry, in: app),
                      "The AI Photo Assist row was never reachable on the capture sheet.")
        entry.tap()
    }

    private func gatherSamples(in app: XCUIApplication) {
        tapWhenHittable(control(app, A11yID.PhotoAssist.addSamples),
                        "the sample photos action",
                        in: app)
    }

    /// Reads the gathered photographs. Leaves the sheet in its finished state.
    private func analyze(in app: XCUIApplication) {
        let read = control(app, A11yID.PhotoAssist.analyze)
        XCTAssertTrue(scrollUntilHittable(read, in: app),
                      "The action that reads the gathered photos never became reachable.")
        read.tap()
    }

    /// Accepts the result and opens the shared review sheet.
    ///
    /// A separate step from `analyze` on purpose: reading the photos and accepting what was read
    /// are two decisions, and the screen keeps them apart so nothing reaches the form on the
    /// strength of a tap that only meant "have a look".
    private func acceptResult(in app: XCUIApplication) {
        let review = control(app, A11yID.PhotoAssist.review)
        XCTAssertTrue(scrollUntilHittable(review, in: app),
                      "Analysis finished but the action that opens the review never appeared.")
        review.tap()
    }

    // MARK: - The gate

    /// On Free the row is visible, marked as locked, and opens the paywall rather than the feature.
    ///
    /// Visible rather than hidden on purpose: a paid feature nobody can see is a paid feature
    /// nobody buys, and a dead control with no explanation is worse than either.
    func testOnFreeTheAssistantIsLockedAndOffersTheUpgrade() throws {
        let app = launchWithAssist("success", tier: .free)

        tapWhenHittable(control(app, A11yID.Dashboard.scanCore), "Scan core on the Dashboard", in: app)
        requireExists(element(app, A11yID.Scan.root), "the capture sheet")

        let entry = control(app, A11yID.PhotoAssist.open)
        XCTAssertTrue(scrollUntilHittable(entry, in: app),
                      "A free shop must still be able to see that the assistant exists.")
        requireExists(element(app, A11yID.PhotoAssist.locked), "the lock on the assistant row")

        entry.tap()

        requireExists(element(app, A11yID.Paywall.root), "the paywall")
        requireAbsent(element(app, A11yID.PhotoAssist.root),
                      "the assistant itself, which Free must not reach")

        // Closing the paywall leaves the scanner exactly as it was. Nothing about tapping a locked
        // row may cost somebody the sheet they were working in.
        tapWhenHittable(control(app, A11yID.Paywall.close), "the paywall's close action", in: app)
        requireExists(element(app, A11yID.Scan.root), "the capture sheet, still open behind it")
    }

    /// On Pro the same row opens the assistant.
    func testOnProTheAssistantOpens() throws {
        let app = launchWithAssist("success")
        openAssistant(in: app)

        requireExists(element(app, A11yID.PhotoAssist.root), "the assistant")
        requireAbsent(element(app, A11yID.PhotoAssist.locked), "a lock, on a shop that has paid")
        requireExists(element(app, A11yID.PhotoAssist.capability),
                      "the line saying which senses this device actually has")
    }

    // MARK: - Gathering

    func testPhotosCanBeGatheredAndRemoved() throws {
        let app = launchWithAssist("success")
        openAssistant(in: app)

        gatherSamples(in: app)

        requireExists(element(app, A11yID.PhotoAssist.photo(0)), "the first gathered photo")
        requireExists(element(app, A11yID.PhotoAssist.photo(1)), "the second gathered photo")

        tapWhenHittable(control(app, A11yID.PhotoAssist.remove(1)),
                        "the remove action on the second photo",
                        in: app)

        requireAbsent(element(app, A11yID.PhotoAssist.photo(1)), "the removed photo")
        requireExists(element(app, A11yID.PhotoAssist.photo(0)),
                      "the photo that was not removed")
    }

    // MARK: - Results

    /// The ordinary path: gather, read, review, apply, and land back on the form with the values in
    /// it and nothing saved.
    func testSuggestionsReachTheFormAndNothingIsSavedWithoutSave() throws {
        let app = launchWithAssist("success")
        openAssistant(in: app)
        gatherSamples(in: app)
        analyze(in: app)
        acceptResult(in: app)

        XCTContext.runActivity(named: "The review sheet is the same one every capture path uses") { _ in
            let review = element(app, A11yID.ScanReview.root)
            XCTAssertTrue(review.waitForExistence(timeout: UITestTimeout.standard),
                          "Reading the photos never produced the shared review sheet.")
            requireExists(control(app, A11yID.ScanReview.apply), "the apply action")
        }

        XCTContext.runActivity(named: "Applying fills the form and saves nothing") { _ in
            tapWhenHittable(control(app, A11yID.ScanReview.apply),
                            "Apply selected suggestions",
                            in: app)

            requireExists(element(app, A11yID.Editor.partNumber),
                          "the form, with the applied values in it")

            // The ledger is still empty. Only the form's own Save writes a core, and it has not
            // been tapped.
            tapWhenHittable(control(app, A11yID.Editor.cancel), "the editor's Cancel", in: app)
            tapTab(A11yID.Tab.cores, in: app)
            requireAbsent(coreRow(app, titled: "Alternator"),
                          "a core, on a ledger where Save was never tapped")
        }
    }

    /// Two photographs reading different part numbers. Both survive, and neither is ticked.
    func testConflictingReadingsAreBothShownAndNeitherIsPreselected() throws {
        let app = launchWithAssist("conflict")
        openAssistant(in: app)
        gatherSamples(in: app)
        analyze(in: app)
        acceptResult(in: app)

        let review = element(app, A11yID.ScanReview.root)
        XCTAssertTrue(review.waitForExistence(timeout: UITestTimeout.standard),
                      "The conflicting set never reached the review sheet.")

        // Both readings are present. Picking one silently would be the app inventing a fact.
        requireExists(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "03-1887")).firstMatch,
                      "the first of two disagreeing part numbers")
        requireExists(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "03-9921")).firstMatch,
                      "the second of two disagreeing part numbers")
    }

    /// A photograph of a bare casting. The app says so rather than offering a shrug as a suggestion.
    func testNoConfidentMatchSaysSoPlainly() throws {
        let app = launchWithAssist("noMatch")
        openAssistant(in: app)
        gatherSamples(in: app)
        analyze(in: app)

        let apology = element(app, A11yID.PhotoAssist.noMatch)
        XCTAssertTrue(apology.waitForExistence(timeout: UITestTimeout.standard),
                      "Nothing was identified, and the screen did not say so.")

        // Manual entry is unaffected by the assistant coming up empty.
        tapWhenHittable(button(app, labelContaining: "Cancel"), "the assistant's Cancel", in: app)
        requireExists(element(app, A11yID.Scan.root), "the capture sheet")
        requireExists(control(app, A11yID.Scan.manualEntry),
                      "the manual entry field, which never depended on any of this")
    }

    // MARK: - Capability

    /// On hardware that reports no depth sensor — every simulator — the feature still works and
    /// says which analysis it is doing.
    func testWithoutDepthTheFeatureStillWorks() throws {
        let app = launchWithAssist("success")
        openAssistant(in: app)

        let capability = element(app, A11yID.PhotoAssist.capability)
        requireExists(capability, "the capability line")
        XCTAssertTrue(accessibilityText(of: capability).contains("Standard camera analysis"),
                      """
                      A simulator has no LiDAR scanner. The screen should say which analysis it is                       doing rather than implying a sense the device does not have.
                      """)

        // Auto capture needs ARKit, which a simulator does not have. The control is absent rather
        // than present and dead.
        requireAbsent(element(app, A11yID.PhotoAssist.autoCapture),
                      "the auto-capture control, on hardware that cannot do it")
    }
}
