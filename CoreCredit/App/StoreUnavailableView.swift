//
//  StoreUnavailableView.swift
//  CoreCredit
//

import SwiftUI

/// Shown when CoreCredit could not open the file it keeps the ledger in.
///
/// This screen exists so that the worst case is still a screen. `ModelContainerFactory` never
/// traps and never spins, so the app reaches this view instead of dying on launch — and from
/// here there is always something the owner can do.
///
/// The wording is chosen for someone standing at a parts counter, not for a developer: what
/// happened, what it means for their data, and two clearly different buttons. The underlying
/// reason is shown, but demoted and labelled, so it can be read out to support without being the
/// first thing anyone sees.
struct StoreUnavailableView: View {

    private let message: String
    private let onRetry: () -> Void
    private let onReset: () -> Void

    /// - Parameters:
    ///   - message: The reason the store could not be opened, as recorded by
    ///     `ModelContainerFactory.lastLoadFailureMessage`.
    ///   - onRetry: Tries to open the store again.
    ///   - onReset: Deletes the local store files and tries again. Destructive.
    init(message: String, onRetry: @escaping () -> Void, onReset: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
        self.onReset = onReset
    }

    var body: some View {
        ZStack {
            Palette.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header
                    explanation
                    reasonCard
                    actions
                }
                .padding(Spacing.l)
                .frame(maxWidth: StoreUnavailableView.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(.largeTitle, design: .default, weight: .regular))
                .foregroundStyle(Palette.danger)
                .accessibilityHidden(true)

            Text("CoreCredit can't open your data")
                .font(Typography.hero)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Explanation

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Your cores, vendors, and photos are stored on this device. CoreCredit couldn't "
                 + "open that storage, so it can't show or save anything right now.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Nothing has been deleted. Trying again is safe, and often works after the "
                 + "device has finished starting up or has some free space again.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Reason

    private var reasonCard: some View {
        SectionCard(title: "What the device reported", systemImage: "info.circle") {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Reported reason. " + message))
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Button(action: onRetry) {
                PrimaryButtonLabel("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Tries to open your saved data again. Nothing is deleted."))

            VStack(alignment: .leading, spacing: Spacing.s) {
                DestructiveConfirmButton(
                    title: "Reset local data",
                    confirmationTitle: "Reset local data",
                    message: "This deletes the storage file CoreCredit can't open, including any "
                        + "cores, vendors, and photos still inside it. This cannot be undone.",
                    action: onReset
                )

                Text("Only use this if trying again keeps failing. It removes the damaged file so "
                     + "CoreCredit can start over from empty.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let contentMaxWidth: CGFloat = 560
}

#Preview("Store unavailable") {
    StoreUnavailableView(
        message: "The saved data file could not be opened. The file is in use by another process.",
        onRetry: { },
        onReset: { }
    )
}
