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
struct SectionCard<Content: View>: View {

    private let title: String?
    private let systemImage: String?
    private let content: Content

    /// - Parameters:
    ///   - title: Section heading. Omit for an untitled card.
    ///   - systemImage: Optional SF Symbol shown before the title. Ignored when `title` is `nil`.
    ///   - content: The card's rows.
    init(
        title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
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
        }
        .padding(Spacing.l)
    }
    .background(Palette.background)
}
