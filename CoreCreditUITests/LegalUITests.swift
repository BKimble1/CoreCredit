//
//  LegalUITests.swift
//  CoreCreditUITests
//
//  The documents a shop is entitled to read: the privacy policy, the terms of use, and the note on
//  where its records actually live.
//
//  ## Every test here is an offline test
//
//  There is nothing to disable and no network condition to simulate. `LegalDocumentView` decodes
//  JSON that ships inside the app bundle (`CoreCredit/Resources/Legal/*.json`) and draws it as
//  ordinary SwiftUI `Text`. There is no web view, no `URLSession`, and no fetch of any kind on this
//  path — so asserting that the text is on screen *is* asserting that it renders without a
//  connection. A basement parts room with no signal is the case these screens were written for.
//
//  The phrases asserted below are quoted character for character out of those JSON files. They are
//  the app's own words, so a test failing on one means the shipped document changed — which is
//  exactly when a legal-text assertion should be looked at.
//

import XCTest

final class LegalUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Quoted text
    //
    // Each of these appears verbatim in the named bundled document.

    /// `privacy-policy.json` → `sections[0].heading`.
    private static let privacyFirstHeading = "The short version"

    /// The opening of `privacy-policy.json` → `summary`, matched as a prefix so the whole sentence
    /// does not have to be repeated here.
    private static let privacySummaryOpening = "Everything you enter in CoreCredit stays on this device"

    /// `terms-of-use.json` → `sections[0].heading`. Chosen over "What CoreCredit is", which is a
    /// prefix of the section after it.
    private static let termsFirstHeading = "What these terms cover"

    /// The opening of `terms-of-use.json` → `summary`.
    private static let termsSummaryOpening = "CoreCredit is an organisational ledger for core returns"

    /// `local-data-and-backup.json` → `sections[0].heading`.
    private static let localDataFirstHeading = "Where your records live"

    // MARK: - Document titles
    //
    // `LegalDocumentView` uses one identifier for all three documents and tells them apart by the
    // navigation title, which is the document's own `title` field.

    private static let privacyTitle = "Privacy Policy"
    private static let termsTitle = "Terms of Use"
    private static let localDataTitle = "Local Data and Backup"
    private static let legalHubTitle = "Legal"
    private static let supportTitle = "Support and contact"

    // MARK: - Settings ▸ Legal

    func testPrivacyPolicyOpensFromSettingsAndRendersItsText() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)
        openLegalHub(in: app)

        XCTContext.runActivity(named: "The Privacy Policy row opens the reader") { _ in
            tapWhenHittable(control(app, A11yID.Legal.privacyPolicy),
                            "the Privacy Policy row in the Legal hub",
                            in: app)

            requireExists(element(app, A11yID.Legal.documentRoot), "the legal document reader")
            requireExists(app.navigationBars[LegalUITests.privacyTitle],
                          "the Privacy Policy navigation bar")
        }

        XCTContext.runActivity(named: "The policy's own words are on screen") { _ in
            requireExists(element(app, labelled: LegalUITests.privacyFirstHeading),
                          "the policy's first section heading, \"\(LegalUITests.privacyFirstHeading)\"")
            requireExists(staticText(app, beginningWith: LegalUITests.privacySummaryOpening),
                          "the policy's summary sentence")

            // The screen says the offline promise out loud, which is the same promise this test is
            // making by never touching a network.
            requireExists(
                staticText(app, beginningWith: "This document is stored inside the app"),
                "the reader's \"stored inside the app\" note"
            )
        }
    }

    func testTermsOfUseOpensFromSettingsAndRendersItsText() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)
        openLegalHub(in: app)

        XCTContext.runActivity(named: "The Terms of Use row opens the same reader") { _ in
            tapWhenHittable(control(app, A11yID.Legal.termsOfUse),
                            "the Terms of Use row in the Legal hub",
                            in: app)

            requireExists(element(app, A11yID.Legal.documentRoot), "the legal document reader")
            requireExists(app.navigationBars[LegalUITests.termsTitle],
                          "the Terms of Use navigation bar")
        }

        XCTContext.runActivity(named: "The terms' own words are on screen") { _ in
            requireExists(element(app, labelled: LegalUITests.termsFirstHeading),
                          "the terms' first section heading, \"\(LegalUITests.termsFirstHeading)\"")
            requireExists(staticText(app, beginningWith: LegalUITests.termsSummaryOpening),
                          "the terms' summary sentence")
        }
    }

    func testLocalDataAndSupportScreensAreReachable() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)
        openLegalHub(in: app)

        XCTContext.runActivity(named: "Local Data and Backup") { _ in
            tapWhenHittable(control(app, A11yID.Legal.localData),
                            "the Local Data and Backup row in the Legal hub",
                            in: app)

            requireExists(element(app, A11yID.Legal.documentRoot), "the legal document reader")
            requireExists(app.navigationBars[LegalUITests.localDataTitle],
                          "the Local Data and Backup navigation bar")
            requireExists(element(app, labelled: LegalUITests.localDataFirstHeading),
                          "the note's first section heading, "
                              + "\"\(LegalUITests.localDataFirstHeading)\"")

            popToLegalHub(from: LegalUITests.localDataTitle, in: app)
        }

        XCTContext.runActivity(named: "Support and contact") { _ in
            tapWhenHittable(control(app, A11yID.Legal.support),
                            "the Support and contact row in the Legal hub",
                            in: app)

            // `LegalSupportView` carries no root identifier of its own — the identifier
            // `A11y.Legal.support` belongs to the *row* that pushes it and stays behind on the hub —
            // so the screen is asserted through its navigation bar and two card headings that appear
            // nowhere else in the app. "Version" is deliberately not used: the document reader has a
            // version row too, and a stale query would pass on the wrong screen.
            requireExists(app.navigationBars[LegalUITests.supportTitle],
                          "the Support and contact navigation bar")
            requireExists(element(app, labelled: "Getting in touch"),
                          "the contact card on the support screen")
            requireExists(element(app, labelled: "Things you can do without waiting"),
                          "the self-service card on the support screen")
        }
    }

    // MARK: - The paywall's copies

    /// Both documents a shopper is agreeing to have to be readable at the moment of purchase, and
    /// they have to be readable without a signal — which is why the paywall opens the bundled copy
    /// rather than a web page.
    func testBothLegalDocumentsOpenFromThePaywall() throws {
        // `fiveUnresolved` seeds exactly five unresolved cores — the free limit — so the next
        // "add" is the one that is blocked. Mirrors `PaywallUITests`. The engine is the stub, so
        // no product is ever purchased and no live StoreKit call is made.
        let app = launchApp(seed: .fiveUnresolved, tier: .free, skipOnboarding: true)

        XCTContext.runActivity(named: "A sixth core on the free tier reaches the paywall") { _ in
            tapTab(A11yID.Tab.cores, in: app)
            tapWhenHittable(control(app, A11yID.Cores.addButton), "the Cores add button", in: app)
            requireExists(element(app, A11yID.Paywall.root), "the paywall")
        }

        XCTContext.runActivity(named: "The controls a shopper must always have are present") { _ in
            // Rendered in a plain `VStack`, so they exist in the hierarchy below the fold. Asserted,
            // never tapped: `manageSubscription` hands off to Apple.
            requireExists(element(app, A11yID.Paywall.privacyPolicy),
                          "the paywall's Privacy Policy link")
            requireExists(element(app, A11yID.Paywall.termsOfUse),
                          "the paywall's Terms of Use link")
            requireExists(element(app, A11yID.Paywall.manageSubscription),
                          "the paywall's Manage subscription control")
        }

        XCTContext.runActivity(named: "The Terms of Use open over the paywall") { _ in
            openPaywallDocument(A11yID.Paywall.termsOfUse,
                                titled: LegalUITests.termsTitle,
                                heading: LegalUITests.termsFirstHeading,
                                in: app)
        }

        XCTContext.runActivity(named: "And so does the Privacy Policy") { _ in
            openPaywallDocument(A11yID.Paywall.privacyPolicy,
                                titled: LegalUITests.privacyTitle,
                                heading: LegalUITests.privacyFirstHeading,
                                in: app)
        }
    }

    // MARK: - Dynamic Type

    /// The largest accessibility text size is the one a policy is most likely to be read at, and the
    /// one a fixed-height layout would clip. Every size in `LegalDocumentView` comes from a text
    /// style rather than a point value, and this is what holds that to it.
    func testLegalDocumentSurvivesAnAccessibilityTextSize() throws {
        let app = launchApp(
            seed: .empty,
            tier: .free,
            skipOnboarding: true,
            extraArguments: [
                SystemLaunchArgument.contentSizeCategory,
                SystemLaunchArgument.accessibilityExtraLarge
            ]
        )

        openLegalHub(in: app)
        tapWhenHittable(control(app, A11yID.Legal.privacyPolicy),
                        "the Privacy Policy row at an accessibility text size",
                        in: app)

        XCTContext.runActivity(named: "The reader still renders") { _ in
            requireExists(element(app, A11yID.Legal.documentRoot),
                          "the legal document reader at an accessibility text size")
            requireExists(app.navigationBars[LegalUITests.privacyTitle],
                          "the Privacy Policy navigation bar at an accessibility text size")
        }

        XCTContext.runActivity(named: "And a section heading is still reachable, not clipped") { _ in
            let heading = element(app, labelled: LegalUITests.privacyFirstHeading)
            // The document is one long `ScrollView`, so at this text size the heading is below the
            // summary card rather than beside it. Scrolling to it is the assertion: a heading that
            // has been clipped out of the layout can never become hittable.
            XCTAssertTrue(
                scrollUntilHittable(heading, in: app),
                "The heading \"\(LegalUITests.privacyFirstHeading)\" could not be brought into "
                    + "reach at UICTContentSizeCategoryAccessibilityXL."
            )
        }
    }

    // MARK: - Navigation

    /// Settings ▸ Legal, left on the hub.
    private func openLegalHub(in app: XCUIApplication,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTContext.runActivity(named: "Settings ▸ Legal") { _ in
            tapTab(A11yID.Tab.settings, in: app, file: file, line: line)
            requireExists(element(app, A11yID.Settings.root), "the Settings list", file: file, line: line)

            // Legal is the third row of the last section, so on a phone it starts below the fold —
            // and `List` is lazy, so it is absent from the hierarchy rather than merely off screen.
            XCTAssertTrue(
                scrollUntilExists(element(app, A11yID.Settings.legal), in: app),
                "The Legal row never appeared in the Settings list.",
                file: file,
                line: line
            )

            tapWhenHittable(control(app, A11yID.Settings.legal),
                            "the Legal row in Settings",
                            in: app,
                            file: file,
                            line: line)
            requireExists(element(app, A11yID.Legal.root), "the Legal hub", file: file, line: line)
        }
    }

    /// Goes back to the Legal hub from a pushed document.
    ///
    /// Asserted on one of the hub's own rows rather than on `A11y.Legal.root`: the hub's list stays
    /// in the hierarchy behind a pushed screen, so its root identifier can answer a query before the
    /// pop has actually happened, while a row is only tappable once it is genuinely in front again.
    private func popToLegalHub(from title: String,
                               in app: XCUIApplication,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        let bar = app.navigationBars[title]
        guard requireExists(bar, "the \"\(title)\" navigation bar", file: file, line: line) else {
            return
        }

        // A back button is labelled with the previous screen's title. The first button in the bar
        // is the fallback for a build where that title is elided to a bare chevron; the document's
        // own share action sits on the trailing side, so the leading button is the one found first.
        let titled = bar.buttons[LegalUITests.legalHubTitle]
        let backButton = titled.exists ? titled : bar.buttons.element(boundBy: 0)

        tapWhenHittable(backButton,
                        "the back button on the \"\(title)\" screen",
                        in: app,
                        file: file,
                        line: line)

        requireExists(control(app, A11yID.Legal.privacyPolicy),
                      "the Legal hub after going back from \"\(title)\"",
                      file: file,
                      line: line)
    }

    /// Opens one of the paywall's two documents, checks it rendered, and closes it again.
    ///
    /// The paywall is presented as a sheet with no `NavigationStack` around it, so these documents
    /// arrive as a *second* sheet carrying their own stack and their own Done button — not as a
    /// push. Closing must therefore leave the paywall exactly where it was.
    private func openPaywallDocument(_ identifier: String,
                                     titled title: String,
                                     heading: String,
                                     in app: XCUIApplication,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        tapWhenHittable(control(app, identifier),
                        "the paywall's \"\(title)\" link",
                        in: app,
                        file: file,
                        line: line)

        requireExists(element(app, A11yID.Legal.documentRoot),
                      "the \(title) document opened from the paywall",
                      file: file,
                      line: line)
        requireExists(app.navigationBars[title],
                      "the \(title) navigation bar over the paywall",
                      file: file,
                      line: line)
        requireExists(element(app, labelled: heading),
                      "the \"\(heading)\" section heading in \(title)",
                      file: file,
                      line: line)

        tapWhenHittable(button(app, labelContaining: "Done"),
                        "the Done button on the \(title) sheet",
                        in: app,
                        file: file,
                        line: line)

        requireAbsent(element(app, A11yID.Legal.documentRoot),
                      "the closed \(title) sheet",
                      file: file,
                      line: line)
        requireExists(element(app, A11yID.Paywall.root),
                      "the paywall, which the document was only ever laid over",
                      file: file,
                      line: line)
    }

    // MARK: - Queries

    /// The first static text whose label starts with `prefix`.
    ///
    /// A paragraph in a legal document is a plain SwiftUI `Text` and carries no identifier of its
    /// own, so its own words are the only handle on it. A prefix match rather than equality, so a
    /// long sentence does not have to be repeated in full inside a test.
    private func staticText(_ app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
    }
}
