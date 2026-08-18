//
//  CurrencyTextField.swift
//  CoreCredit
//

import SwiftUI

/// A money entry well: currency symbol on the left, right-aligned monospaced figure on the right.
///
/// The field binds to a plain `String` and **never parses**. Parsing is the caller's job via
/// `Money.parse(_:locale:)`, so validation, error text, and the parsed value all stay in one place
/// (the editor's model) rather than being split between the model and a text field.
///
/// Errors are shown beneath the field with a glyph as well as red text, and the well's border
/// thickens, so the error state survives a colour-blind user, a greyscale screenshot, and a sunlit
/// parts counter.
struct CurrencyTextField: View {

    private let title: String
    @Binding private var text: String
    private let currencySymbol: String
    private let errorMessage: String?
    private let focusHint: String?
    private let fieldIdentifier: String?

    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - title: Field label, e.g. "Expected credit".
    ///   - text: Raw user text. Parse it with `Money.parse(_:locale:)`.
    ///   - currencyCode: ISO code used to look up the leading symbol.
    ///   - errorMessage: Validation message to show beneath the field. `nil` or empty hides it.
    ///   - focusHint: Supporting sentence shown when there is no error, and used as the
    ///     VoiceOver hint, e.g. "The core charge printed on the invoice."
    ///   - fieldIdentifier: Accessibility identifier for the inner `TextField`. Applying it here
    ///     rather than to the whole component is what makes the money entry resolve as a text
    ///     field in UI tests; the composed view is a `VStack`, which would not.
    init(
        title: String,
        text: Binding<String>,
        currencyCode: String,
        errorMessage: String? = nil,
        focusHint: String? = nil,
        fieldIdentifier: String? = nil
    ) {
        self.title = title
        self._text = text
        self.currencySymbol = Self.symbol(forCurrencyCode: currencyCode)
        self.errorMessage = errorMessage
        self.focusHint = focusHint
        self.fieldIdentifier = fieldIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            HStack(spacing: Spacing.s) {
                Text(currencySymbol)
                    .font(Typography.money)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)

                field
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Spacing.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }

            if hasError {
                FormErrorText(errorMessage)
            } else if let focusHint = focusHint, focusHint.isEmpty == false {
                Text(focusHint)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Private

    /// The real entry field. The caller's identifier is applied here rather than to the composed
    /// `VStack`, so `app.textFields[identifier]` resolves in UI tests.
    @ViewBuilder
    private var field: some View {
        let base = TextField("0.00", text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .font(Typography.money)
            .foregroundStyle(Palette.textPrimary)
            .focused($isFocused)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(spokenValue))
            .accessibilityHint(Text(spokenHint))

        if let fieldIdentifier = fieldIdentifier {
            base.accessibilityIdentifier(fieldIdentifier)
        } else {
            base
        }
    }

    private var hasError: Bool {
        guard let errorMessage = errorMessage else { return false }
        return errorMessage.isEmpty == false
    }

    private var borderColor: Color {
        if hasError { return Palette.danger }
        return isFocused ? Palette.accent : Palette.fieldBorder
    }

    /// The error and focused states thicken the border, so neither depends on colour alone.
    private var borderWidth: CGFloat {
        (hasError || isFocused) ? 2 : 1
    }

    /// Spoken form of the current entry. VoiceOver reads an empty field as "Empty" rather than
    /// silently skipping the value.
    private var spokenValue: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Empty" }
        return currencySymbol + trimmed
    }

    /// The error takes priority over the hint, because a user who has just failed validation needs
    /// to hear why before they hear guidance.
    private var spokenHint: String {
        if let errorMessage = errorMessage, errorMessage.isEmpty == false {
            return errorMessage
        }
        return focusHint ?? ""
    }

    /// Looks up the display symbol for an ISO currency code, falling back to the code itself
    /// (which is what a shop entering an unusual currency would rather see than a blank).
    private static func symbol(forCurrencyCode code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let resolved: String? = formatter.currencySymbol
        if let resolved = resolved, resolved.isEmpty == false {
            return resolved
        }
        return code
    }
}

/// Preview host so the field is actually typable in the canvas.
private struct CurrencyTextFieldPreviewHost: View {
    @State private var good = "86.50"
    @State private var bad = "eighty six"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            CurrencyTextField(
                title: "Expected credit",
                text: $good,
                currencyCode: "USD",
                focusHint: "The core charge printed on the invoice."
            )
            CurrencyTextField(
                title: "Expected credit",
                text: $bad,
                currencyCode: "USD",
                errorMessage: "Enter the core charge, for example 86.50."
            )
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background)
    }
}

#Preview("Currency field") {
    CurrencyTextFieldPreviewHost()
}
