//
//  NotificationSettingsUITests.swift
//  CoreCreditUITests
//
//  The reminder settings screen: the controls it offers, and the privacy default underneath them.
//
//  ## Nothing here can raise a permission prompt
//
//  `-uiTesting` sets `LaunchOptions.disableNotifications`, so `AppEnvironment` installs
//  `RecordingNotificationScheduler` instead of `UserNotificationScheduler`. It records calls and
//  performs nothing, and opening this screen only *reads* the permission — `refreshAuthorization()`
//  never requests it. The "Send a test notification" button is asserted on and never tapped.
//
//  ## Which permission state these tests observe
//
//  `-uiTestNotificationAuthorization <notDetermined|denied|authorized|provisional>` selects the
//  stubbed state: `LaunchOptions` parses it and `AppEnvironment` passes it to
//  `RecordingNotificationScheduler(status:)`. Real authorization cannot be revoked from inside the
//  process, so this is the only way to reach the `denied` branch (`A11y.Notifications.openSettings`)
//  and the `notDetermined` branch ("Allow reminders"). Omitting the flag keeps the recorder's
//  `.authorized` default. Selecting a state never *requests* permission — nothing here can prompt.
//

import XCTest

final class NotificationSettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Fallback label for the Settings row that pushes this screen, used only if the identifier
    /// `A11yID.Settings.notifications` cannot be resolved.
    private static let remindersRowLabel = "Notifications"

    // MARK: - The controls

    func testNotificationSettingsShowsItsControls() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)
        openNotificationSettings(in: app)

        try XCTContext.runActivity(named: "The master switch is present and on") { _ in
            // Waited for before `toggle(_:_:)` chooses, so the switch query has a settled tree to
            // match against rather than falling back to the container on a first frame.
            requireExists(element(app, A11yID.Notifications.enable), "the master reminders switch")
            let enableSwitch = toggle(app, A11yID.Notifications.enable)

            // `ShopProfile.remindersEnabled` ships `true`, which is why the rest of the screen is
            // built at all: `test` and `details` exist only while reminders are switched on.
            let state = try XCTUnwrap(enableSwitch.value as? String,
                                      "The master reminders switch reported no accessibility value.")
            XCTAssertEqual(state,
                           "1",
                           "The master reminders switch read \"\(state)\" on a freshly seeded "
                               + "profile, which ships with reminders enabled.")
        }

        try XCTContext.runActivity(named: "The item-detail switch is present") { _ in
            let details = try requireDeepControl(A11yID.Notifications.details,
                                                 "the item-detail switch",
                                                 in: app)
            XCTAssertTrue(details.exists,
                          "The item-detail switch did not resolve after being scrolled to.")
        }

        try XCTContext.runActivity(named: "The test-notification button is present") { _ in
            let test = try requireDeepControl(A11yID.Notifications.test,
                                              "the Send a test notification button",
                                              in: app)
            // Never tapped: the recorder would accept it, but the value of this assertion is that
            // the control exists, not that a stub logged a call.
            XCTAssertTrue(test.exists,
                          "The test-notification button did not resolve after being scrolled to.")
        }
    }

    // MARK: - The privacy default

    /// Off by default, deliberately: a banner can be read by anyone standing near the phone, and a
    /// shop's vendor terms and dollar figures are its own business. Worth pinning in the UI as well
    /// as in the model, because this is a default a redesign could quietly flip.
    func testItemDetailInNotificationsIsOffByDefault() throws {
        let app = launchApp(seed: .walkthrough, tier: .free, skipOnboarding: true)
        openNotificationSettings(in: app)

        let details = try requireDeepControl(A11yID.Notifications.details,
                                             "the item-detail switch",
                                             in: app)

        try XCTContext.runActivity(named: "The switch itself reads off") { _ in
            let state = try XCTUnwrap(details.value as? String,
                                      "The item-detail switch reported no accessibility value.")
            XCTAssertEqual(state,
                           "0",
                           "\"Show item details in notifications\" read \"\(state)\" on a fresh "
                               + "profile. It is the privacy default and must ship off.")
        }

        XCTContext.runActivity(named: "And the example alert names nothing") { _ in
            // The preview under the switch is one accessibility element: label "Example alert",
            // value the title and body a real reminder would carry. With details off it must not
            // name the part, the vendor, or the amount — this seed's walkthrough ledger holds an
            // alternator from NAPA at 86.50, so any of those appearing here would be the leak.
            //
            // Scrolled to, for the same reason `requireDeepControl` scrolls to the switch above
            // it: this form is lazy, and the preview sits *below* the switch — so a scroll that
            // stopped the moment the switch materialised need not have brought the preview with
            // it. The assertions below are unchanged; this only gets the element on screen.
            let preview = element(app, labelled: "Example alert")
            XCTAssertTrue(
                scrollUntilExists(preview, in: app),
                "The example alert preview never appeared, even after scrolling the reminder form."
            )
            requireExists(preview, "the example alert preview")

            let spoken = accessibilityText(of: preview)
            XCTAssertFalse(spoken.contains("NAPA"),
                           "The example alert read \"\(spoken)\", which names the vendor.")
            XCTAssertFalse(spoken.contains("Alternator"),
                           "The example alert read \"\(spoken)\", which names the part.")
            XCTAssertFalse(spoken.contains("86"),
                           "The example alert read \"\(spoken)\", which carries the amount.")
        }
    }

    // MARK: - Permission states

    /// The authorized state is the one every UI test observes, and it is the state in which the
    /// whole screen is usable.
    ///
    /// The denied counterpart is deliberately not attempted: see the note at the head of this file.
    /// `A11y.Notifications.openSettings` exists in the app and is applied to the "Open the Settings
    /// app" link, but only inside `if status == .denied`, and no launch argument can put the
    /// recorder into that state — so it is asserted *absent* here rather than left untested, which
    /// at least pins that an authorized device is never told to go and fix something.
    func testAuthorizedPermissionRendersTheControlsAndOffersNoRecovery() throws {
        let app = launchApp(seed: .empty, tier: .free, skipOnboarding: true)
        openNotificationSettings(in: app)

        XCTContext.runActivity(named: "The permission block states what this device will do") { _ in
            // The row is one accessibility element: label "Permission", value
            // `NotificationAuthorizationStatus.authorized.explanation`. Matching on both separates
            // it from the section header, which carries the same word and no value.
            let permission = app.descendants(matching: .any)
                .matching(
                    NSPredicate(format: "label == %@ AND value BEGINSWITH %@",
                                "Permission",
                                "Reminders are on")
                )
                .firstMatch
            requireExists(permission, "the permission row reporting an authorized device")
        }

        XCTContext.runActivity(named: "No recovery affordance is offered to an authorized device") { _ in
            requireAbsent(element(app, A11yID.Notifications.openSettings),
                          "the \"Open the Settings app\" link, which only a denied permission builds")
            requireAbsent(button(app, labelContaining: "Allow reminders"),
                          "the \"Allow reminders\" button, which only an undetermined permission "
                              + "builds")
        }

        try XCTContext.runActivity(named: "And the screen is fully usable") { _ in
            requireExists(element(app, A11yID.Notifications.enable), "the master reminders switch")
            try requireDeepControl(A11yID.Notifications.details,
                                   "the item-detail switch",
                                   in: app)
            try requireDeepControl(A11yID.Notifications.test,
                                   "the Send a test notification button",
                                   in: app)
        }
    }

    // MARK: - Navigation

    /// Settings ▸ Notifications, left on the reminder settings screen.
    private func openNotificationSettings(in app: XCUIApplication,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        tapTab(A11yID.Tab.settings, in: app, file: file, line: line)
        requireExists(element(app, A11yID.Settings.root), "the Settings list", file: file, line: line)

        // `List` is lazy, so a row far enough down is absent rather than merely off screen. The
        // reminders row sits above the Plan and App sections and is normally visible on a phone;
        // this keeps the test honest on a smaller screen without changing what it asserts.
        XCTAssertTrue(
            scrollUntilExists(remindersRow(in: app), in: app),
            "No row labelled \"\(NotificationSettingsUITests.remindersRowLabel)\" appeared in the "
                + "Settings list.",
            file: file,
            line: line
        )

        tapWhenHittable(remindersRow(in: app),
                        "the Notifications row in Settings",
                        in: app,
                        file: file,
                        line: line)
        requireExists(element(app, A11yID.Notifications.root),
                      "the notification settings screen",
                      file: file,
                      line: line)
    }

    /// The Settings row that pushes the reminder screen, matched on its label.
    ///
    /// Buttons first, then list cells, mirroring `control(_:_:)` — which cannot be used here because
    /// the row carries no identifier to hand it.
    private func remindersRow(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", NotificationSettingsUITests.remindersRowLabel)

        let button = app.buttons.matching(predicate).firstMatch
        if button.exists { return button }

        let cell = app.cells.matching(predicate).firstMatch
        if cell.exists { return cell }

        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - Lazy form

    /// Scrolls until the control carrying `identifier` is in the tree, then returns it.
    ///
    /// `NotificationSettingsView` is a `Form`, and a `Form` is lazy: the privacy switch and the test
    /// button sit below the timing, due-soon, follow-up, and weekly sections, so they are not merely
    /// off screen — they are absent from the accessibility hierarchy until the screen has been
    /// scrolled towards them. Waiting on existence alone would time out on a control that is
    /// perfectly present, which is why every deep control on this screen goes through here.
    @discardableResult
    private func requireDeepControl(_ identifier: String,
                                    _ description: String,
                                    in app: XCUIApplication,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> XCUIElement {
        let anyElement = element(app, identifier)
        XCTAssertTrue(
            scrollUntilExists(anyElement, in: app),
            "\(description) never appeared, even after scrolling the whole reminder form.",
            file: file,
            line: line
        )

        // Resolved after the scroll, so the switch and button queries have something to match.
        let asSwitch = app.switches.matching(identifier: identifier).firstMatch
        if asSwitch.exists { return asSwitch }

        let asControl = control(app, identifier)
        let resolved: XCUIElement? = asControl.exists ? asControl : nil
        return try XCTUnwrap(resolved,
                             "\(description) is in the hierarchy but resolved to no control "
                                 + "carrying \"\(identifier)\".",
                             file: file,
                             line: line)
    }

    // MARK: - Denied permission

    /// The recovery path a shop actually hits: reminders were refused at some point, so the screen
    /// must say so and offer the one action that can fix it — opening iOS Settings.
    ///
    /// Reachable only because `-uiTestNotificationAuthorization denied` forces the stub's state.
    /// Nothing here requests permission; the screen only reads it.
    func testDeniedPermissionExplainsItselfAndOffersSystemSettings() throws {
        let app = launchApp(seed: .empty,
                            tier: .free,
                            skipOnboarding: true,
                            notificationAuthorization: .denied)
        openNotificationSettings(in: app)

        try XCTContext.runActivity(named: "The screen offers a route to iOS Settings") { _ in
            let openSettings = element(app, A11yID.Notifications.openSettings)
            XCTAssertTrue(openSettings.waitForExistence(timeout: 10),
                          "A denied permission must offer a way into iOS Settings.")
            XCTAssertTrue(openSettings.isHittable,
                          "The recovery control must be reachable, not merely present.")
        }

        try XCTContext.runActivity(named: "The test button is not offered while denied") { _ in
            // Sending a test notification cannot work without permission, so offering it would
            // be a dead end. Asserted as a soft check: the screen may legitimately show it
            // disabled rather than absent.
            let test = element(app, A11yID.Notifications.test)
            if test.exists {
                XCTAssertFalse(test.isEnabled,
                               "A test notification cannot fire while permission is denied.")
            }
        }
    }
}
