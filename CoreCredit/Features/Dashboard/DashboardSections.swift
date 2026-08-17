//
//  DashboardSections.swift
//  CoreCredit
//
//  The three presentational blocks the dashboard is assembled from. None of them reads the clock,
//  fetches anything, or mutates anything — they render a `RiskSummary` that `DashboardView`
//  already computed through `RiskCalculator`.
//

import SwiftUI

/// "1 core" / "4 cores". Duplicated per file on purpose so no new shared symbol enters the module.
private func coreCountPhrase(_ count: Int) -> String {
    count == 1 ? "1 core" : String(count) + " cores"
}

// MARK: - MoneyAtRiskHeader

/// The headline of the whole app: how much core-credit money is still outstanding, and how much of
/// it is already late.
///
/// The total is drawn with `MoneyLabel` at `.hero` — monospaced, never truncated, and spoken as
/// words rather than punctuation. The overdue figure sits directly beneath it as a `StatTile`
/// tinted `Palette.danger`, which puts the red on the number itself; the warning glyph and the
/// caption carry the same meaning without colour, so a red-blind owner reads it just as fast.
struct MoneyAtRiskHeader: View {

    private let summary: RiskSummary
    private let currencyCode: String

    /// - Parameters:
    ///   - summary: Already computed by `RiskCalculator.summarize(_:now:calendar:)`.
    ///   - currencyCode: `ShopProfile.currencyCode`.
    init(summary: RiskSummary, currencyCode: String) {
        self.summary = summary
        self.currencyCode = currencyCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            headlineCard
            overdueTile
        }
    }

    // MARK: Private

    private var headlineCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "dollarsign.circle")
                    .imageScale(.medium)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                Text("Money at risk")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MoneyLabel(summary.moneyAtRisk, currencyCode: currencyCode, style: .hero)
                .accessibilityLabel(Text("Money at risk"))
                .accessibilityIdentifier(A11y.Dashboard.moneyAtRisk)

            Text(openText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private var overdueTile: some View {
        StatTile(
            title: "Overdue",
            value: summary.overdueAmount.formatted(currencyCode: currencyCode),
            symbol: "exclamationmark.circle",
            tint: summary.overdueCount > 0 ? Palette.danger : Palette.textSecondary,
            caption: overdueCaption,
            accessibilityValue: overdueSpokenValue
        )
        .accessibilityIdentifier(A11y.Dashboard.overdueAmount)
    }

    private var openText: String {
        if summary.unresolvedCount == 0 {
            return "Nothing is open. Every core has been credited or written off."
        }
        return coreCountPhrase(summary.unresolvedCount) + " still open with a vendor."
    }

    private var overdueCaption: String {
        if summary.overdueCount == 0 {
            return "Nothing is past its return window."
        }
        return coreCountPhrase(summary.overdueCount) + " past the return window."
    }

    private var overdueSpokenValue: String {
        let amount = summary.overdueAmount.accessibilityText(currencyCode: currencyCode)
        if summary.overdueCount == 0 {
            return amount + ", nothing past its return window"
        }
        return amount + ", " + coreCountPhrase(summary.overdueCount) + " past the return window"
    }
}

// MARK: - StatusCardGrid

/// One tappable tile per unresolved status, each showing the money and the count behind it.
///
/// The destination is supplied by the caller so this stays free of navigation assumptions: on the
/// dashboard each tile pushes the Cores list pre-filtered to that status. Tiles are wide, one or
/// two per row — never a grid of small squares — and collapse to a single column at accessibility
/// text sizes so a figure never has to shrink to fit.
struct StatusCardGrid<Destination: View>: View {

    private let summary: RiskSummary
    private let currencyCode: String
    private let destination: (CoreStatus) -> Destination

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// - Parameters:
    ///   - summary: Already computed by `RiskCalculator.summarize(_:now:calendar:)`.
    ///   - currencyCode: `ShopProfile.currencyCode`.
    ///   - destination: The screen a tile opens, built for the tapped status.
    init(summary: RiskSummary,
         currencyCode: String,
         @ViewBuilder destination: @escaping (CoreStatus) -> Destination) {
        self.summary = summary
        self.currencyCode = currencyCode
        self.destination = destination
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.m) {
            ForEach(statuses) { status in
                NavigationLink {
                    destination(status)
                } label: {
                    tile(for: status)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Private

    /// Only the statuses that still represent money the shop has not got back. `credited` and
    /// `writtenOff` are settled and deliberately absent — this grid answers "where is my money",
    /// not "what has this shop ever handled".
    ///
    /// Computed rather than `static` because static stored properties are not allowed in a generic
    /// type.
    private var statuses: [CoreStatus] {
        CoreStatus.unresolvedCases
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize || horizontalSizeClass != .regular {
            return [GridItem(.flexible(), spacing: Spacing.m)]
        }
        return [
            GridItem(.flexible(), spacing: Spacing.m),
            GridItem(.flexible(), spacing: Spacing.m)
        ]
    }

    private func tile(for status: CoreStatus) -> some View {
        StatTile(
            title: status.displayName,
            value: summary.amount(for: status).formatted(currencyCode: currencyCode),
            symbol: status.symbolName,
            tint: Palette.color(for: status),
            caption: coreCountPhrase(summary.count(for: status)),
            accessibilityValue: spokenValue(for: status)
        )
    }

    private func spokenValue(for status: CoreStatus) -> String {
        let amount = summary.amount(for: status).accessibilityText(currencyCode: currencyCode)
        return coreCountPhrase(summary.count(for: status)) + ", " + amount
    }
}

// MARK: - AgingBucketRow

/// One aging band — 0–7, 8–30, or 31+ days — with the money and the count sitting in it.
///
/// Presentational only. The dashboard wraps it in a `NavigationLink`, which is what supplies the
/// button trait; the row itself is a single accessibility element so VoiceOver reads
/// "8 to 30 days, 3 cores, four hundred and twelve dollars" as one phrase.
struct AgingBucketRow: View {

    private let summary: AgingBucketSummary
    private let currencyCode: String
    private let showsDisclosure: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - summary: One entry from `RiskSummary.agingBuckets`.
    ///   - currencyCode: `ShopProfile.currencyCode`.
    ///   - showsDisclosure: Draws the chevron. Turn it off when the row is not tappable.
    init(summary: AgingBucketSummary, currencyCode: String, showsDisclosure: Bool = true) {
        self.summary = summary
        self.currencyCode = currencyCode
        self.showsDisclosure = showsDisclosure
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    labelBlock
                    MoneyLabel(summary.amount, currencyCode: currencyCode)
                }
            } else {
                HStack(spacing: Spacing.m) {
                    labelBlock
                    Spacer(minLength: Spacing.s)
                    MoneyLabel(summary.amount, currencyCode: currencyCode)
                    if showsDisclosure {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary.bucket.displayName))
        .accessibilityValue(Text(spokenValue))
    }

    // MARK: Private

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(summary.bucket.displayName)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(coreCountPhrase(summary.count))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var spokenValue: String {
        coreCountPhrase(summary.count)
            + ", "
            + summary.amount.accessibilityText(currencyCode: currencyCode)
    }
}
