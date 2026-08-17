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

/// Verbatim copy of the app's `A11y` strings. Only the members the tests actually query are here,
/// and each one is copied character for character — a mirror member whose value has drifted from
/// the app's is a query that resolves to nothing rather than a build failure.
enum A11yID {

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
        static let invoice = "editor.invoice"
        static let repairOrder = "editor.repairOrder"
        static let save = "editor.save"
        static let cancel = "editor.cancel"
        // `editor.scan` is deliberately absent: it opens the camera-backed scan sheet, and the
        // brief forbids any test depending on camera permission. Manual entry only.
    }

    enum Detail {
        static let root = "detail.root"
        static let status = "detail.status"
        static let markReady = "detail.markReady"
        static let recordCredit = "detail.recordCredit"
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
    }

    enum Settings {
        static let root = "settings.root"
        static let vendors = "settings.vendors"
        static let addVendor = "settings.addVendor"
        static let vendorName = "settings.vendorName"
        static let vendorWindow = "settings.vendorWindow"
        static let vendorSave = "settings.vendorSave"
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
    func launchApp(seed: UITestSeed = .empty,
                   tier: UITestTier? = .free,
                   skipOnboarding: Bool = true,
                   storeKitFailure: Bool = false,
                   scannerPayload: String? = nil,
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
    @discardableResult
    func scrollUntilHittable(_ element: XCUIElement,
                             in app: XCUIApplication,
                             maxSwipes: Int = 8) -> Bool {
        var remaining = maxSwipes
        while remaining > 0 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
            remaining -= 1
        }
        return element.exists && element.isHittable
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
        tapWhenHittable(element, description, in: app, file: file, line: line)
        guard element.exists else { return }

        let reported = (element.value as? String) ?? ""
        let deletions = min(reported.count + 2, 64)
        if deletions > 0 {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deletions))
        }
        element.typeText(text)
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
