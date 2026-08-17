//
//  ErrorBanner.swift
//  CoreCredit
//

import SwiftUI

/// An inline failure message with an optional retry and an optional dismiss.
///
/// Used for recoverable, non-modal problems — a StoreKit load that failed, an export that could
/// not be written, a reminder that could not be scheduled. Modal errors that stop the user belong
/// in an alert; this is for the ones they can work around.
///
/// The banner never appears on its own: it is red, it carries a warning glyph, and it states the
/// problem in words, so none of the three signals is load-bearing by itself.
struct ErrorBanner: View {

    private let message: String
    private let retryTitle: String?
    private let onRetry: (() -> Void)?
    private let onDismiss: (() -> Void)?

    /// - Parameters:
    ///   - message: What went wrong, in plain language.
    ///   - retryTitle: Retry button title. The button appears only when both this and `onRetry`
    ///     are set.
    ///   - onRetry: Performed when retry is tapped.
    ///   - onDismiss: When set, a close control appears. Omit it for errors that must stay visible
    ///     until they are actually resolved.
    init(
        message: String,
        retryTitle: String? = nil,
        onRetry: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(Palette.danger)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Error. " + message))

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

            if let retryTitle = retryTitle, let onRetry = onRetry {
                Button(action: onRetry) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                        Text(retryTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, Spacing.s)
                    .frame(minHeight: Spacing.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.danger.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.danger.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview("Error banners") {
    VStack(spacing: Spacing.l) {
        ErrorBanner(message: "Couldn't load subscription options.")
        ErrorBanner(
            message: "Couldn't load subscription options. Check your connection and try again.",
            retryTitle: "Try again",
            onRetry: { }
        )
        ErrorBanner(
            message: "The dispute packet couldn't be written to disk.",
            retryTitle: "Try again",
            onRetry: { },
            onDismiss: { }
        )
    }
    .padding(Spacing.l)
    .background(Palette.background)
}
