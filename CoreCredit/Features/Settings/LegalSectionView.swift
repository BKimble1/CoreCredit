//
//  LegalSectionView.swift
//  CoreCredit
//

import SwiftUI

/// The Legal hub: the documents that ship with the app, plus how to get in touch.
///
/// Every document here is read from the app bundle and rendered natively by `LegalDocumentView`.
/// Nothing on this screen opens a network connection, which is deliberate — a shop is entitled to
/// read the terms it agreed to without a signal and without asking anyone's server for permission.
///
/// Rows are `NavigationLink { destination } label: { row }`, matching `SettingsView`, because these
/// screens share a `NavigationSplitView` column on iPad where a value-typed destination registered
/// here would be ambiguous.
struct LegalSectionView: View {

    init() { }

    var body: some View {
        List {
            documentsSection
            contactSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Legal")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Legal.root)
    }

    // MARK: - Sections

    private var documentsSection: some View {
        Section {
            ForEach(LegalDocumentID.allCases, id: \.self) { documentID in
                NavigationLink {
                    LegalDocumentView(documentID: documentID)
                } label: {
                    LegalHubRow(
                        title: documentID.displayName,
                        value: LegalSectionView.summary(for: documentID),
                        symbol: LegalSectionView.symbol(for: documentID),
                        hint: LegalSectionView.hint(for: documentID)
                    )
                }
                .accessibilityIdentifier(LegalSectionView.identifier(for: documentID))
            }
        } header: {
            Text("Documents")
        } footer: {
            Text("These are stored inside the app and open without a connection. Each one can be "
                 + "shared as plain text from its own screen.")
        }
        .listRowBackground(Palette.surface)
    }

    private var contactSection: some View {
        Section {
            NavigationLink {
                LegalSupportView()
            } label: {
                LegalHubRow(
                    title: "Support and contact",
                    value: contactSummary,
                    symbol: "lifepreserver",
                    hint: "The app version, and how to reach support if a contact has been set up."
                )
            }
            .accessibilityIdentifier(A11y.Legal.support)
        } header: {
            Text("Help")
        }
        .listRowBackground(Palette.surface)
    }

    private var contactSummary: String {
        AppConfiguration.isSupportContactConfigured
            ? "Version " + AppConfiguration.versionDisplayString
            : "Version " + AppConfiguration.versionDisplayString + " • no contact set up yet"
    }

    // MARK: - Row content

    /// The automation identifier for one document's row.
    ///
    /// Exhaustive rather than derived from `rawValue`, so adding a document does not compile until
    /// an identifier has been chosen for it and mirrored into `CoreCreditUITests`. Never spoken —
    /// the row supplies its own VoiceOver label.
    private static func identifier(for documentID: LegalDocumentID) -> String {
        switch documentID {
        case .privacyPolicy:
            return A11y.Legal.privacyPolicy
        case .termsOfUse:
            return A11y.Legal.termsOfUse
        case .localDataAndBackup:
            return A11y.Legal.localData
        }
    }

    private static func summary(for documentID: LegalDocumentID) -> String {
        switch documentID {
        case .privacyPolicy:
            return "What is stored, and what never leaves this device"
        case .termsOfUse:
            return "What the app is, what it is not, and what you rely on"
        case .localDataAndBackup:
            return "Where the ledger lives, backups, and erasing"
        }
    }

    private static func symbol(for documentID: LegalDocumentID) -> String {
        switch documentID {
        case .privacyPolicy:
            return "hand.raised"
        case .termsOfUse:
            return "doc.text"
        case .localDataAndBackup:
            return "internaldrive"
        }
    }

    private static func hint(for documentID: LegalDocumentID) -> String {
        switch documentID {
        case .privacyPolicy:
            return "Opens the privacy policy, stored inside the app."
        case .termsOfUse:
            return "Opens the terms of use, stored inside the app."
        case .localDataAndBackup:
            return "Opens the note on local storage, backups, and erasing, stored inside the app."
        }
    }
}

// MARK: - Support and contact

/// Version information and, if the owner has configured one, how to reach support.
///
/// The screen refuses to print a placeholder address. `AppConfiguration` still ships `example.com`
/// stand-ins so the build compiles, but showing one here would be worse than showing nothing: it
/// invites a shop to write to an address that reaches nobody. When nothing is configured the screen
/// says exactly that.
///
/// Not private: `AboutView` links to this same screen, so there is exactly one place in the app
/// that decides how a support contact is shown or withheld.
struct LegalSupportView: View {

    init() { }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                versionCard
                contactCard
                inTheAppCard
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Support and contact")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Version

    private var versionCard: some View {
        SectionCard(title: AppConfiguration.displayName, systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabeledValueRow(
                    "Version",
                    value: AppConfiguration.versionDisplayString,
                    isMonospaced: true
                )

                Text("Quote this version if you ever report a problem. It tells whoever reads the "
                     + "report exactly which build you are running.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Contact

    private var contactCard: some View {
        SectionCard(title: "Getting in touch", systemImage: "envelope") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let supportURL = AppConfiguration.configuredSupportURL {
                    externalLinkRow(
                        title: "Support page",
                        symbol: "lifepreserver",
                        destination: supportURL,
                        hint: "Opens the support page in the browser."
                    )
                }

                if let email = AppConfiguration.configuredSupportEmail {
                    LabeledValueRow("Support email", value: email, symbol: "envelope")

                    if let mailURL = URL(string: "mailto:" + email) {
                        externalLinkRow(
                            title: "Send an email",
                            symbol: "square.and.pencil",
                            destination: mailURL,
                            hint: "Opens a new message in your mail app."
                        )
                    }
                }

                if AppConfiguration.isSupportContactConfigured == false {
                    Text("A support contact has not been set up for this app yet, so there is "
                         + "nothing to show here. Nothing is hidden from you — there is genuinely "
                         + "no address that would reach anyone.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("A working support address must be published before this app is offered "
                         + "publicly.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func externalLinkRow(
        title: String,
        symbol: String,
        destination: URL,
        hint: String
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .imageScale(.medium)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.s)

                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint))
    }

    // MARK: What to try first

    private var inTheAppCard: some View {
        SectionCard(title: "Things you can do without waiting", systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                bullet("Subscription questions, restoring a purchase, and cancelling are all on the "
                       + "Subscription screen in Settings. Billing itself is handled by Apple.")

                bullet("Data and export writes a spreadsheet, a ledger document, or a full backup "
                       + "file you can keep somewhere safe.")

                bullet("Scanner diagnostics shows exactly what the last scan read, which is usually "
                       + "the fastest way to understand a scan that went wrong.")

                bullet("Legal holds the privacy policy, the terms of use, and the note on how your "
                       + "records are stored on this device.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

/// One line in the Legal hub: glyph, what it is, and a short description of what is inside.
///
/// Collapsed into a single accessibility element so VoiceOver reads the row as one phrase, and
/// held to the 44-point minimum height, exactly like the rows in `SettingsView`.
private struct LegalHubRow: View {

    let title: String
    let value: String
    let symbol: String
    let hint: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(value)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.s)
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityHint(Text(hint))
    }
}

#Preview("Legal") {
    NavigationStack {
        LegalSectionView()
    }
}
