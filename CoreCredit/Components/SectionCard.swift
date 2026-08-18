//
//  SectionCard.swift
//  CoreCredit
//

import SwiftUI

/// A titled container for a group of related rows.
///
/// One card, one idea. The app uses a small number of wide cards rather than a grid of small ones,
/// because the content here is rows of figures that need horizontal room and must never truncate.
///
/// The header is marked as an accessibility header so VoiceOver's rotor can jump between sections.
///
/// # No outline, and no card inside a card
///
/// The card is a fill and nothing else. `Palette.surface` is white in light and a lifted navy in
/// dark, which separates it from `Palette.background` on its own; a stroke on top of that is a
/// second line saying the same thing, and four of them stacked down a screen is what made this app
/// read as heavier than it is. Anything that needs to sit *inside* a card is a row with a
/// `Divider`, never a nested card — use `isPlain` when a caller has already provided the surface.
struct SectionCard<Content: View>: View {

    private let title: String?
    private let systemImage: String?
    private let isPlain: Bool
    private let content: Content

    /// - Parameters:
    ///   - title: Section heading. Omit for an untitled card.
    ///   - systemImage: Optional SF Symbol shown before the title. Ignored when `title` is `nil`.
    ///   - isPlain: Drops the fill and the padding, for a card that is already inside one. This is
    ///     how a group of rows gets a heading without becoming a second raised rectangle.
    ///   - content: The card's rows.
    init(
        title: String? = nil,
        systemImage: String? = nil,
        isPlain: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isPlain = isPlain
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let title = title {
                HStack(spacing: Spacing.s) {
                    if let systemImage = systemImage {
                        Image(systemName: systemImage)
                            .imageScale(.medium)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isPlain ? 0 : Spacing.l)
        .padding(.vertical, isPlain ? 0 : Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isPlain == false {
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.surface)
            }
        }
    }
}

#Preview("Section cards") {
    ScrollView {
        VStack(spacing: Spacing.l) {
            SectionCard(title: "Vendor", systemImage: "building.2") {
                VStack(spacing: Spacing.s) {
                    LabeledValueRow("Name", value: "NAPA Auto Parts")
                    LabeledValueRow("Return window", value: "30 days")
                    LabeledValueRow("Account", value: "88-41207", isMonospaced: true)
                }
            }

            SectionCard {
                Text("An untitled card holds anything that does not need a heading.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }

            SectionCard(title: "Plain", systemImage: "square.dashed", isPlain: true) {
                Text("A plain card is a heading and its rows, with no surface of its own.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.l)
    }
    .background(Palette.background)
}
