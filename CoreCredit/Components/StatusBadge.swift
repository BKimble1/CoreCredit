//
//  StatusBadge.swift
//  CoreCredit
//

import SwiftUI

/// The status pill used in list rows, detail headers, and batch summaries.
///
/// Colour is never the only signal: the badge always draws the status' SF Symbol *and* its text.
/// When `isOverdue` is set it appends a second, red glyph and says "overdue" in the spoken label,
/// so an overdue core is identifiable by shape, by text, and by VoiceOver alike.
///
/// The whole badge is a single accessibility element — VoiceOver reads one phrase rather than
/// spelling out an icon and a label separately.
struct StatusBadge: View {

    private let status: CoreStatus
    private let isOverdue: Bool
    private let compact: Bool

    /// - Parameters:
    ///   - status: The core's current status.
    ///   - isOverdue: Whether the item is past its due date. Callers get this from
    ///     `RiskCalculator.isOverdue(_:now:calendar:)`; the badge does not compute it.
    ///   - compact: Uses `CoreStatus.shortName` and tighter padding, for dense list rows.
    init(status: CoreStatus, isOverdue: Bool = false, compact: Bool = false) {
        self.status = status
        self.isOverdue = isOverdue
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: status.symbolName)
                .imageScale(.small)
                .foregroundStyle(tint)

            Text(compact ? status.shortName : status.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if isOverdue {
                Image(systemName: Self.overdueSymbolName)
                    .imageScale(.small)
                    .foregroundStyle(Palette.danger)
            }
        }
        .padding(.horizontal, compact ? Spacing.s : Spacing.m)
        .padding(.vertical, compact ? Spacing.xs : Spacing.s)
        .background(
            Capsule(style: .continuous).fill(tint.opacity(0.14))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(tint.opacity(0.38), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text(status.accessibilityHint))
    }

    // MARK: Private

    /// SF Symbol for the overdue marker. Fixed by the icon table in `docs/CONTRACTS.md` §9.
    private static let overdueSymbolName = "exclamationmark.circle"

    private var tint: Color {
        Palette.color(for: status)
    }

    private var accessibilityLabelText: String {
        let name = compact ? status.shortName : status.displayName
        return isOverdue ? name + ", overdue" : name
    }
}

#Preview("Status badges") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ForEach(CoreStatus.allCases) { status in
                HStack(spacing: Spacing.m) {
                    StatusBadge(status: status)
                    StatusBadge(status: status, compact: true)
                }
            }
            StatusBadge(status: .readyToReturn, isOverdue: true)
            StatusBadge(status: .returnedAwaitingCredit, isOverdue: true, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
    }
    .background(Palette.background)
}
