//
//  LegalDocumentView.swift
//  CoreCredit
//

import SwiftUI

/// One bundled legal document, rendered natively.
///
/// There is no web view here and no network request of any kind. The text is decoded from JSON that
/// ships inside the app and drawn as ordinary SwiftUI `Text`, which is what makes it readable in a
/// basement parts room with no signal, selectable, searchable, spoken correctly by VoiceOver, and
/// scalable to the largest accessibility text sizes.
///
/// Every size on this screen comes from a text style, never a point value, so the whole document
/// grows with Dynamic Type.
struct LegalDocumentView: View {

    private let documentID: LegalDocumentID

    @State private var document: LegalDocument?
    @State private var loadFailureMessage: String?
    @State private var searchText = ""

    init(documentID: LegalDocumentID) {
        self.documentID = documentID
    }

    var body: some View {
        Group {
            if let document = document {
                documentBody(document)
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Search this document")
                    )
            } else {
                failureBody
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(document?.title ?? documentID.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { shareToolbar }
        .accessibilityIdentifier(A11y.Legal.documentRoot)
        .task { loadIfNeeded() }
    }

    // MARK: - Loaded document

    private func documentBody(_ document: LegalDocument) -> some View {
        let matches = document.sections(matching: searchText)

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                summaryCard(document)

                if matches.isEmpty {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "No matches",
                        message: "No part of this document contains that word. Clear the search to "
                            + "read the whole document."
                    )
                } else {
                    ForEach(matches) { section in
                        sectionCard(section)
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .textSelection(.enabled)
    }

    private func summaryCard(_ document: LegalDocument) -> some View {
        SectionCard(title: document.title, systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabeledValueRow("Version", value: document.version, isMonospaced: true)
                LabeledValueRow("Effective", value: LegalDocumentView.readableDate(document.effectiveDate))

                Text(document.summary)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("This document is stored inside the app. Reading it does not connect to "
                     + "anything.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `SectionCard` already marks its title as an accessibility header, which is what lets
    /// VoiceOver's rotor jump section to section through a long policy.
    private func sectionCard(_ section: LegalSection) -> some View {
        SectionCard(title: section.heading) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                // Indices rather than the strings themselves: two identical paragraphs in one
                // section would collide if the text were the identity.
                ForEach(section.paragraphs.indices, id: \.self) { index in
                    Text(section.paragraphs[index])
                        .font(.subheadline)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Failure

    /// Shown when the document could not be read out of the bundle.
    ///
    /// It says which document failed and where else the text can be read — and it still fetches
    /// nothing. The published address appears only if the owner has actually configured one; a
    /// placeholder address is never printed to the screen.
    private var failureBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ErrorBanner(message: loadFailureMessage ?? LegalDocumentView.genericFailureMessage)

                SectionCard(title: "What to do", systemImage: "questionmark.circle") {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("This document ships inside the app, so this is a problem with this "
                             + "copy of the app rather than with your ledger. Nothing in your "
                             + "records is affected.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Reinstalling CoreCredit from the App Store restores it.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let publishedURL = publishedURL {
                            Link(destination: publishedURL) {
                                HStack(spacing: Spacing.s) {
                                    Text("Read the published copy")
                                        .font(Typography.rowTitle)
                                    Image(systemName: "arrow.up.forward")
                                        .font(.footnote.weight(.semibold))
                                        .accessibilityHidden(true)
                                }
                                .foregroundStyle(Palette.accent)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: Spacing.minimumTapTarget,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel(Text("Read the published copy"))
                            .accessibilityHint(Text("Opens the published version of this document "
                                                    + "in the browser."))
                        } else {
                            Text("A published address for this document has not been set up yet, "
                                 + "so there is nowhere to send you.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Toolbar

    /// Sharing the document as plain text, so it pastes straight into a mail body or a note.
    @ToolbarContentBuilder
    private var shareToolbar: some ToolbarContent {
        if let document = document {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: document.plainText, subject: Text(document.title)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("Share this document"))
                .accessibilityHint(Text("Opens the share sheet with the whole document as text."))
            }
        }
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard document == nil else { return }
        do {
            document = try LegalDocumentStore.load(documentID)
            loadFailureMessage = nil
        } catch {
            document = nil
            loadFailureMessage = LegalDocumentView.message(for: error)
        }
    }

    /// The published address for this document, but only when the owner has replaced the shipped
    /// placeholder. `nil` means the screen says so in words instead of printing a dead address.
    private var publishedURL: URL? {
        switch documentID {
        case .privacyPolicy:
            return AppConfiguration.configuredPrivacyURL
        case .termsOfUse:
            return AppConfiguration.configuredTermsURL
        case .localDataAndBackup:
            return nil
        }
    }

    private static let genericFailureMessage =
        "This document couldn't be opened on this device."

    private static func message(for error: any Error) -> String {
        guard let localized = error as? any LocalizedError,
              let description = localized.errorDescription else {
            return LegalDocumentView.genericFailureMessage
        }
        return description
    }

    /// Turns the document's `yyyy-MM-dd` effective date into something a person reads.
    ///
    /// Falls back to the raw string rather than hiding the value if it is ever written in another
    /// shape — a policy that shows no date at all would be worse than one showing an ISO date.
    ///
    /// Parsing and formatting both happen in the device's own time zone, so a date-only value
    /// cannot slide to the day before or after.
    private static func readableDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"

        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

#Preview("Privacy policy") {
    NavigationStack {
        LegalDocumentView(documentID: .privacyPolicy)
    }
}

#Preview("Terms of use") {
    NavigationStack {
        LegalDocumentView(documentID: .termsOfUse)
    }
}
