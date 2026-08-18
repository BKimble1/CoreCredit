//
//  AccessibilityIdentifiers.swift
//  CoreCredit
//

import Foundation

/// Accessibility identifiers shared by the app and the UI test target.
///
/// These strings are a contract with `CoreCreditUITests`. Do not add, rename, or re-value a member
/// without updating the tests in the same change — a renamed identifier does not fail to compile,
/// it fails at runtime as a query that never resolves.
///
/// Identifiers are for automation only. They are never spoken: VoiceOver reads the accessibility
/// *label*, which every component sets separately.
enum A11y {

    /// The app shell, outside any one feature screen.
    enum Root {
        /// Whatever a deep link, a Shortcut, or the Action Button brought to the front. Applied by
        /// `MainTabView`'s own sheet, so a UI test waits on one identifier instead of guessing
        /// which screen answered the link.
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
        /// Opens the intake form with the scanner already in front of it.
        static let scanCore = "dashboard.scanCore"
    }

    enum Cores {
        static let root = "cores.root"
        static let list = "cores.list"
        static let addButton = "cores.add"
        static func row(_ id: UUID) -> String { "cores.row." + id.uuidString }

        // There is deliberately no `searchField` member. The ledger's search field is created by
        // SwiftUI's `.searchable` modifier, which injects it into the navigation bar; an
        // `.accessibilityIdentifier` attached to the view the modifier is applied to lands on that
        // view, never on the injected field, so no custom identifier can reach it. UI tests must
        // use `app.searchFields.firstMatch`, the supported way to a system search control.
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
        /// "Scan core" — the unified capture entry at the top of the intake form.
        static let scan = "editor.scan"
        /// The References disclosure header. Folded away while the section is empty, so a test
        /// that wants the invoice or repair-order field taps this first.
        static let referencesSection = "editor.referencesSection"
    }

    /// The unified "Scan core" surface.
    ///
    /// `root` is Live capture and `documentRoot` is Document capture — one sheet each, never both,
    /// because switching mode swaps `CoreEditorModel.Route`. Every identifier under `root` exists
    /// in all six availability states, because manual entry is present in all six.
    enum Scan {
        static let root = "scan.root"
        /// The Document half of the same surface.
        static let documentRoot = "scan.documentRoot"
        /// The Live / Document segmented control, present on both halves.
        static let modePicker = "scan.modePicker"
        /// "Open document camera", on the Document half.
        static let openDocumentCamera = "scan.openDocumentCamera"
        /// The type-it-in field.
        static let manualEntry = "scan.manualEntry"
        /// "Use this number" — accepts whatever is in `manualEntry`.
        static let useManual = "scan.useManual"
        /// "Resume scanning" on a frozen scan.
        static let resume = "scan.resume"
        /// Cancel. Carried by both halves, so it resolves whichever mode is in front.
        static let cancel = "scan.cancel"
    }

    /// The confirmation step. Shared by the live scanner, the photo read, and the document scan, so
    /// these identifiers resolve on whichever of the three is in front.
    enum ScanReview {
        static let root = "scanReview.root"
        static let apply = "scanReview.apply"
        static let retake = "scanReview.retake"
        static let cancel = "scanReview.cancel"

        /// One row per candidate, keyed on the candidate's own identifier so several rows of the
        /// same kind stay distinct.
        static func row(_ id: UUID) -> String { "scanReview.row." + id.uuidString }
    }

    enum Detail {
        static let root = "detail.root"
        static let status = "detail.status"
        static let markReady = "detail.markReady"
        static let recordCredit = "detail.recordCredit"
        static let exportPacket = "detail.exportPacket"
        static let binTag = "detail.binTag"
        /// The scanned-barcode card's two actions. The card exists only on a core that actually
        /// carries a payload, so a query resolving to nothing is a statement about the record.
        static let copyBarcode = "detail.copyBarcode"
        static let clearBarcode = "detail.clearBarcode"
    }

    enum Returns {
        static let root = "returns.root"
        /// The reference field on the create-return sheet.
        static let reference = "returns.reference"
        /// The reference field on an existing return's detail screen, while it is being edited.
        static let editReference = "returns.editReference"
        static let confirm = "returns.confirm"
        static let awaitingCredit = "returns.awaitingCredit"

        /// "Create return batch" is rendered once per ready vendor group, so the identifier is
        /// keyed on the vendor name to keep every button on the screen unique.
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
        /// The two documents a shopper is agreeing to, opened from the paywall's own footer. They
        /// present `LegalDocumentView` in a sheet, so `Legal.documentRoot` is what appears next.
        static let privacyPolicy = "paywall.privacyPolicy"
        static let termsOfUse = "paywall.termsOfUse"
        /// "Manage subscription". One identifier for both forms of the control — the in-app
        /// `AppStore.showManageSubscriptions` button and the web-page `Link` it falls back to —
        /// because only one of them is ever built.
        static let manageSubscription = "paywall.manageSubscription"
    }

    enum Settings {
        static let root = "settings.root"
        static let vendors = "settings.vendors"
        static let addVendor = "settings.addVendor"
        static let vendorName = "settings.vendorName"
        static let vendorWindow = "settings.vendorWindow"
        static let vendorSave = "settings.vendorSave"
        /// The Subscription row in the Settings list.
        static let subscription = "settings.subscription"
        /// The subscription screen that row pushes. Distinct from the row, which stays in the same
        /// `NavigationStack` behind it.
        static let subscriptionScreen = "settings.subscriptionScreen"
        static let exportCSV = "settings.exportCSV"
        /// The Scanner diagnostics row in the Settings list.
        static let diagnostics = "settings.diagnostics"
        /// The Notifications row in the Settings list. The screen it pushes is
        /// `Notifications.root`.
        static let notifications = "settings.notifications"
        /// The Appearance row in the Settings list. The screen it pushes is `Appearance.root`.
        static let appearance = "settings.appearance"
        /// The Legal row in the Settings list. The screen it pushes is `Legal.root`.
        static let legal = "settings.legal"
    }

    /// Light / Dark / Match device. One row per `AppearancePreference`, keyed on its raw value so
    /// a test can name the option it wants without depending on the order they are listed in.
    enum Appearance {
        static let root = "appearance.root"
        static func option(_ rawValue: String) -> String { "appearance.option." + rawValue }
    }

    /// The Data & export screen's restore flow. The preflight and its two actions exist only
    /// after a valid backup file has been chosen, so a query resolving to nothing is a statement
    /// about where the flow has got to.
    enum Data {
        static let restore = "data.restore"
        static let restorePreflight = "data.restorePreflight"
        static let restoreCancel = "data.restoreCancel"
    }

    /// The scanner diagnostics screen that row pushes.
    enum Diagnostics {
        static let root = "diagnostics.root"
        static let clear = "diagnostics.clear"
    }

    /// The Legal hub, its rows, and the document reader they push.
    ///
    /// `documentRoot` is deliberately one identifier for all three documents: `LegalDocumentView` is
    /// a single screen parameterised by `LegalDocumentID`, and it is also presented from the paywall,
    /// so a test waits on one thing whichever route opened it and reads the title to tell them apart.
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
    /// `enable` is there whenever a shop profile exists; `test` and `details` only while reminders
    /// are switched on; `openSettings` only while the permission is `denied`, since it is the jump
    /// to CoreCredit's page in the Settings app. A query resolving to nothing is a statement about
    /// the screen's state rather than a broken identifier.
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
