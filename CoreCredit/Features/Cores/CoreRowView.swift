//
//  CoreRowView.swift
//  CoreCredit
//

import SwiftUI

/// One core in a list: what it is, who owes for it, how much, where it is in the cycle, and how
/// long is left.
///
/// The row never reads the clock — `now` and `calendar` are handed in from
/// `AppEnvironment.dateProvider`, so the same row renders identically in the app and under a frozen
/// test clock.
///
/// Three deliberate choices:
///
/// - **Money on the trailing edge**, monospaced through `MoneyLabel`, so a column of amounts lines
///   up and can be scanned without reading.
/// - **Status by badge, deadline by words.** `StatusBadge` already carries icon plus text; the
///   deadline line adds its own glyph, so "12 days overdue" is legible with the colour ignored.
/// - **Stacks vertically at accessibility text sizes** rather than squeezing an amount next to a
///   part name — a truncated amount is a wrong amount.
struct CoreRowView: View {

    private let item: CoreItem
    private let currencyCode: String
    private let now: Date
    private let calendar: Calendar

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - item: The core to render.
    ///   - currencyCode: `ShopProfile.currencyCode`.
    ///   - now: `AppEnvironment.dateProvider.now`.
    ///   - calendar: `AppEnvironment.dateProvider.calendar`.
    init(item: CoreItem, currencyCode: String, now: Date, calendar: Calendar) {
        self.item = item
        self.currencyCode = currencyCode
        self.now = now
        self.calendar = calendar
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    titleBlock
                    MoneyLabel(item.expectedCredit, currencyCode: currencyCode)
                    statusBlock
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        titleBlock
                        Spacer(minLength: Spacing.s)
                        MoneyLabel(item.expectedCredit, currencyCode: currencyCode)
                    }
                    statusBlock
                }
            }
        }
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityValue(Text(accessibilityValueText))
        .accessibilityIdentifier(A11y.Cores.row(item.id))
    }

    // MARK: - Pieces

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(item.displayTitle)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBlock: some View {
        HStack(spacing: Spacing.s) {
            StatusBadge(status: item.status, isOverdue: isOverdue, compact: true)

            HStack(spacing: Spacing.xs) {
                Image(systemName: deadline.symbol)
                    .imageScale(.small)
                Text(deadline.text)
                    .font(Typography.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(deadline.tint)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Text

    private var subtitle: String {
        var parts: [String] = [item.vendorName ?? "No vendor"]

        let number = item.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !number.isEmpty { parts.append(number) }

        if let bin = item.binLabel { parts.append("Bin " + bin) }

        return parts.joined(separator: " • ")
    }

    private var isOverdue: Bool {
        RiskCalculator.isOverdue(item, now: now, calendar: calendar)
    }

    /// The deadline or age line, with the glyph and tint that go with it.
    ///
    /// Amber means "act soon", red means "already late", grey means "nothing to do yet" — and every
    /// one of them is spelled out in words as well.
    private var deadline: DeadlineLine {
        if item.status.isClosed {
            let age = RiskCalculator.ageInDays(item, now: now, calendar: calendar)
            let verb = item.status == .credited ? "Credited " : "Closed "
            return DeadlineLine(
                text: verb + CoreRowView.agoPhrase(age),
                symbol: item.status.symbolName,
                tint: Palette.textSecondary
            )
        }

        if let days = RiskCalculator.daysUntilDue(item, now: now, calendar: calendar) {
            if days < 0 {
                return DeadlineLine(
                    text: CoreRowView.dayCount(-days) + " overdue",
                    symbol: "exclamationmark.circle",
                    tint: Palette.danger
                )
            }
            if days == 0 {
                return DeadlineLine(text: "Due today", symbol: "clock", tint: Palette.accent)
            }
            if days == 1 {
                return DeadlineLine(text: "Due tomorrow", symbol: "clock", tint: Palette.accent)
            }
            let text = "Due in " + CoreRowView.dayCount(days)
            if days <= CoreRowView.soonThresholdDays {
                return DeadlineLine(text: text, symbol: "clock", tint: Palette.accent)
            }
            return DeadlineLine(text: text, symbol: "calendar", tint: Palette.textSecondary)
        }

        let age = RiskCalculator.ageInDays(item, now: now, calendar: calendar)
        return DeadlineLine(
            text: "Received " + CoreRowView.agoPhrase(age),
            symbol: "calendar",
            tint: Palette.textSecondary
        )
    }

    private var accessibilityLabelText: String {
        item.displayTitle + ", " + subtitle
    }

    private var accessibilityValueText: String {
        var parts = [item.expectedCredit.accessibilityText(currencyCode: currencyCode)]
        parts.append(isOverdue ? item.status.displayName + ", overdue" : item.status.displayName)
        parts.append(deadline.text)
        return parts.joined(separator: ", ")
    }

    // MARK: - Constants and helpers

    /// A deadline inside this many days is drawn in amber: it is the last chance to get the core
    /// on the truck without a phone call.
    private static let soonThresholdDays = 3

    private static func dayCount(_ days: Int) -> String {
        days == 1 ? "1 day" : String(days) + " days"
    }

    private static func agoPhrase(_ days: Int) -> String {
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return String(days) + " days ago"
    }
}

/// One line of deadline copy plus the glyph and tint that carry the same meaning without colour.
private struct DeadlineLine {
    var text: String
    var symbol: String
    var tint: Color
}
