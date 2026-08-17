//
//  EmptyStateView.swift
//  CoreCredit
//

import SwiftUI

/// The "nothing here yet" state for a list or a filtered result.
///
/// Written as instructions rather than decoration: a glyph, what the screen is for, and — where
/// there is an obvious next step — the button that takes it. The action is optional because an
/// empty *filter* result has no useful action, while an empty *ledger* does.
struct EmptyStateView: View {

    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - symbol: SF Symbol name, normally the one already associated with the screen.
    ///   - title: Short statement of what is missing.
    ///   - message: One or two sentences saying what to do about it.
    ///   - actionTitle: Button title. The button appears only when both this and `action` are set.
    ///   - action: Performed when the button is tapped.
    init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: symbol)
                .font(.system(.largeTitle, design: .default, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.s) {
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    PrimaryButtonLabel(actionTitle)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 320)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Empty states") {
    ScrollView {
        VStack(spacing: Spacing.xxl) {
            EmptyStateView(
                symbol: "shippingbox",
                title: "No cores tracked yet",
                message: "Add the first core charge you are waiting to get back from a vendor.",
                actionTitle: "Add a core",
                action: { }
            )
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No matches",
                message: "No cores match this search and filter combination."
            )
        }
        .padding(.vertical, Spacing.xl)
    }
    .background(Palette.background)
}
