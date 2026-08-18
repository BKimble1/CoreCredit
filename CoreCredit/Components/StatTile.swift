//
//  StatTile.swift
//  CoreCredit
//

import SwiftUI

/// A single dashboard figure: a glyph, a name, a number, and optionally a line of context.
///
/// Tiles are wide and few, not a grid of small squares — the numbers here are money and they must
/// stay readable at the largest Dynamic Type sizes without truncating.
///
/// The whole tile is one accessibility element. When an `action` is supplied it also carries the
/// button trait, so VoiceOver announces "Overdue, four thousand two hundred dollars, button".
struct StatTile: View {

    private let title: String
    private let value: String
    private let symbol: String
    private let tint: Color
    private let caption: String?
    private let spokenValue: String?
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - title: What the figure measures, e.g. "Money at risk".
    ///   - value: The already-formatted figure. Format money with
    ///     `Money.formatted(currencyCode:locale:)` before passing it in.
    ///   - symbol: SF Symbol name.
    ///   - tint: Colour for the glyph and the value. Keep to `Palette`'s semantic tokens.
    ///   - caption: Supporting line, e.g. "3 cores".
    ///   - accessibilityValue: Spoken form of `value`. Pass
    ///     `Money.accessibilityText(currencyCode:)` for money so VoiceOver does not read symbols.
    ///     Falls back to `value` when omitted.
    ///   - action: Makes the tile tappable — normally a jump to the filtered list behind it.
    init(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        caption: String? = nil,
        accessibilityValue: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.tint = tint
        self.caption = caption
        self.spokenValue = accessibilityValue
        self.action = action
    }

    var body: some View {
        if let action = action {
            Button(action: action) {
                tileContent
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(resolvedSpokenValue))
            .accessibilityAddTraits(.isButton)
        } else {
            tileContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(resolvedSpokenValue))
        }
    }

    // MARK: Private

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .imageScale(.medium)
                    .foregroundStyle(tint)

                Text(title)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Text(value)
                .font(Font.system(.title2, design: .default, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let caption = caption, caption.isEmpty == false {
                Text(caption)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surface)
        )
        .contentShape(Rectangle())
    }

    private var resolvedSpokenValue: String {
        guard let spokenValue = spokenValue, spokenValue.isEmpty == false else { return value }
        return spokenValue
    }
}

#Preview("Stat tiles") {
    ScrollView {
        VStack(spacing: Spacing.m) {
            StatTile(
                title: "Money at risk",
                value: "$12,846.50",
                symbol: "dollarsign.circle",
                tint: Palette.textPrimary,
                caption: "27 cores unresolved",
                accessibilityValue: "12,846 dollars and 50 cents",
                action: { }
            )
            StatTile(
                title: "Overdue",
                value: "$4,210.00",
                symbol: "exclamationmark.circle",
                tint: Palette.danger,
                caption: "6 cores past their return window",
                accessibilityValue: "4,210 dollars"
            )
            StatTile(
                title: "Credited this month",
                value: "$8,904.25",
                symbol: "checkmark.seal",
                tint: Palette.positive
            )
        }
        .padding(Spacing.l)
    }
    .background(Palette.background)
}
