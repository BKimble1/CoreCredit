//
//  UITestSupport.swift
//  CoreCreditUITests
//
//  Launch helpers, robust waits, and the small query helpers every test file shares.
//
//  ## Why the identifiers are duplicated here
//
//  `CoreCredit/Components/AccessibilityIdentifiers.swift` is a member of the **app** target only.
//  The UI test target is a `PBXFileSystemSynchronizedRootGroup` over `CoreCreditUITests/` with no
//  membership exception, and a UI test bundle cannot import the app module anyway — the app runs
//  in a separate process. So `A11yID` below is a verbatim mirror of `A11y`, copied string for
//  string. If the app renames one, nothing fails to compile: the query simply never resolves and
//  the test fails on its wait with the message naming the identifier.
//

import XCTest

// MARK: - Identifier mirror

/// Verbatim copy of the app's `A11y` strings, each one copied character for character — a mirror
/// member whose value has drifted from the app's is a query that resolves to nothing rather than a
/// build failure.
///
/// Not every member the app declares is here, and a few here are not queried by any test yet: a
/// screen's identifiers are mirrored in the same change that adds them to the app, so the mirror
/// never lags behind the screen a test is about to be written for.
enum A11yID {

    /// The app shell. `deepLinkTarget` marks whatever a deep link, a Shortcut, or the Action
    /// Button brought to the front — the quick-scan editor, in practice — so a test can wait on
    /// one identifier rather than on the screen it happens to resolve to.
    enum Root {
        static let deepLinkTarget = "root.deepLinkTarget"
    }

    enum Tab {
        static let dashboard = "tab.dashboard"
        static let cores = "tab.cores"
        static let returns = "tab.returns"
        static let settings = "tab.settings"
    }

    enum Dashboard {
        static let moneyAtRisk = "dashboard.moneyAtRisk"
        static let overdueAmount = "dashboard.overdueAmount"
        static let addCore = "dashboard.addCore"
        static let root = "dashboard.root"
        static let scanCore = "dashboard.scanCore"
    }

    enum Cores {
        static let root = "cores.root"
        static let list = "cores.list"
        static let addButton = "cores.add"

        /// The app builds row identifiers as `"cores.row." + id.uuidString`. The UUID is created at
        /// runtime, so tests match on this prefix instead.
        static let rowPrefix = "cores.row."

        // There is no `searchField` member, because the app has none either. The ledger's search
        // field is injected into the navigation bar by `.searchable` and no custom identifier can
        // reach it; `searchField(_:)` below goes through `app.searchFields` instead.
    }

    enum Editor {
        static let partName = "editor.partName"
        static let partNumber = "editor.partNumber"
        static let amount = "editor.amount"
        static let vendor = "editor.vendor"
        static let bin = "editor.bin"
        static let invoice = "editor.invoice"
        static let repairOrder = "editor.repairOrder"
        /// The one Save. It lives in a pinned bar above the safe area rather than in the toolbar,
        /// so it is reachable without scrolling and stays above the keyboard.
        static let save = "editor.save"
        static let cancel = "editor.cancel"
        /// "Scan core" — the unified capture entry at the top of the intake form. It opens the
        /// capture sheet, which on the simulator lands on its no-camera state, so a test may tap it
        /// without ever meeting a permission prompt.
        static let scan = "editor.scan"
        /// The References disclosure header. The section is folded away while it is empty, so a
        /// test that wants the invoice or repair-order field opens it first.
        static let referencesSection = "editor.referencesSection"
    }

    /// The unified "Scan core" surface. Reachable from the Dashboard's `scanCore` action, the
    /// intake form's own Scan core action, and every external entry point (`corecredit://scan`),
    /// all of which open the editor with this sheet already in front of it — on the simulator that
    /// lands on the "no camera" state, where manual entry is the whole screen and no permission is
    /// involved.
    ///
    /// `root` is Live capture and `documentRoot` is Document capture. Only one is ever presented:
    /// choosing the other mode swaps `CoreEditorModel.Route`, so a test asserting one must assert
    /// the absence of the other rather than expecting both.
    enum Scan {
        static let root = "scan.root"
        static let documentRoot = "scan.documentRoot"
        static let modePicker = "scan.modePicker"
        static let openDocumentCamera = "scan.openDocumentCamera"
        static let manualEntry = "scan.manualEntry"
        static let useManual = "scan.useManual"
        static let resume = "scan.resume"
        static let cancel = "scan.cancel"
    }

    /// The confirmation step every capture path ends on.
    enum ScanReview {
        static let root = "scanReview.root"
        static let apply = "scanReview.apply"
        static let retake = "scanReview.retake"
        static let cancel = "scanReview.cancel"

        /// Mirrors `A11y.ScanReview.row(_:)`. The candidate's UUID is created at runtime, so tests
        /// normally match on `rowPrefix` instead of building the whole identifier.
        static func row(_ id: UUID) -> String { "scanReview.row." + id.uuidString }

        static let rowPrefix = "scanReview.row."
    }

    enum Detail {
        static let root = "detail.root"
        static let status = "detail.status"
        static let markReady = "detail.markReady"
        static let recordCredit = "detail.recordCredit"
        static let copyBarcode = "detail.copyBarcode"
        static let clearBarcode = "detail.clearBarcode"
    }

    enum Returns {
        static let root = "returns.root"
        static let reference = "returns.reference"
        static let confirm = "returns.confirm"
        static let awaitingCredit = "returns.awaitingCredit"

        /// Mirrors `A11y.Returns.createBatch(vendor:)`. One button is rendered per ready vendor
        /// group, so the vendor name is part of the identifier and each button is unique.
        static func createBatch(vendor name: String) -> String { "returns.createBatch." + name }
    }

    enum Credit {
        static let amount = "credit.amount"
        static let reference = "credit.reference"
        static let save = "credit.save"
    }

    enum Paywall {
        static let root = "paywall.root"
        static let monthly = "paywall.monthly"
        static let annual = "paywall.annual"
        static let restore = "paywall.restore"
        static let close = "paywall.close"
        static let privacyPolicy = "paywall.privacyPolicy"
        static let termsOfUse = "paywall.termsOfUse"

        /// Applied to both forms of the control — the in-app management button and the web-page
        /// link it falls back to — because only one of them is ever built.
        static let manageSubscription = "paywall.manageSubscription"
    }

    enum Settings {
        static let root = "settings.root"
        static let vendors = "settings.vendors"
        static let addVendor = "settings.addVendor"
        static let vendorName = "settings.vendorName"
        static let vendorWindow = "settings.vendorWindow"
        static let vendorSave = "settings.vendorSave"
        static let dataExport = "settings.dataExport"
        static let diagnostics = "settings.diagnostics"
        static let notifications = "settings.notifications"
        static let appearance = "settings.appearance"
        static let legal = "settings.legal"
    }

    /// Light / Dark / Match device.
    enum Appearance {
        static let root = "appearance.root"
        static func option(_ rawValue: String) -> String { "appearance.option." + rawValue }
    }

    /// The Data & export screen's restore flow.
    enum Data {
        static let restore = "data.restore"
        static let restorePreflight = "data.restorePreflight"
        static let restoreCancel = "data.restoreCancel"
    }

    enum Diagnostics {
        static let root = "diagnostics.root"
        static let clear = "diagnostics.clear"
    }

    /// The Legal hub and the document reader its rows push.
    ///
    /// `documentRoot` is one identifier for all three documents: the app has a single
    /// `LegalDocumentView` parameterised by document, reached from this hub and from the paywall, so
    /// a test waits on one thing and reads the navigation title to tell the documents apart.
    enum Legal {
        static let root = "legal.root"
        static let privacyPolicy = "legal.privacyPolicy"
        static let termsOfUse = "legal.termsOfUse"
        static let localData = "legal.localData"
        static let support = "legal.support"
        static let documentRoot = "legal.documentRoot"
    }

    /// The notification settings screen.
    ///
    /// `enable` is present whenever a shop profile exists; `test` and `details` only while reminders
    /// are switched on; `openSettings` only while this device has denied the permission. A query
    /// that resolves to nothing therefore describes the screen's state, not a drifted identifier.
    ///
    /// Under `-uiTesting` the app installs `RecordingNotificationScheduler`, so nothing on this
    /// screen can raise a real system permission prompt.
    enum Notifications {
        static let root = "notifications.root"
        static let enable = "notifications.enable"
        static let test = "notifications.test"
        static let openSettings = "notifications.openSettings"
        static let details = "notifications.details"
    }

    enum Onboarding {
        static let root = "onboarding.root"
        static let next = "onboarding.next"
        static let shopName = "onboarding.shopName"
        static let finish = "onboarding.finish"
        static let skip = "onboarding.skip"
    }
}

// MARK: - Launch vocabulary

/// Mirrors `SeedScenario`. `noSeed` carries the raw value `"none"`; the Swift case is renamed so a
/// call site never has to disambiguate `.none` from `Optional.none`.
enum UITestSeed: String {
    case noSeed = "none"
    case empty
    case fiveUnresolved
    case walkthrough
}

/// Mirrors `SubscriptionTier`'s raw values, which is what `-uiTestTier` is matched against.
enum UITestTier: String {
    case free
    case pro
}

/// Verbatim copy of `LaunchOptions.Flag`.
enum LaunchFlag {
    static let uiTesting = "-uiTesting"
    static let seed = "-uiTestSeed"
    static let tier = "-uiTestTier"
    static let storeKitFailure = "-uiTestStoreKitFailure"
    static let scannerPayload = "-uiTestScannerPayload"
    static let skipOnboarding = "-uiTestSkipOnboarding"

    /// Delivers a `corecredit://` URL at launch, as though the system had opened it.
    static let deepLink = "-uiTestDeepLink"

    /// Forces the stubbed notification authorization state.
    ///
    /// Real authorization cannot be revoked from inside the process, and
    /// `RecordingNotificationScheduler` reports `.authorized` by default, so without this the
    /// denied and not-determined branches of `NotificationSettingsView` are unreachable.
    static let notificationAuthorization = "-uiTestNotificationAuthorization"
}

/// The authorization states `LaunchFlag.notificationAuthorization` accepts. Values match
/// `LaunchOptions.notificationAuthorization(named:)` in the app target.
enum UITestNotificationAuthorization: String {
    case notDetermined
    case denied
    case authorized
    case provisional
}

/// System launch arguments a test occasionally needs. Not CoreCredit's own — these are read by
/// UIKit, which is why they are passed through `launchApp(extraArguments:)` rather than given a
/// parameter of their own.
enum SystemLaunchArgument {

    /// Forces a content size category for the whole run, so a screen can be asserted at an
    /// accessibility text size without touching device settings.
    static let contentSizeCategory = "-UIPreferredContentSizeCategoryName"

    static let accessibilityExtraLarge = "UICTContentSizeCategoryAccessibilityXL"
}

enum UITestTimeout {
    /// Cold launch on a busy CI simulator.
    static let launch: TimeInterval = 30
    /// A screen, sheet, or record change.
    static let standard: TimeInterval = 10
    /// A control that is expected to be on screen already, or an absence check.
    static let short: TimeInterval = 3
}

// MARK: - Launching

extension XCTestCase {

    /// Launches CoreCredit configured for a deterministic run.
    ///
    /// `-uiTesting` is always passed: it is the app's master switch for the in-memory store, the
    /// stub scanner, the stub subscription engine, the recording notification scheduler, and
    /// disabled animations. Without it the value flags deliberately do nothing.
    ///
    /// - Parameters:
    ///   - seed: Which fixture the in-memory store opens with.
    ///   - tier: Forces the stub entitlement. `nil` leaves the engine's own answer in charge.
    ///   - skipOnboarding: Marks the seeded profile onboarded so the run starts on the tab bar.
    ///   - storeKitFailure: Makes the stub engine fail product loading.
    ///   - scannerPayload: Pre-fills the stub recogniser. Never needed for manual entry.
    ///   - deepLink: A `corecredit://` URL handed to the app at launch, as though the system had
    ///     opened it. This is the *cold-start* path — the URL reaches `DeepLinkRouter` before the
    ///     shell exists and waits there until `MainTabView` consumes it — and it is the only way
    ///     into it, because XCUITest cannot open a custom scheme without driving Safari. The app
    ///     ignores the argument unless `-uiTesting` is set, which it always is here.
    ///   - extraArguments: Arguments appended verbatim after CoreCredit's own, for the system
    ///     switches a test occasionally needs (see `SystemLaunchArgument`). Appended last so a
    ///     CoreCredit value flag can never swallow one of them.
    func launchApp(seed: UITestSeed = .empty,
                   tier: UITestTier? = .free,
                   skipOnboarding: Bool = true,
                   storeKitFailure: Bool = false,
                   scannerPayload: String? = nil,
                   deepLink: String? = nil,
                   notificationAuthorization: UITestNotificationAuthorization? = nil,
                   extraArguments: [String] = [],
                   file: StaticString = #filePath,
                   line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()

        var arguments: [String] = [LaunchFlag.uiTesting, LaunchFlag.seed, seed.rawValue]
        if let tier = tier {
            arguments.append(contentsOf: [LaunchFlag.tier, tier.rawValue])
        }
        if skipOnboarding {
            arguments.append(LaunchFlag.skipOnboarding)
        }
        if storeKitFailure {
            arguments.append(LaunchFlag.storeKitFailure)
        }
        if let scannerPayload = scannerPayload {
            arguments.append(contentsOf: [LaunchFlag.scannerPayload, scannerPayload])
        }
        if let deepLink = deepLink {
            arguments.append(contentsOf: [LaunchFlag.deepLink, deepLink])
        }
        if let notificationAuthorization = notificationAuthorization {
            arguments.append(contentsOf: [LaunchFlag.notificationAuthorization,
                                          notificationAuthorization.rawValue])
        }
        arguments.append(contentsOf: extraArguments)

        app.launchArguments = arguments
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: UITestTimeout.launch),
            "CoreCredit did not reach the foreground within \(UITestTimeout.launch)s. "
                + "Launch arguments: \(arguments.joined(separator: " "))",
            file: file,
            line: line
        )
        return app
    }
}

// MARK: - Queries

extension XCTestCase {

    /// Any element carrying `identifier`, whatever its type.
    ///
    /// SwiftUI's `.accessibilityIdentifier` propagates from a container to the elements inside it,
    /// so a screen-level identifier such as `dashboard.root` lands on a container rather than on a
    /// control. A type-agnostic descendant query is therefore the only lookup that works for every
    /// identifier in the app's contract.
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The tappable element carrying `identifier`, preferring real controls over containers.
    ///
    /// Buttons come first, then list cells, then anything. Every query uses `firstMatch` because
    /// several identifiers in this app are legitimately applied more than once — `CoreListView` is
    /// instantiated in five places, so a filtered list pushed from the Dashboard carries the same
    /// `cores.*` identifiers as the ledger behind it.
    func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        if button.exists { return button }

        let cell = app.cells.matching(identifier: identifier).firstMatch
        if cell.exists { return cell }

        return element(app, identifier)
    }

    /// The text field carrying `identifier`.
    ///
    /// The direct query is the one that resolves for every field in the app: `editor.amount` and
    /// `credit.amount` are handed to `CurrencyTextField` as its `fieldIdentifier`, which applies
    /// them to the inner `TextField` rather than to the composed `VStack`. The nested lookup is
    /// kept as a fallback for any identifier that still lands on a container.
    func textField(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let direct = app.textFields.matching(identifier: identifier).firstMatch
        if direct.exists { return direct }

        let container = element(app, identifier)
        if container.exists {
            let nested = container.textFields.firstMatch
            if nested.exists { return nested }
        }
        return direct
    }

    /// The switch carrying `identifier`, falling back to whatever else carries it.
    ///
    /// A SwiftUI `Toggle` publishes as a `.switch` whose accessibility *value* is `"1"` or `"0"`,
    /// which is how a test reads whether a setting is on. Call this **after** the control is on
    /// screen: several of the app's toggles live far enough down a lazy `Form` that they are not in
    /// the accessibility tree until the screen has been scrolled towards them.
    func toggle(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let direct = app.switches.matching(identifier: identifier).firstMatch
        if direct.exists { return direct }
        return element(app, identifier)
    }

    /// Any element whose accessibility label is exactly `label`.
    func element(_ app: XCUIApplication, labelled label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    /// The first button whose accessibility label contains `fragment`.
    func button(_ app: XCUIApplication, labelContaining fragment: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", fragment))
            .firstMatch
    }

    /// A core row in the ledger, matched on the documented `cores.row.<uuid>` prefix and on the
    /// row's own label, which `CoreRowView` builds as "<part name>, <vendor> • <part number>".
    func coreRow(_ app: XCUIApplication, titled title: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            A11yID.Cores.rowPrefix,
            title
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// The search field created by `.searchable`.
    ///
    /// An `.accessibilityIdentifier` written next to `.searchable` lands on the view the modifier
    /// is attached to, not on the field the modifier injects into the navigation bar, so the app
    /// deliberately declares no identifier for it. `searchFields` is the documented XCUITest
    /// affordance for a system search control.
    func searchField(_ app: XCUIApplication) -> XCUIElement {
        app.searchFields.firstMatch
    }
}

// MARK: - Waiting

extension XCTestCase {

    /// Waits for `element` to exist, failing with a message that names what was being waited for.
    @discardableResult
    func requireExists(_ element: XCUIElement,
                       _ description: String,
                       timeout: TimeInterval = UITestTimeout.standard,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        XCTFail("Timed out after \(timeout)s waiting for \(description) to appear.",
                file: file,
                line: line)
        return false
    }

    /// Waits for `element` to be gone. Used for "the paywall did not appear" style assertions.
    func requireAbsent(_ element: XCUIElement,
                       _ description: String,
                       timeout: TimeInterval = UITestTimeout.short,
                       file: StaticString = #filePath,
                       line: UInt = #line) {
        guard element.exists else { return }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("\(description) was still present after \(timeout)s, and should not have been.",
                    file: file,
                    line: line)
        }
    }

    /// Waits for an element's accessibility label to become exactly `expected`.
    ///
    /// Status changes are driven by a SwiftData write flowing back through `@Query`, so the label
    /// is the observable end of that round trip. Polling a predicate is what replaces a `sleep`.
    func requireLabel(_ element: XCUIElement,
                      equals expected: String,
                      _ description: String,
                      timeout: TimeInterval = UITestTimeout.standard,
                      file: StaticString = #filePath,
                      line: UInt = #line) {
        guard requireExists(element, description, timeout: timeout, file: file, line: line) else {
            return
        }
        if element.label == expected { return }

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("\(description) read \"\(element.label)\" instead of \"\(expected)\" "
                        + "after \(timeout)s.",
                    file: file,
                    line: line)
        }
    }

    /// The index of the first element in `elements` that exists, polled until one does.
    ///
    /// Used where a screen can legitimately be in one of two states — the Cores tab either shows
    /// the ledger or is still standing on a core that was opened earlier. Each `exists` is an IPC
    /// round trip, so the loop paces itself; nothing sleeps.
    func indexOfFirstExisting(_ elements: [XCUIElement],
                              timeout: TimeInterval = UITestTimeout.standard) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for (index, element) in elements.enumerated() where element.exists {
                return index
            }
        } while Date() < deadline
        return nil
    }

    /// Scrolls the frontmost scrolling content until `element` can be tapped.
    ///
    /// Several primary actions in this app sit at the bottom of a `ScrollView` — the credit sheet's
    /// Save, the batch sheet's Confirm, the detail screen's status moves. They exist in the
    /// hierarchy immediately (plain `VStack`s, not lazy), so `exists` is true while `isHittable`
    /// is false. Swiping on the application taps the frontmost scroller, which is what a presented
    /// sheet needs.
    /// **This only ever scrolls one way — forwards.** `swipeUp` reveals content *below* the
    /// viewport, so a control that has ended up *above* it gets further away with every swipe, and
    /// this returns false after `maxSwipes` on something that was on screen a moment earlier.
    ///
    /// The fix is to drive a screen in the order it is laid out rather than to teach this to swipe
    /// both ways. A downward swipe is not a safe general move: every editor and review screen in
    /// this app is presented as a sheet, and a downward drag on a sheet that is already at the top
    /// of its scroll view dismisses the sheet — losing whatever the test had typed and failing
    /// somewhere far away from the cause. `dismissKeyboard(in:)` avoids swiping for the same
    /// reason.
    /// The swipe is deliberately `.slow`, and there are more of them than a full-speed scroll would
    /// need.
    ///
    /// A default-velocity `swipeUp()` throws the content several hundred points. That is fine when
    /// the target is far below, and wrong when it is just past the fold: the gesture carries it
    /// straight over the top of the viewport, the next check still says "not hittable", and every
    /// remaining swipe lands in a scroll view already at its end. The editor's References header
    /// failed exactly that way — reachable in one big swipe while the form sat near the top, and
    /// unreachable in eight once the form had scrolled down to the amount field and left only a
    /// short distance to travel. A slow swipe moves a fraction of that and cannot overshoot a
    /// nearby control.
    @discardableResult
    func scrollUntilHittable(_ element: XCUIElement,
                             in app: XCUIApplication,
                             maxSwipes: Int = 14) -> Bool {
        var remaining = maxSwipes
        while remaining > 0 {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
            remaining -= 1
        }
        return element.exists && element.isHittable
    }

    /// Scrolls the frontmost scrolling content until `element` **exists**.
    ///
    /// The counterpart to `scrollUntilHittable(_:in:)`, for the screens built on `Form` and `List`.
    /// Those are lazy: a row far enough down is not merely off screen, it is absent from the
    /// accessibility tree entirely, so `waitForExistence` would time out on a control that is
    /// perfectly present. Nothing sleeps — each `exists` is an IPC round trip, which paces the loop.
    @discardableResult
    func scrollUntilExists(_ element: XCUIElement,
                           in app: XCUIApplication,
                           maxSwipes: Int = 12) -> Bool {
        var remaining = maxSwipes
        while remaining > 0 {
            if element.exists { return true }
            app.swipeUp()
            remaining -= 1
        }
        return element.exists
    }

    /// Waits for existence, scrolls the element into reach, waits for hittability, then taps.
    func tapWhenHittable(_ element: XCUIElement,
                         _ description: String,
                         in app: XCUIApplication,
                         timeout: TimeInterval = UITestTimeout.standard,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        guard requireExists(element, description, timeout: timeout, file: file, line: line) else {
            return
        }

        if element.isHittable == false {
            // A keyboard left up by the previous field covers the bottom of the screen, and no
            // amount of swiping moves it: `scrollUntilHittable` below would swipe eight times and
            // the control would still be behind it, which is exactly how both core-editor
            // walkthroughs failed on the References section header — typed into Part number, then
            // reached for a header the keyboard was sitting on. Put the keyboard away first, the
            // way a person would. A no-op when there is no keyboard up, and only ever reached on
            // a path that was otherwise going to time out.
            dismissKeyboard(in: app)
        }

        if element.isHittable == false {
            scrollUntilHittable(element, in: app)
        }

        if element.isHittable == false {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"),
                object: element
            )
            let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
            guard result == .completed else {
                XCTFail("\(description) exists but never became hittable within \(timeout)s.",
                        file: file,
                        line: line)
                return
            }
        }

        element.tap()
    }
}

// MARK: - Text entry

extension XCTestCase {

    /// Focuses a field, removes whatever is in it, and types `text`.
    ///
    /// The number of deletions is derived from the field's reported accessibility *value*, which
    /// several fields override — `CurrencyTextField` reports `"$86.50"`, the vendor window reports
    /// its clamped integer, and an empty `UITextField` reports its placeholder. That makes the
    /// count an upper bound rather than an exact length, which is fine: a delete keystroke against
    /// an already-empty field does nothing.
    func clearAndType(_ text: String,
                      into element: XCUIElement,
                      _ description: String,
                      in app: XCUIApplication,
                      file: StaticString = #filePath,
                      line: UInt = #line) {
        // Put the keyboard away before reaching for the next field.
        //
        // Tapping a second field while the first still holds the keyboard is tapping a moving
        // target: SwiftUI's keyboard avoidance is scrolling the form, and XCTest aims its
        // synthesized tap at the frame the element had when the query resolved. The tap lands
        // somewhere else, the field never takes focus, and `typeText` fails with "Neither element
        // nor any descendant has keyboard focus".
        //
        // That is exactly how both core-editor walkthroughs failed, on the hop from Part name to
        // Part number — the worst case in this app, because those two fields ask for different
        // keyboard types, so iOS is tearing down and rebuilding the keyboard at the same moment
        // the form is scrolling. The accessibility snapshot showed the field present, labelled,
        // and on screen the whole time; nothing was wrong with it or with the app.
        //
        // With no keyboard up the form is stationary, and the tap lands where the query said it
        // would.
        dismissKeyboard(in: app)

        tapWhenHittable(element, description, in: app, file: file, line: line)
        guard element.exists else { return }

        // The keyboard is the proof that the tap took focus — no field on any of these screens
        // raises one without being focused. Checked rather than assumed, and answered with one
        // bounded re-tap rather than a sleep: by now the form has finished settling, so the
        // second tap lands on a stationary field.
        if app.keyboards.firstMatch.waitForExistence(timeout: UITestTimeout.short) == false {
            element.tap()
            guard app.keyboards.firstMatch.waitForExistence(timeout: UITestTimeout.standard) else {
                XCTFail("The keyboard never appeared after tapping \(description), so there was "
                        + "nothing focused to type into.",
                        file: file,
                        line: line)
                return
            }
        }

        // One `typeText`, not two. Every extra call is another opportunity for focus to move
        // between clearing the field and refilling it.
        let reported = (element.value as? String) ?? ""
        let deletions = min(reported.count + 2, 64)
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deletions) + text)
    }

    /// Resigns the keyboard without dismissing the screen behind it.
    ///
    /// The core editor supplies its own keyboard-toolbar "Done"; the credit and batch sheets do
    /// not, and their money fields use a decimal pad with no return key. Tapping the inline
    /// navigation bar is the inert fallback — its title is not a control, so nothing is triggered.
    /// A swipe is never used here: a downward swipe on a sheet dismisses the sheet.
    func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }

        let keyboardDone = app.toolbars.buttons["Done"].firstMatch
        if keyboardDone.exists && keyboardDone.isHittable {
            keyboardDone.tap()
            return
        }

        // A sheet leaves the presenting screen's navigation bar in the tree behind it, so the
        // first *hittable* bar is the one in front rather than simply the first one found.
        for navigationBar in app.navigationBars.allElementsBoundByIndex
        where navigationBar.exists && navigationBar.isHittable {
            navigationBar.tap()
            return
        }
    }
}

// MARK: - Navigation

extension XCTestCase {

    /// Selects a top-level destination.
    ///
    /// The same identifier is applied to the tab-bar item in the compact layout and to the sidebar
    /// row in the regular one — and, because SwiftUI propagates the modifier, to the tab's *content*
    /// as well. The tab bar is therefore tried first, so a tap can never land in the middle of the
    /// screen instead of on the tab.
    func tapTab(_ identifier: String,
                in app: XCUIApplication,
                file: StaticString = #filePath,
                line: UInt = #line) {
        let title = tabTitle(for: identifier)

        // 1. Compact layout, by identifier.
        let tabButton = app.tabBars.buttons.matching(identifier: identifier).firstMatch
        if tabButton.waitForExistence(timeout: UITestTimeout.short) {
            tabButton.tap()
            return
        }

        // 2. Compact layout, by the tab's own title — the fallback for the case where SwiftUI
        //    keeps the identifier on the tab's content rather than forwarding it to the tab item.
        if let title = title {
            let titledTab = app.tabBars.buttons[title]
            if titledTab.exists {
                titledTab.tap()
                return
            }
        }

        // 3. Regular layout: the sidebar row, which carries the same identifier.
        let sidebarCell = app.cells.matching(identifier: identifier).firstMatch
        if sidebarCell.exists && sidebarCell.isHittable {
            sidebarCell.tap()
            return
        }
        if let title = title {
            let titledCell = app.cells[title]
            if titledCell.exists && titledCell.isHittable {
                titledCell.tap()
                return
            }
        }

        let sidebarButton = app.buttons.matching(identifier: identifier).firstMatch
        if sidebarButton.exists && sidebarButton.isHittable {
            sidebarButton.tap()
            return
        }

        XCTFail("No tab bar item or sidebar row carrying \"\(identifier)\" could be tapped.",
                file: file,
                line: line)
    }

    /// `AppTab.title` for a tab identifier, used only as a fallback when the identifier does not
    /// reach the tab bar item.
    private func tabTitle(for identifier: String) -> String? {
        switch identifier {
        case A11yID.Tab.dashboard: return "Dashboard"
        case A11yID.Tab.cores: return "Cores"
        case A11yID.Tab.returns: return "Returns"
        case A11yID.Tab.settings: return "Settings"
        default: return nil
        }
    }

    /// Taps an item inside an open SwiftUI `Menu`.
    func tapMenuItem(_ title: String,
                     in app: XCUIApplication,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", title)

        let menuButton = app.buttons.matching(predicate).firstMatch
        if menuButton.waitForExistence(timeout: UITestTimeout.standard) {
            menuButton.tap()
            return
        }

        let menuItem = app.menuItems.matching(predicate).firstMatch
        if menuItem.waitForExistence(timeout: UITestTimeout.short) {
            menuItem.tap()
            return
        }

        XCTFail("The menu item \"\(title)\" never appeared.", file: file, line: line)
    }

    /// Opens the detail screen for a core, tolerating a `NavigationStack` that is already there.
    ///
    /// In the compact layout each tab keeps its own stack, so returning to the Cores tab lands
    /// back on the core that was open. In the regular layout the detail column is rebuilt per
    /// destination and the row has to be tapped again.
    func openCoreDetail(titled title: String,
                        in app: XCUIApplication,
                        file: StaticString = #filePath,
                        line: UInt = #line) {
        let detailRoot = element(app, A11yID.Detail.root)
        let row = coreRow(app, titled: title)

        // Waiting on *either* also absorbs the moment right after a tab switch, when the previous
        // tab's snapshot could still answer the query.
        guard let found = indexOfFirstExisting([detailRoot, row]) else {
            XCTFail("Neither the core detail screen nor the \"\(title)\" row appeared on the "
                        + "Cores tab.",
                    file: file,
                    line: line)
            return
        }
        if found == 0 { return }

        tapWhenHittable(row, "the \"\(title)\" row in the ledger", in: app, file: file, line: line)
        requireExists(detailRoot, "the core detail screen for \"\(title)\"", file: file, line: line)
    }
}

// MARK: - Money

extension XCTestCase {

    /// Everything the accessibility layer exposes about an element, label and value together.
    ///
    /// `MoneyLabel` renders "$86.50" but publishes `accessibilityValue` as
    /// `Money.accessibilityText(currencyCode:)` — "86 US dollars and 50 cents" — while the parent
    /// supplies the label ("Money at risk"). The rendered, locale-formatted string is never exposed
    /// to XCUITest at all, which is why money assertions look for digits across both.
    func accessibilityText(of element: XCUIElement) -> String {
        let value = (element.value as? String) ?? ""
        return element.label + " " + value
    }

    /// Asserts that a money element reports every one of `digits`.
    ///
    /// Deliberately not an equality check against a formatted string. The symbol, the grouping
    /// separator, the decimal separator, and the spoken currency noun are all supplied by
    /// `Foundation` from the simulator's locale and storefront, so "$86.50" is only correct on an
    /// en_US device. The digit groups are the part of the figure the app is actually responsible
    /// for, and they survive every locale that uses Arabic numerals.
    /// The figure is re-read until it settles, so the assertion never races the SwiftData write
    /// flowing back through `@Query` into the header.
    func requireMoneyDigits(_ element: XCUIElement,
                            _ digits: [String],
                            _ description: String,
                            timeout: TimeInterval = UITestTimeout.standard,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        guard requireExists(element, description, timeout: timeout, file: file, line: line) else {
            return
        }

        var lastSeen = ""
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            lastSeen = accessibilityText(of: element)
            if digits.allSatisfy({ lastSeen.contains($0) }) { return }
        } while Date() < deadline

        XCTFail("\(description) reported \"\(lastSeen)\", which is missing one of the expected "
                    + "digit groups \(digits).",
                file: file,
                line: line)
    }
}
