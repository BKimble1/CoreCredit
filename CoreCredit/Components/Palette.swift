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
/// - **Amber** (`accent`) is the *only* warning colour, and it means "ready to return".
/// - **Green** (`positive`) appears *only* on confirmed credits.
/// - **Red** (`danger`) appears *only* on overdue and disputed states.
/// - Everything else is graphite, slate, or steel.
///
/// Colour never carries meaning on its own. Every status is also drawn with its SF Symbol and its
/// text label — see `StatusBadge`.
///
/// # Contrast
///
/// Each light-mode status colour clears 4.5:1 against white, and each dark-mode status colour
/// clears 4.5:1 against `background`, so the tinted pill treatment used by `StatusBadge` stays
/// legible. `textSecondary`, `hairline`, and `muted` additionally darken (light) or brighten
/// (dark) when the system's Increase Contrast setting is on.
enum Palette {

    // MARK: Surfaces

    /// Screen background: near-black navy in dark, cool off-white in light.
    ///
    /// Light is the bright-shop-floor case and is treated as the primary one. The value is the
    /// cool grey iOS uses behind an inset-grouped list, so a `SectionCard` sitting on it reads the
    /// way a settings row does rather than like a floating panel.
    static let background = Palette.adaptive(light: 0xEDEFF3, dark: 0x0B0E14)

    /// Default card / list-row background.
    ///
    /// White in light, so the separation from `background` comes from the surface itself and a
    /// card needs no outline drawn round it. Cards are no longer stroked anywhere in the app.
    static let surface = Palette.adaptive(light: 0xFFFFFF, dark: 0x141924)

    /// A well *inside* a surface — text fields, steppers, the inline vendor and bin forms.
    ///
    /// The name is historical: in dark it sits above `surface` and in light it sits very slightly
    /// below it, which is the direction iOS itself moves a field well in each appearance. Either
    /// way it is the token for "an input lives here", never for a second card.
    static let surfaceElevated = Palette.adaptive(light: 0xF1F3F7, dark: 0x1E2532)

    /// One-pixel separators. No longer used as a card border — see `surface`.
    static let hairline = Palette.adaptive(
        light: 0xD9DDE4, lightHighContrast: 0xA9B0BC,
        dark: 0x2B3341, darkHighContrast: 0x4A5566
    )

    // MARK: Text

    static let textPrimary = Palette.adaptive(light: 0x0E1420, dark: 0xF2F5FA)

    static let textSecondary = Palette.adaptive(
        light: 0x5B6575, lightHighContrast: 0x3E4756,
        dark: 0xA3AEC0, darkHighContrast: 0xC7D0DD
    )

    // MARK: Semantic

    /// Restrained amber. Warnings and "ready to return" only — never decoration.
    static let accent = Palette.adaptive(light: 0x8A4F00, dark: 0xF5B23C)

    /// Green. Confirmed credits only.
    static let positive = Palette.adaptive(light: 0x1F7A45, dark: 0x3FBE7B)

    /// Red. Overdue and disputed only.
    static let danger = Palette.adaptive(light: 0xB3261E, dark: 0xFF6B60)

    /// Graphite/slate. The resting state — a core that is simply waiting.
    static let neutral = Palette.adaptive(light: 0x4A5563, dark: 0x9BA6B6)

    /// Deliberately low-energy grey for written-off records.
    static let muted = Palette.adaptive(
        light: 0x6B7280, lightHighContrast: 0x515966,
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
            return accent
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

    /// Cool steel, reserved for `returnedAwaitingCredit`. It has to read as "in flight" without
    /// borrowing amber (which means "act now") or green (which means "money arrived"), so it is
    /// kept private rather than exposed as a general-purpose token.
    private static let steel = Palette.adaptive(light: 0x2F5D7C, dark: 0x7FB0D0)

    /// White on light fills, near-black on dark fills.
    private static let contrastForeground = Palette.adaptive(light: 0xFFFFFF, dark: 0x0B0E14)

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
