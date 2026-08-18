//
//  AppearancePreference.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — the SwiftUI mapping lives in `Palette.colorScheme(for:)`,
//  because `Domain/` may not import SwiftUI.
//

import Foundation

/// Which appearance the shop has chosen for CoreCredit, independently of the rest of the phone.
///
/// # Why the app has this at all
///
/// Most apps should simply follow the system, and CoreCredit used to. It has its own control for a
/// specific reason: the light scheme is the one built for the job. A phone left on Dark because it
/// is easier to read in bed is not making a statement about a parts counter under fluorescent
/// light, and a shop that wants the bright scheme at work should not have to change the whole
/// device to get it.
///
/// So the default is `.light` — deliberately, not by omission — and `.system` is offered for
/// anyone who would rather it follow the phone after all.
enum AppearancePreference: String, CaseIterable, Identifiable, Codable, Sendable {

    /// Always the bright scheme, whatever the phone is set to. **The default.**
    case light

    /// Always the dark scheme.
    case dark

    /// Follow the device.
    case system

    var id: String { rawValue }

    /// What a brand-new install uses.
    static let `default`: AppearancePreference = .light

    /// Order shown in Settings: the two explicit choices first, then the deferring one.
    static let displayOrder: [AppearancePreference] = [.light, .dark, .system]

    var displayName: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .system:
            return "Match device"
        }
    }

    /// One line saying what the choice actually does, for the row underneath it.
    var explanation: String {
        switch self {
        case .light:
            return "The bright scheme, whatever the phone is set to. Built for a shop floor under "
                + "the lights."
        case .dark:
            return "The dark scheme, whatever the phone is set to."
        case .system:
            return "Follows the phone's own Light or Dark setting, and changes when it does."
        }
    }

    var symbolName: String {
        switch self {
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        case .system:
            return "iphone"
        }
    }

    /// Parses a stored value, falling back to the default for anything unrecognised.
    ///
    /// Deliberately total: a preference read back from a future build, a corrupted defaults
    /// domain, or a hand-edited plist must not be able to leave the app with no appearance at all.
    static func named(_ raw: String?) -> AppearancePreference {
        guard let raw = raw, let match = AppearancePreference(rawValue: raw) else {
            return .default
        }
        return match
    }
}
