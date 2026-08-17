//
//  Spacing.swift
//  CoreCredit
//

import SwiftUI

/// Layout constants.
///
/// The scale is a plain 4-point rhythm. `minimumTapTarget` is the Human Interface Guidelines floor
/// and is a hard requirement here rather than a suggestion: this app is used with dirty hands, in
/// a hurry, standing at a parts counter.
enum Spacing {
    /// 4 — hairline gaps inside a single control.
    static let xs: CGFloat = 4
    /// 8 — icon-to-label, chip padding.
    static let s: CGFloat = 8
    /// 12 — inside a card.
    static let m: CGFloat = 12
    /// 16 — screen margins, between rows.
    static let l: CGFloat = 16
    /// 24 — between card groups.
    static let xl: CGFloat = 24
    /// 32 — above and below a screen's primary section.
    static let xxl: CGFloat = 32

    /// Minimum height and width of anything tappable.
    static let minimumTapTarget: CGFloat = 44
    /// Corner radius for cards, wells, and buttons.
    static let cornerRadius: CGFloat = 12
}
