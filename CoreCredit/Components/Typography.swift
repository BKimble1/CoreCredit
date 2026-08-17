//
//  Typography.swift
//  CoreCredit
//

import SwiftUI

/// The app's type tokens.
///
/// Every token is built from a *text style* (`.largeTitle`, `.headline`, …) rather than a point
/// size, so all of it scales with Dynamic Type including the accessibility sizes. Nothing in the
/// app should call `Font.system(size:)`.
///
/// Money is always drawn with monospaced digits so figures line up column-to-column in the ledger
/// and so a value does not shimmy horizontally while it is being typed.
enum Typography {

    /// Screen-level figure — the money-at-risk headline on the dashboard.
    static let hero: Font = .system(.largeTitle, design: .rounded, weight: .bold)

    /// Default money treatment for rows and detail fields.
    static let money: Font = Font.system(.title3, design: .default, weight: .semibold).monospacedDigit()

    /// Card and section headers.
    static let sectionTitle: Font = .system(.headline, design: .default, weight: .semibold)

    /// Primary line of a list row.
    static let rowTitle: Font = .system(.body, design: .default, weight: .medium)

    /// Field labels, timestamps, and supporting copy.
    static let caption: Font = .system(.caption, design: .default, weight: .regular)
}
