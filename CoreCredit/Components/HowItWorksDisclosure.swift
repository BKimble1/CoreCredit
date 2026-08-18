//
//  HowItWorksDisclosure.swift
//  CoreCredit
//

import SwiftUI

/// The four-step explanation of how a core charge comes back, folded away until it is asked for.
///
/// # Why this is a disclosure rather than a screen block
///
/// The lesson is real and a new owner needs it, but they need it *once*. It used to be printed in
/// full on the Dashboard every time the ledger was empty — which is also what a shop sees on the
/// day it finally settles every core, so the reward for doing the work was being taught the
/// workflow again. Onboarding teaches it on first run; this is where it stays reachable
/// afterwards, closed, one tap from the empty state that would otherwise have to repeat it.
///
/// # No animation
///
/// Expanding swaps the content in without an implicit animation, so the behaviour is identical
/// with Reduce Motion on and off. The chevron is the only thing that changes shape, and it is
/// accompanied by the button's own text ("Show" / "Hide"), so the state is never carried by the
/// glyph alone.
struct HowItWorksDisclosure: View {

    @State private var isExpanded: Bool

    /// - Parameter isInitiallyExpanded: Opens the disclosure on first appearance. Defaults to
    ///   closed, which is the whole point of the component.
    init(isInitiallyExpanded: Bool = false) {
        _isExpanded = State(initialValue: isInitiallyExpanded)
    }

    /// One step of the return cycle.
    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    private static let steps: [Step] = [
        Step(id: 1,
             title: "The vendor charges you a core",
             detail: "A deposit is added to the invoice on top of the new part."),
        Step(id: 2,
             title: "You keep the old part",
             detail: "Tag it and put it in a bin so it does not walk off the shelf."),
        Step(id: 3,
             title: "You return it in time",
             detail: "Send it back before the vendor's return window closes."),
        Step(id: 4,
             title: "You confirm the credit",
             detail: "Match the credit memo against the charge. Anything short stays on your "
                 + "books until it is settled.")
    ]

    private static let title = "How CoreCredit works"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)

                    Text(HowItWorksDisclosure.title)
                        .font(Typography.sectionTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: Spacing.s)
                }
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity,
                       minHeight: Spacing.minimumTapTarget,
                       alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(HowItWorksDisclosure.title))
            .accessibilityValue(Text(isExpanded ? "Showing" : "Hidden"))
            .accessibilityHint(Text(isExpanded
                                    ? "Hides the four steps of a core return."
                                    : "Shows the four steps of a core return."))
            .accessibilityAddTraits(.isHeader)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(HowItWorksDisclosure.steps) { step in
                        stepRow(step)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surface)
        )
    }

    // MARK: Private

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(String(step.id))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Palette.onColor(for: .readyToReturn))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.accent))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(step.title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step " + String(step.id) + ". " + step.title))
        .accessibilityValue(Text(step.detail))
    }
}

#Preview("How CoreCredit works") {
    ScrollView {
        VStack(spacing: Spacing.l) {
            HowItWorksDisclosure()
            HowItWorksDisclosure(isInitiallyExpanded: true)
        }
        .padding(Spacing.l)
    }
    .background(Palette.background)
}
