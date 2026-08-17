//
//  MoneyLabel.swift
//  CoreCredit
//

import SwiftUI

/// How prominent a `MoneyLabel` should be.
enum MoneyLabelStyle {
    /// Dashboard headline figure.
    case hero
    /// Detail-screen totals and batch summaries.
    case prominent
    /// Default: list rows and form values.
    case row
    /// Supporting figures, e.g. "expected 86.50" under an actual credit.
    case caption
}

/// Renders a `Money` value.
///
/// Three rules, all of which matter more than they look:
///
/// - **Monospaced digits.** Figures line up down a column, and a value does not jitter as digits
///   change.
/// - **Never truncated.** A truncated amount is a wrong amount. The label is limited to one line
///   and scales down to 60% instead of ever showing an ellipsis.
/// - **Spoken properly.** The accessibility *value* is `Money.accessibilityText(currencyCode:)`,
///   so VoiceOver says "eighty-six dollars and fifty cents" rather than reading punctuation. The
///   label is deliberately left empty so a parent row can supply the noun ("Money at risk") and
///   the two combine into one sensible phrase.
struct MoneyLabel: View {

    private let money: Money
    private let currencyCode: String
    private let style: MoneyLabelStyle
    private let emphasizeNegative: Bool

    /// - Parameters:
    ///   - money: The amount to display.
    ///   - currencyCode: ISO code, normally `ShopProfile.currencyCode`.
    ///   - style: Visual prominence.
    ///   - emphasizeNegative: Draws negative amounts in the danger colour. Off by default, because
    ///     most figures in this app are exposure, not loss, and red must stay meaningful.
    init(
        _ money: Money,
        currencyCode: String,
        style: MoneyLabelStyle = .row,
        emphasizeNegative: Bool = false
    ) {
        self.money = money
        self.currencyCode = currencyCode
        self.style = style
        self.emphasizeNegative = emphasizeNegative
    }

    var body: some View {
        Text(money.formatted(currencyCode: currencyCode))
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.6)
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(money.accessibilityText(currencyCode: currencyCode)))
    }

    // MARK: Private

    private var font: Font {
        switch style {
        case .hero:
            return Typography.hero.monospacedDigit()
        case .prominent:
            return Font.system(.title2, design: .default, weight: .semibold).monospacedDigit()
        case .row:
            return Typography.money
        case .caption:
            return Font.system(.footnote, design: .default, weight: .medium).monospacedDigit()
        }
    }

    private var foreground: Color {
        if emphasizeNegative && money.isNegative {
            return Palette.danger
        }
        return Palette.textPrimary
    }
}

#Preview("Money labels") {
    VStack(alignment: .trailing, spacing: Spacing.l) {
        MoneyLabel(Money(cents: 1_284_650), currencyCode: "USD", style: .hero)
        MoneyLabel(Money(cents: 8650), currencyCode: "USD", style: .prominent)
        MoneyLabel(Money(cents: 8650), currencyCode: "USD")
        MoneyLabel(Money(cents: 1250), currencyCode: "USD", style: .caption)
        MoneyLabel(Money(cents: -4500), currencyCode: "USD", emphasizeNegative: true)
    }
    .padding(Spacing.l)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .background(Palette.background)
}
