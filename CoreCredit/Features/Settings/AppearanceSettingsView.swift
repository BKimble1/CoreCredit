//
//  AppearanceSettingsView.swift
//  CoreCredit
//

import SwiftUI

/// Light, Dark, or follow the phone.
///
/// One list, three rows, a checkmark on the current one — the shape iOS itself uses for a choice
/// of this kind, so nobody has to learn anything. The change applies the instant a row is tapped
/// and is written straight through to `UserDefaults`; there is no Save button on a setting whose
/// entire effect is already visible behind the sheet.
struct AppearanceSettingsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    init() { }

    var body: some View {
        List {
            Section {
                ForEach(AppearancePreference.displayOrder) { option in
                    row(for: option)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("CoreCredit opens in Light unless you change it here. The bright scheme is the "
                     + "one built for the job — a phone at a parts counter, under the lights — and "
                     + "it does not have to match how the rest of the phone is set.")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Appearance.root)
    }

    // MARK: - Rows

    private func row(for option: AppearancePreference) -> some View {
        let isSelected = appEnvironment.appearance.preference == option

        return Button {
            appEnvironment.appearance.preference = option
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: option.symbolName)
                    .imageScale(.medium)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(option.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(option.explanation)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.s)

                // The checkmark is the selection, and the accessibility trait below says so too,
                // so the current choice is never carried by a tint alone.
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Appearance.option(option.rawValue))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option.displayName))
        .accessibilityValue(Text(option.explanation))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
