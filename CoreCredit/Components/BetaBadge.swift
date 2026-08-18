//
//  BetaBadge.swift
//  CoreCredit
//
//  A small, honest "Beta" mark.
//
//  It exists because AI Photo Assist reads photographs of greasy parts in workshop light and is
//  right most of the time rather than all of the time. A shop owner deciding how much to trust a
//  suggested part number deserves to know which parts of this app are settled and which are still
//  finding their feet, and a badge is a cheaper way to say it than a paragraph nobody reads twice.
//
//  Deliberately quiet: it labels a feature, it does not advertise one.
//

import SwiftUI

struct BetaBadge: View {

    var body: some View {
        Text("Beta")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 2)
            .background(
                Palette.surfaceElevated,
                in: RoundedRectangle(cornerRadius: Spacing.xs, style: .continuous)
            )
            .foregroundStyle(Palette.textSecondary)
            // One element with the feature's name, not a stray word after it.
            .accessibilityHidden(true)
    }
}
