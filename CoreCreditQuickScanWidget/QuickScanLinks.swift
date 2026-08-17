//
//  QuickScanLinks.swift
//  CoreCreditQuickScanWidget
//
//  The one place the widget extension knows about the host app's URL scheme.
//

import Foundation

/// Deep links the Quick Scan widget can open.
///
/// The widget extension is a separate binary and cannot import the app module, so it cannot see
/// `AppConfiguration`. The scheme is therefore duplicated here on purpose. Anyone changing the
/// scheme must change it in three places: `AppConfiguration.urlScheme`, the `CFBundleURLSchemes`
/// entry in `Config/CoreCredit-Info.plist`, and this file.
enum QuickScanLinks {

    /// Must stay in step with `AppConfiguration.urlScheme` in the app target. The widget
    /// extension cannot import the app module, so the string is duplicated deliberately.
    static let scheme = "corecredit"

    /// Opens the app's scanner to start a new core. The host is `scan`; the app routes it in
    /// its `onOpenURL` handler alongside the bare scheme and the `item` bin-tag links.
    static let scanURLString = "corecredit://scan"

    /// Non-optional so views never force-unwrap. The fallback mirrors `AppConfiguration.fallbackURL`
    /// in the app target: a harmless, obviously wrong URL, chosen so a mistyped literal above shows
    /// up as a widget that does nothing rather than as a crash.
    static var scanURL: URL { URL(string: scanURLString) ?? URL(fileURLWithPath: "/") }
}
