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
        static let save = "editor.save"
        static let cancel = "editor.cancel"
        static let scan = "editor.scan"
    }

    enum Detail {
        static let root = "detail.root"
        static let status = "detail.status"
        static let markReady = "detail.markReady"
        static let recordCredit = "detail.recordCredit"
        static let exportPacket = "detail.exportPacket"
        static let binTag = "detail.binTag"
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
    }

    enum Onboarding {
        static let root = "onboarding.root"
        static let next = "onboarding.next"
        static let shopName = "onboarding.shopName"
        static let finish = "onboarding.finish"
        static let skip = "onboarding.skip"
    }
}
