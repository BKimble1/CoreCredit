//
//  Buttons.swift
//  CoreCredit
//

import SwiftUI

// MARK: - PrimaryButtonLabel

/// The label for the one primary action on a screen — "Save core", "Create batch", "Record credit".
///
/// It is a *label*, not a button, so the caller keeps ownership of the action, the role, and any
/// `.disabled` state. Wrap it: `Button(action: save) { PrimaryButtonLabel("Save core") }`.
///
/// Fills its container's width and is at least `Spacing.minimumTapTarget` tall.
struct PrimaryButtonLabel: View {

    private let title: String
    private let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let systemImage = systemImage {
                Image(systemName: systemImage)
                    .imageScale(.medium)
            }
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(Palette.onAccent)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.accent)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - DestructiveConfirmButton

/// A destructive action that always asks first.
///
/// Deleting a core destroys its evidence timeline, which is the one thing this app exists to
/// protect, so every destructive path in the app routes through here rather than calling `delete`
/// straight from a swipe or a menu item.
struct DestructiveConfirmButton: View {

    private let title: String
    private let confirmationTitle: String
    private let message: String
    private let action: () -> Void

    @State private var isPresentingConfirmation = false

    /// - Parameters:
    ///   - title: The button's own label, e.g. "Delete core".
    ///   - confirmationTitle: Title of the dialog *and* the wording of its destructive button, so
    ///     the confirming tap restates what it does instead of saying "OK".
    ///   - message: The consequence, in plain language.
    ///   - action: Performed only after confirmation.
    init(title: String, confirmationTitle: String, message: String, action: @escaping () -> Void) {
        self.title = title
        self.confirmationTitle = confirmationTitle
        self.message = message
        self.action = action
    }

    var body: some View {
        Button(role: .destructive) {
            isPresentingConfirmation = true
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "trash")
                    .imageScale(.medium)
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.danger.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.danger.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isPresentingConfirmation,
            titleVisibility: .visible
        ) {
            Button(confirmationTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(message)
        }
    }
}

// MARK: - LoadingOverlay

/// Blocking progress for work the user must wait on — rendering a dispute packet, writing a backup.
///
/// Deliberately plain: a spinner and a sentence saying what is happening. There is no animation
/// beyond the system spinner, and it is announced to VoiceOver as a single element.
struct LoadingOverlay: View {

    private let message: String

    init(message: String) {
        self.message = message
    }

    var body: some View {
        ZStack {
            Palette.background
                .opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: Spacing.m) {
                ProgressView()
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 280)
            .background(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(message))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - FormErrorText

/// Validation message shown beneath a form field.
///
/// Always pairs the red with a glyph, so the failure is legible without colour perception. Renders
/// nothing at all when the message is `nil` or empty, which lets callers bind it straight to an
/// optional `ValidationIssue.message` without a conditional at the call site.
struct FormErrorText: View {

    private let message: String?

    init(_ message: String?) {
        self.message = message
    }

    var body: some View {
        if let message = message, message.isEmpty == false {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .imageScale(.small)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Error. " + message))
        }
    }
}

#Preview("Buttons and form feedback") {
    VStack(spacing: Spacing.xl) {
        Button { } label: {
            PrimaryButtonLabel("Save core", systemImage: "checkmark")
        }
        .buttonStyle(.plain)

        DestructiveConfirmButton(
            title: "Delete core",
            confirmationTitle: "Delete core",
            message: "This removes the core, its photos, and its history. This cannot be undone.",
            action: { }
        )

        FormErrorText("Enter the core charge, for example 86.50.")

        LoadingOverlay(message: "Building dispute packet…")
            .frame(height: 220)
    }
    .padding(Spacing.l)
    .background(Palette.background)
}
