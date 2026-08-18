//
//  Palette.swift
//  CoreCredit
//

import SwiftUI
import UIKit

/// The app's colour tokens.
///
/// Every token is built from an explicit light/dark pair with `UIColor`'s dynamic provider, so the
/// whole scheme is reviewable in one file and there is no asset-catalog round-trip when a value
/// changes. The only colour that also lives in `Assets.xcassets` is `AccentColor`, because the
/// system tint (navigation links, switches, the default `.tint`) is read from the catalog and
/// cannot be supplied in code. **`AccentColor.colorset` and `Palette.accent` must stay in sync.**
///
/// # Colour discipline
///
/// This is a shop tool, not a fintech dashboard. The rules are deliberately narrow:
///
/// - **Blue** (`accent`) is the app's own colour, taken from the icon. It marks the thing you can
///   act on — the filled button, the link, the focused field — and nothing else.
/// - **Amber** is the *only* warning colour, and it means "ready to return". It is reachable only
///   through `color(for:)`, so it can never be borrowed for a button.
/// - **Green** (`positive`) appears *only* on confirmed credits.
/// - **Red** (`danger`) appears *only* on overdue and disputed states.
/// - Everything else is graphite, slate, or steel.
///
/// Action and status used to be the same token: `accent` was both the primary button *and*
/// "ready to return". Splitting them is what let the light scheme be built out of the app icon
/// without spending the one colour that means a core is staged to go back.
///
/// Colour never carries meaning on its own. Every status is also drawn with its SF Symbol and its
/// text label — see `StatusBadge`.
///
/// # Both appearances are designed, not derived
///
/// Light is the primary case — a bright shop floor, a phone on a parts counter under fluorescent
/// tube lighting — but dark is a first-class scheme with its own values rather than an inversion of
/// light. The **relationship** is what is shared, and it is the thing to preserve when a value
/// changes:
///
/// | | `background` (the ground) | `surface` (a card) | `surfaceElevated` (a well *in* a card) |
/// |---|---|---|---|
/// | Light | cool grey | **white — lifted** | slightly grey — **recessed** |
/// | Dark | near-black navy | **lifted navy — lifted** | lighter navy — **raised** |
///
/// A card is separated from the ground by its own fill, in both appearances, which is why no card
/// in this app is drawn with an outline. A well inside a card moves in whichever direction iOS
/// itself moves a field well in that appearance — down in light, up in dark. Change one of these
/// and the separation has to survive: `PaletteThemeTests` measures it in both schemes rather than
/// trusting the eye of whoever edited the hex.
///
/// # Contrast
///
/// Every status colour clears 4.5:1 against `surface` — the card it is actually drawn on — in both
/// appearances, so the tinted pill treatment used by `StatusBadge` stays legible. So do
/// `textPrimary` and `textSecondary`. `textSecondary`, `hairline`, and `muted` additionally darken
/// (light) or brighten (dark) when the system's Increase Contrast setting is on. All of it is
/// measured in `PaletteThemeTests`, because "it looked fine on my screen" is not a contrast check.
enum Palette {

    // MARK: Surfaces

    /// Screen background: the ground everything sits on.
    ///
    /// In light it is the icon's blue washed almost all the way out — the same hue as `accent`,
    /// two per cent of the way from white — so the whole bright scheme reads as one family rather
    /// than as blue buttons dropped onto neutral grey. Near-black navy in dark, and deliberately
    /// *darker* than a card so the card is the thing that comes forward.
    static let background = Palette.adaptive(light: 0xE7EDFA, dark: 0x080B12)

    /// Default card / list-row background.
    ///
    /// **This is the token that replaced every card outline in the app**, so its separation from
    /// `background` is load-bearing in *both* appearances: white against cool grey in light, and a
    /// clearly lifted navy against near-black in dark. Removing the outlines without lifting this
    /// in dark would have left dark-mode cards indistinguishable from the ground.
    static let surface = Palette.adaptive(light: 0xFFFFFF, dark: 0x18202E)

    /// A well *inside* a surface — text fields, steppers, the inline vendor and bin forms.
    ///
    /// The name is historical: in dark it sits above `surface` and in light it sits very slightly
    /// below it, which is the direction iOS itself moves a field well in each appearance. Either
    /// way it is the token for "an input lives here", never for a second card.
    static let surfaceElevated = Palette.adaptive(light: 0xEEF2FB, dark: 0x222B3B)

    /// One-pixel separators between rows. No longer used as a card border — see `surface` — and
    /// deliberately faint: a separator's job is to group, and a strong line between every row of a
    /// ledger is a cage. For the edge of something a person types into, use `fieldBorder`.
    static let hairline = Palette.adaptive(
        light: 0xD3DCEC, lightHighContrast: 0xA3AFC6,
        dark: 0x2E3747, darkHighContrast: 0x51607A
    )

    /// The edge of a text field, a picker row, or any other well a person is meant to act on.
    ///
    /// Separate from `hairline` for a measured reason. WCAG 1.4.11 asks for **3:1** on the visual
    /// information needed to identify a user-interface component, and a field's edge is exactly
    /// that here: `surfaceElevated` differs from `surface` by only about 1.1:1, so the fill alone
    /// does not say "this is an input" — the border does. `hairline` reaches 1.36:1, which is right
    /// for a separator and not nearly enough for a control.
    ///
    /// These clear 3:1 against `surface` in both appearances (3.35:1 light, 3.36:1 dark). Focus and
    /// error states still override this with `accent` / `danger` *and* a thicker stroke, so neither
    /// is carried by colour alone.
    static let fieldBorder = Palette.adaptive(
        light: 0x7F8CA6, lightHighContrast: 0x56637D,
        dark: 0x62728F, darkHighContrast: 0x8B9BB8
    )

    // MARK: Text

    static let textPrimary = Palette.adaptive(light: 0x0B1220, dark: 0xF4F7FC)

    static let textSecondary = Palette.adaptive(
        light: 0x55617A, lightHighContrast: 0x3A455C,
        dark: 0xA9B4C6, darkHighContrast: 0xCCD5E1
    )

    // MARK: Semantic

    /// **The app's own blue — `#0053FD`, lifted straight out of the icon.**
    ///
    /// This is the action colour: the filled primary button, a link, a focused field, an active
    /// filter. It is *not* a status, and `color(for:)` never returns it.
    ///
    /// The light value is the icon's background exactly, unmodified, because it happens to be one
    /// of the rare vivid colours that carries text on white (5.74:1) *and* takes white text on
    /// itself (5.74:1) — so the same value works as a label and as a fill. The dark value is
    /// lifted, because the icon's blue on a near-black card is too dim to read.
    ///
    /// **`AccentColor.colorset` must match this**, or the system tint on switches and navigation
    /// links will disagree with everything drawn in code. `PaletteThemeTests` holds them together.
    static let accent = Palette.adaptive(
        light: 0x0053FD, lightHighContrast: 0x0040C4,
        dark: 0x5B93FF, darkHighContrast: 0x8AB8FF
    )

    /// A readable foreground on a solid `accent` fill — white in light, near-black in dark.
    static let onAccent = contrastForeground

    // MARK: Launch screen

    /// Asset catalog name of the flat colour iOS paints before any Swift runs. It holds the
    /// **light** value of `accent` — the icon's own blue — so the app opens in its own colour
    /// rather than on a white flash. `LaunchScreenTests` holds the two together.
    ///
    /// Deliberately fixed in both appearances: the launch screen is the app introducing itself,
    /// not a surface being read, and a brand that changed colour by time of day would be a
    /// different app twice a day.
    static let launchBackgroundAssetName = "LaunchBackground"

    /// Asset catalog name of the white mark, on a transparent square canvas.
    static let launchMarkAssetName = "LaunchMark"

    /// Green. Confirmed credits only.
    static let positive = Palette.adaptive(light: 0x1F7A45, dark: 0x3FBE7B)

    /// Red. Overdue and disputed only.
    static let danger = Palette.adaptive(light: 0xB3261E, dark: 0xFF6B60)

    /// Graphite/slate. The resting state — a core that is simply waiting.
    static let neutral = Palette.adaptive(light: 0x4A5563, dark: 0x9BA6B6)

    /// Deliberately low-energy grey for written-off records.
    static let muted = Palette.adaptive(
        light: 0x69748C, lightHighContrast: 0x505B72,
        dark: 0x8A94A3, darkHighContrast: 0xA6AFBC
    )

    // MARK: Status mapping

    /// The tint for a status. Exhaustive by design: adding a `CoreStatus` case must not compile
    /// until a colour has been chosen for it.
    static func color(for status: CoreStatus) -> Color {
        switch status {
        case .awaitingCore:
            return neutral
        case .readyToReturn:
            return readyAmber
        case .returnedAwaitingCredit:
            return steel
        case .credited:
            return positive
        case .disputed:
            return danger
        case .writtenOff:
            return muted
        }
    }

    /// A foreground colour that stays readable when `color(for:)` is used as a *solid* fill.
    ///
    /// Every status colour is dark in light mode and light in dark mode, so the answer is the same
    /// in each case today. The switch is still written out per status so that changing one status
    /// colour is a one-line change here rather than a silent contrast regression.
    static func onColor(for status: CoreStatus) -> Color {
        switch status {
        case .awaitingCore:
            return contrastForeground
        case .readyToReturn:
            return contrastForeground
        case .returnedAwaitingCredit:
            return contrastForeground
        case .credited:
            return contrastForeground
        case .disputed:
            return contrastForeground
        case .writtenOff:
            return contrastForeground
        }
    }

    // MARK: Private tokens

    /// Restrained amber, reserved for `readyToReturn`. Private, and reachable only through
    /// `color(for:)`, so "a core is staged to go back" cannot be borrowed to decorate a button —
    /// which is exactly what happened while this and `accent` were one token.
    private static let readyAmber = Palette.adaptive(light: 0x8A4F00, dark: 0xF5B23C)

    /// Cool steel, reserved for `returnedAwaitingCredit`. It has to read as "in flight" without
    /// borrowing amber (which means "act now") or green (which means "money arrived"), so it is
    /// kept private rather than exposed as a general-purpose token.
    private static let steel = Palette.adaptive(light: 0x2F5D7C, dark: 0x7FB0D0)

    /// White on light fills, near-black on dark fills. Tracks `background` in each appearance.
    private static let contrastForeground = Palette.adaptive(light: 0xFFFFFF, dark: 0x080B12)

    // MARK: Construction

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        adaptive(light: light, lightHighContrast: light, dark: dark, darkHighContrast: dark)
    }

    private static func adaptive(
        light: UInt32,
        lightHighContrast: UInt32,
        dark: UInt32,
        darkHighContrast: UInt32
    ) -> Color {
        let provider = UIColor { traits in
            let wantsHighContrast = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return Palette.uiColor(hex: wantsHighContrast ? darkHighContrast : dark)
            }
            return Palette.uiColor(hex: wantsHighContrast ? lightHighContrast : light)
        }
        return Color(uiColor: provider)
    }

    private static func uiColor(hex: UInt32) -> UIColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

// MARK: - Previews

/// Every surface and every status, so both appearances can be judged side by side.
///
/// The two previews below are the fastest way to check the thing this palette is built on: a card
/// has to be visible against the ground *without* an outline, in light and in dark. If a card ever
/// looks like it is floating on nothing in one of them, `surface` and `background` have drifted too
/// close together — and `PaletteThemeTests` will say so in numbers.
private struct PaletteSpecimen: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Surfaces")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)

                // A card, drawn exactly as the app draws one: a fill, and nothing else.
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("A card on the ground")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)

                    Text("No outline. The fill is the whole separation.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)

                    // A well inside it, with the border a real field gets.
                    Text("A field well inside the card")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                                .fill(Palette.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                                .strokeBorder(Palette.fieldBorder, lineWidth: 1)
                        )

                    Divider().overlay(Palette.hairline)

                    Text("A row separator, deliberately quieter than a field edge")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surface)
                )

                Text("Status")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(CoreStatus.allCases) { status in
                        HStack(spacing: Spacing.m) {
                            StatusBadge(status: status)
                            Spacer(minLength: Spacing.s)
                            Text(status.displayName)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.color(for: status))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surface)
                )

                Button { } label: {
                    PrimaryButtonLabel("The one filled control", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.l)
        }
        .background(Palette.background)
    }
}

#Preview("Palette — light") {
    PaletteSpecimen()
        .preferredColorScheme(.light)
}

#Preview("Palette — dark") {
    PaletteSpecimen()
        .preferredColorScheme(.dark)
}

// MARK: - Appearance

extension Palette {

    /// The `ColorScheme` to force for a chosen appearance, or `nil` to let the device decide.
    ///
    /// Lives here rather than on `AppearancePreference` because `Domain/` imports only Foundation
    /// and `ColorScheme` is SwiftUI's. This is the single place in the app that forces an
    /// appearance, and `CoreCreditApp` is its only caller.
    static func colorScheme(for preference: AppearancePreference) -> ColorScheme? {
        switch preference {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil
        }
    }
}
