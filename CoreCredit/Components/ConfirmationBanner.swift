//
//  ConfirmationBanner.swift
//  CoreCredit
//

import SwiftUI

/// An inline confirmation that something the user asked for actually happened.
///
/// # Why this exists rather than a notification
///
/// An ordinary action inside the app is confirmed *inside the app*. A notification is for something
/// the shop needs to know when they are not looking at CoreCredit — a return window about to close,
/// a credit that never arrived. Sending one to say "saved" would train the owner to ignore the
/// alerts that matter, so a confirmation of a tap the user just made never leaves this screen.
///
/// # Construction mirrors `ErrorBanner`
///
/// Same padding, same corner radius, same tinted fill and hairline border, same 44-point dismiss
/// control, so the two read as one family stacked in the same banner strip. The only differences are
/// the colour, the glyph, and the absence of a retry — there is nothing to retry about a success.
///
/// Green is this app's confirmation colour (`Palette.positive`). The colour is never the message,
/// though: the glyph and the wording both say the same thing, so the banner still works for a
/// colour-blind reader and under VoiceOver.
///
/// Auto-dismissal is deliberately not offered. A confirmation that erases itself on a timer is a
/// confirmation the person who was interrupted mid-task never got to read.
struct ConfirmationBanner: View {

    private let message: String
    private let systemImage: String
    private let onDismiss: (() -> Void)?

    /// - Parameters:
    ///   - message: What happened, in plain language and in the past tense.
    ///   - systemImage: The glyph shown beside the message. The default suits a plain "that worked";
    ///     pass something more specific when the action has an obvious symbol of its own.
    ///   - onDismiss: When set, a close control appears. Omit it when the caller clears the message
    ///     some other way — the next action, or leaving the screen.
    init(
        message: String,
        systemImage: String = "checkmark.circle",
        onDismiss: (() -> Void)? = nil
    ) {
        self.message = message
        self.systemImage = systemImage
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .foregroundStyle(Palette.positive)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Confirmed. " + message))
                .accessibilityAddTraits(.isStaticText)

            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(
                            width: Spacing.minimumTapTarget,
                            height: Spacing.minimumTapTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.positive.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.positive.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview("Confirmation banners") {
    VStack(spacing: Spacing.l) {
        ConfirmationBanner(message: "Core saved.")
        ConfirmationBanner(
            message: "A test notification is on its way — it should arrive in about five seconds.",
            systemImage: "bell.badge",
            onDismiss: { }
        )
    }
    .padding(Spacing.l)
    .background(Palette.background)
}
