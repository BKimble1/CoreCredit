//
//  PaletteThemeTests.swift
//  CoreCreditTests
//
//  Both appearances, measured rather than eyeballed.
//
//  ## Why this file exists
//
//  The UX pass removed every card outline in the app on the grounds that `Palette.surface`
//  separates a card from `Palette.background` on its own. That is a claim about *numbers*, and it
//  was true in light and false in dark: the light half of the palette was retuned and the dark half
//  was left exactly as it was, so dark-mode cards lost their outline and got nothing back. Nothing
//  failed. Nothing warned. The app just looked, in one appearance out of two, like no work had been
//  done at all.
//
//  A screenshot would have caught it. There is no screenshot — this repository is built on a
//  machine with no simulator — so the design rule is written down as arithmetic instead:
//
//  1. A **card** is distinguishable from the **ground** in both appearances.
//  2. A **well** is distinguishable from the **card** in both appearances.
//  3. Every colour the app draws *on* a card clears 4.5:1 against it, in both appearances.
//  4. A **field border** clears 3:1 against a card — WCAG 1.4.11, because a field's edge is what
//     identifies it as something you can type into.
//  5. Increase Contrast never makes anything worse.
//
//  Relative luminance and contrast ratio are WCAG 2.1's own formulas, computed here rather than
//  imported, so the assertions do not depend on anything outside Foundation and UIKit.
//

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CoreCredit

@Suite("The palette works in light and in dark, by measurement")
struct PaletteThemeTests {

    // MARK: - Fixtures

    /// The appearances the app actually ships in, including the accessibility variants.
    fileprivate static let schemes: [(name: String, traits: UITraitCollection)] = [
        ("light", UITraitCollection(userInterfaceStyle: .light)),
        ("dark", UITraitCollection(userInterfaceStyle: .dark)),
        ("light + Increase Contrast", UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(accessibilityContrast: .high)
        ])),
        ("dark + Increase Contrast", UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(accessibilityContrast: .high)
        ]))
    ]

    /// Everything the app draws on top of a card.
    private static let foregrounds: [(name: String, color: Color)] = [
        ("textPrimary", Palette.textPrimary),
        ("textSecondary", Palette.textSecondary),
        ("accent", Palette.accent),
        ("positive", Palette.positive),
        ("danger", Palette.danger),
        ("neutral", Palette.neutral),
        ("muted", Palette.muted)
    ]

    // MARK: - Surfaces separate without an outline

    @Test("A card is visible against the ground in every appearance, with no border to help it")
    @MainActor
    func aCardSeparatesFromTheGround() {
        // The exact regression this file was written after: dark cards were 1.099:1 against the
        // background once their outline came off, which is a card you cannot see. 1.12 is the floor
        // that rules that out while still allowing the quiet, flat look the app is going for.
        let floor = 1.12

        for scheme in PaletteThemeTests.schemes {
            let ratio = PaletteThemeTests.contrast(Palette.surface, Palette.background, in: scheme.traits)
            #expect(ratio >= floor,
                    """
                    In \(scheme.name) a card is only \(PaletteThemeTests.rounded(ratio)):1 against the background. \
                    No card in this app is drawn with an outline, so the fill is the only thing separating it — see \
                    Palette's surface token.
                    """)
        }
    }

    @Test("A well inside a card is visible against the card")
    @MainActor
    func aWellSeparatesFromTheCard() {
        for scheme in PaletteThemeTests.schemes {
            let ratio = PaletteThemeTests.contrast(Palette.surfaceElevated, Palette.surface, in: scheme.traits)
            #expect(ratio >= 1.05,
                    """
                    In \(scheme.name) a field well is only \(PaletteThemeTests.rounded(ratio)):1 against the card it \
                    sits in.
                    """)
        }
    }

    @Test("The three surfaces are three different colours in every appearance")
    @MainActor
    func theThreeSurfacesAreDistinct() {
        for scheme in PaletteThemeTests.schemes {
            let ground = PaletteThemeTests.components(Palette.background, in: scheme.traits)
            let card = PaletteThemeTests.components(Palette.surface, in: scheme.traits)
            let well = PaletteThemeTests.components(Palette.surfaceElevated, in: scheme.traits)

            #expect(ground != card, "background and surface are the same colour in \(scheme.name).")
            #expect(card != well, "surface and surfaceElevated are the same colour in \(scheme.name).")
            #expect(ground != well, "background and surfaceElevated are the same colour in \(scheme.name).")
        }
    }

    // MARK: - Everything on a card is legible on it

    @Test("Every foreground colour clears 4.5:1 against the card it is drawn on")
    @MainActor
    func everyForegroundIsLegibleOnACard() {
        for scheme in PaletteThemeTests.schemes {
            for foreground in PaletteThemeTests.foregrounds {
                let ratio = PaletteThemeTests.contrast(foreground.color, Palette.surface, in: scheme.traits)
                #expect(ratio >= 4.5,
                        """
                        \(foreground.name) is \(PaletteThemeTests.rounded(ratio)):1 on a card in \(scheme.name), under \
                        the 4.5:1 floor for body text.
                        """)
            }
        }
    }

    @Test("Every status colour clears 4.5:1 on a card, so a badge is readable whatever it means")
    @MainActor
    func everyStatusColourIsLegibleOnACard() {
        for scheme in PaletteThemeTests.schemes {
            for status in CoreStatus.allCases {
                let ratio = PaletteThemeTests.contrast(Palette.color(for: status),
                                                      Palette.surface,
                                                      in: scheme.traits)
                #expect(ratio >= 4.5,
                        """
                        \(status.rawValue) is \(PaletteThemeTests.rounded(ratio)):1 on a card in \(scheme.name). \
                        StatusBadge draws the status colour as text and as a glyph on that card.
                        """)
            }
        }
    }

    @Test("Text on a solid status fill is readable — the primary button's own contrast")
    @MainActor
    func textOnASolidStatusFillIsReadable() {
        for scheme in PaletteThemeTests.schemes {
            for status in CoreStatus.allCases {
                let ratio = PaletteThemeTests.contrast(Palette.onColor(for: status),
                                                       Palette.color(for: status),
                                                       in: scheme.traits)
                #expect(ratio >= 4.5,
                        """
                        Foreground on a solid \(status.rawValue) fill is \(PaletteThemeTests.rounded(ratio)):1 in \
                        \(scheme.name). StatusBadge and the status tiles fill with this colour.
                        """)
            }
        }
    }

    @Test("Text on a solid accent fill is readable — the primary button's own contrast")
    @MainActor
    func textOnASolidAccentFillIsReadable() {
        // Every filled control in the app is `accent` with `onAccent` on top: Save core, Add core,
        // Apply Selected Suggestions, the numbered step circles. This is that pair, measured.
        for scheme in PaletteThemeTests.schemes {
            let ratio = PaletteThemeTests.contrast(Palette.onAccent, Palette.accent, in: scheme.traits)
            #expect(ratio >= 4.5,
                    """
                    The primary button's label is \(PaletteThemeTests.rounded(ratio)):1 on its own fill in \
                    \(scheme.name).
                    """)
        }
    }

    @Test("The action colour is not a status colour, and cannot be mistaken for one")
    @MainActor
    func theActionColourIsNotAStatusColour() {
        // These used to be one token: `accent` was the primary button *and* "ready to return".
        // Splitting them is what let the light scheme be rebuilt out of the app icon without
        // spending the colour that means a core is staged to go back. If they ever resolve to the
        // same value again, amber has quietly become a button colour a second time.
        for scheme in PaletteThemeTests.schemes {
            for status in CoreStatus.allCases {
                let statusColour = PaletteThemeTests.components(Palette.color(for: status),
                                                               in: scheme.traits)
                let action = PaletteThemeTests.components(Palette.accent, in: scheme.traits)
                #expect(statusColour != action,
                        """
                        \(status.rawValue) resolves to the same colour as the action accent in \(scheme.name).
                        """)
            }
        }
    }

    // MARK: - Controls announce themselves

    @Test("A field border clears 3:1 on a card, and a separator stays quieter than one")
    @MainActor
    func aFieldBorderIsStrongEnoughToIdentifyAControl() {
        for scheme in PaletteThemeTests.schemes {
            let border = PaletteThemeTests.contrast(Palette.fieldBorder, Palette.surface, in: scheme.traits)
            #expect(border >= 3.0,
                    """
                    The field border is \(PaletteThemeTests.rounded(border)):1 on a card in \(scheme.name), under \
                    WCAG 1.4.11's 3:1 for the edge that identifies an input.
                    """)

            // And the two tokens have not collapsed into each other: a row separator drawn as
            // heavily as a text field would put the ledger back in a cage.
            let separator = PaletteThemeTests.contrast(Palette.hairline, Palette.surface, in: scheme.traits)
            #expect(separator < border,
                    """
                    In \(scheme.name) the row separator (\(PaletteThemeTests.rounded(separator)):1) is no lighter \
                    than a field border (\(PaletteThemeTests.rounded(border)):1).
                    """)
        }
    }

    // MARK: - Increase Contrast only ever helps

    @Test("Increase Contrast never makes a colour harder to read")
    @MainActor
    func increaseContrastNeverMakesThingsWorse() {
        let pairs: [(String, UITraitCollection, UITraitCollection)] = [
            ("light", PaletteThemeTests.schemes[0].traits, PaletteThemeTests.schemes[2].traits),
            ("dark", PaletteThemeTests.schemes[1].traits, PaletteThemeTests.schemes[3].traits)
        ]

        for (name, normal, high) in pairs {
            for foreground in PaletteThemeTests.foregrounds {
                let plain = PaletteThemeTests.contrast(foreground.color, Palette.surface, in: normal)
                let boosted = PaletteThemeTests.contrast(foreground.color, Palette.surface, in: high)
                // Equal is fine — most tokens have no high-contrast variant and are legible as they
                // are. Going *down* would mean a variant was tuned in the wrong direction.
                #expect(boosted >= plain - 0.01,
                        """
                        \(foreground.name) drops from \(PaletteThemeTests.rounded(plain)):1 to \
                        \(PaletteThemeTests.rounded(boosted)):1 in \(name) when Increase Contrast is switched on.
                        """)
            }
        }
    }

    // MARK: - The system tint agrees with the code

    @Test("AccentColor.colorset matches Palette.accent, so the system tint agrees with the app")
    @MainActor
    func theAssetCatalogAccentMatchesTheCodeAccent() throws {
        // The tint on a Toggle, a NavigationLink chevron, and a system control is read from the
        // asset catalog and cannot be supplied in code; everything drawn by hand reads
        // `Palette.accent`. They are two copies of one decision, and nothing but a test notices
        // when they stop agreeing — the app simply ends up with two slightly different blues in it.
        let asset = try #require(UIColor(named: "AccentColor"))

        for scheme in PaletteThemeTests.schemes {
            let fromCatalog = PaletteThemeTests.componentsOf(asset, in: scheme.traits)
            let fromCode = PaletteThemeTests.components(Palette.accent, in: scheme.traits)
            #expect(PaletteThemeTests.isSameColour(fromCatalog, fromCode),
                    "AccentColor.colorset and Palette.accent disagree in \(scheme.name).")
        }
    }

    // MARK: - Both appearances are actually designed

    @Test("Light and dark are different schemes, not one scheme rendered twice")
    @MainActor
    func lightAndDarkAreGenuinelyDifferent() {
        let light = PaletteThemeTests.schemes[0].traits
        let dark = PaletteThemeTests.schemes[1].traits

        let tokens: [(String, Color)] = [
            ("background", Palette.background),
            ("surface", Palette.surface),
            ("surfaceElevated", Palette.surfaceElevated),
            ("hairline", Palette.hairline),
            ("fieldBorder", Palette.fieldBorder),
            ("textPrimary", Palette.textPrimary),
            ("textSecondary", Palette.textSecondary)
        ] + PaletteThemeTests.foregrounds.filter { $0.name != "textPrimary" && $0.name != "textSecondary" }
            .map { ($0.name, $0.color) }

        for (name, color) in tokens {
            let inLight = PaletteThemeTests.components(color, in: light)
            let inDark = PaletteThemeTests.components(color, in: dark)
            #expect(inLight != inDark,
                    """
                    \(name) is the same colour in light and dark. Every token in this palette is an explicit pair; \
                    one that resolves identically is a value somebody forgot to give a second half.
                    """)
        }

        // And the schemes run in opposite directions: a card is lighter than the ground in light,
        // and lighter than the ground in dark too — but the ground itself flips.
        let lightGround = PaletteThemeTests.luminance(Palette.background, in: light)
        let darkGround = PaletteThemeTests.luminance(Palette.background, in: dark)
        #expect(lightGround > 0.5, "The light scheme's ground should be light.")
        #expect(darkGround < 0.1, "The dark scheme's ground should be dark.")
    }

    // MARK: - Measurement

    @MainActor
    fileprivate static func components(_ color: Color, in traits: UITraitCollection) -> [CGFloat] {
        componentsOf(UIColor(color), in: traits)
    }

    @MainActor
    fileprivate static func componentsOf(_ color: UIColor,
                                         in traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    /// Small tolerance: the asset catalog round-trips its components through a stored sRGB
    /// representation and a hand-written `Color` does not, so the last bit of a channel is not
    /// something to hold anybody to.
    fileprivate static func isSameColour(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where abs(left - right) > 0.01 {
            return false
        }
        return true
    }

    /// WCAG 2.1 relative luminance.
    @MainActor
    private static func luminance(_ color: Color, in traits: UITraitCollection) -> CGFloat {
        let parts = components(color, in: traits)
        let linear = parts.prefix(3).map { channel -> CGFloat in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    /// WCAG 2.1 contrast ratio, always >= 1 whichever way round the two are passed.
    @MainActor
    private static func contrast(_ lhs: Color, _ rhs: Color, in traits: UITraitCollection) -> CGFloat {
        let a = luminance(lhs, in: traits)
        let b = luminance(rhs, in: traits)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Two decimal places, for a failure message somebody has to act on.
    private static func rounded(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
