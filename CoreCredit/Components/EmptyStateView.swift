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
///
/// # One sentence, not a lesson
///
/// `message` is **one sentence naming the next useful action**, and nothing else. The four-step
/// explanation of how a core charge comes back is a real thing a new owner needs, but they need it
/// once — it lives in onboarding and in `HowItWorksDisclosure`, not on every visit to an empty
/// screen. A shop that has emptied its ledger by settling every core does not want to be taught
/// the workflow again.
struct EmptyStateView: View {

    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let actionIdentifier: String?
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - symbol: SF Symbol name, normally the one already associated with the screen.
    ///   - title: Short statement of what is missing.
    ///   - message: One sentence saying what to do about it.
    ///   - actionTitle: Button title. The button appears only when both this and `action` are set.
    ///   - actionIdentifier: Accessibility identifier for that button, when a screen's contract
    ///     names it — the Dashboard's `dashboard.addCore`, for instance, which is the same action
    ///     whether the ledger is empty or full and must keep one identifier either way.
    ///   - action: Performed when the button is tapped.
    init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        actionIdentifier: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionIdentifier = actionIdentifier
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(.title, design: .default, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.xs) {
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

            actionButton
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// The single primary action, when the screen has one.
    ///
    /// The identifier is applied only when a caller supplied one. Writing an empty string instead
    /// would clear whatever identifier the enclosing screen had propagated down, which is a
    /// different — and silent — change to make to every empty state in the app.
    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle = actionTitle, let action = action {
            let button = Button(action: action) {
                PrimaryButtonLabel(actionTitle)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 320)
            .padding(.top, Spacing.xs)

            if let actionIdentifier = actionIdentifier, actionIdentifier.isEmpty == false {
                button.accessibilityIdentifier(actionIdentifier)
            } else {
                button
            }
        }
    }
}

#Preview("Empty states") {
    ScrollView {
        VStack(spacing: Spacing.xxl) {
            EmptyStateView(
                symbol: "shippingbox",
                title: "No cores yet",
                message: "Log your first core charge, return deadline, and expected credit.",
                actionTitle: "Add core",
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
