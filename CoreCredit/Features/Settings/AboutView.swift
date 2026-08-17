//
//  AboutView.swift
//  CoreCredit
//

import Foundation
import SwiftUI

/// What this app is, what it is not, and what it does with the shop's information.
///
/// Two rules govern every word on this screen:
///
/// 1. **Nothing is claimed that the code does not do.** The privacy section describes the actual
///    implementation — a local SwiftData store, local notifications, StoreKit for the subscription,
///    and no network client of any kind — and says so in those terms rather than in marketing ones.
/// 2. **A placeholder address is never printed.** `AppConfiguration`'s support and privacy URLs are
///    still `example.com` stand-ins. Showing one to a shop owner would be worse than showing
///    nothing, so this screen hides the row entirely and says, in words, that a support contact has
///    not been set up yet. The full policies do not depend on those addresses at all: they ship
///    inside the app and open natively through `LegalDocumentView`.
///
/// There are no external purchase links here. The only purchase path in CoreCredit is the
/// Subscription screen, which uses StoreKit through `SubscriptionStatusView` and `PaywallView`.
struct AboutView: View {

    init() { }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                versionCard
                whatItIsCard
                termsCard
                privacyCard
                documentsCard
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Version

    private var versionCard: some View {
        SectionCard(title: AppConfiguration.displayName, systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabeledValueRow(
                    "Version",
                    value: AppConfiguration.versionDisplayString,
                    isMonospaced: true
                )

                Text("A core-return and vendor-credit ledger for owner-operated repair shops. "
                     + "Every record lives on this device.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - What it is

    private var whatItIsCard: some View {
        SectionCard(title: "What CoreCredit does", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("CoreCredit keeps track of core charges: what you were billed, which old unit "
                     + "has to go back, which vendor it belongs to, when their return window "
                     + "closes, and whether the credit ever actually arrived.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("It works from the figures you enter. It does not read your invoices for you, "
                     + "it does not connect to a vendor's system, and it does not know anything "
                     + "about your account with them.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Terms

    /// The honest limits of the product, stated where an owner will actually read them.
    ///
    /// A summary, not the agreement: the full Terms of Use is the bundled document linked below.
    private var termsCard: some View {
        SectionCard(title: "Terms of use, in brief", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                paragraph("CoreCredit is an organisational record. It is a place to write down "
                          + "core charges and keep track of them — nothing more.")

                paragraph("It is not accounting software, and nothing in it is accounting, tax, or "
                          + "legal advice. The totals here are not books of account and are not a "
                          + "substitute for your own bookkeeping. Check every figure against your "
                          + "invoices and credit memos before you rely on it.")

                paragraph("It is not a guarantee that a vendor will honour a return. Whether an "
                          + "old core is accepted, and whether a credit is issued and for how "
                          + "much, is entirely between your shop and that supplier, under whatever "
                          + "terms you agreed with them. CoreCredit has no relationship with your "
                          + "vendors, sends them nothing, and cannot make a credit happen.")

                paragraph("Return windows, due dates, and reminders are calculated from the "
                          + "numbers you enter. A vendor can change its policy without telling the "
                          + "app, and a reminder can be delayed or missed if notifications are "
                          + "turned off for CoreCredit or the device is off. Treat the deadlines "
                          + "here as your own working notes, not as the vendor's word.")

                paragraph("The app is provided as it is, without any warranty. You are responsible "
                          + "for keeping your own copies of anything you cannot afford to lose — "
                          + "the backup file on the Data & export screen exists for exactly that.")
            }
        }
    }

    // MARK: - Privacy

    /// Describes the implementation as built. Every sentence here is checkable against the code.
    ///
    /// A summary, not the policy: the full Privacy Policy is the bundled document linked below.
    private var privacyCard: some View {
        SectionCard(title: "Privacy, in brief", systemImage: "lock") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                paragraph("Your shop's records are stored on this device, in the app's own "
                          + "storage. There is no CoreCredit account and no sign-in, because there "
                          + "is no CoreCredit server: nothing you type is sent to the developer.")

                paragraph("There is no analytics, no tracking, and no advertising in this app. "
                          + "Nobody is told which screens you open or how often you use it.")

                paragraph("Reminders are scheduled locally by this device and are delivered by it. "
                          + "They contain only what is already in your ledger.")

                paragraph("Two things do leave the app, and only when you ask them to. Files you "
                          + "export are handed to whichever app you choose in the share sheet — "
                          + "after that they are outside CoreCredit's control. Subscription "
                          + "purchases are handled by Apple through the App Store; Apple tells the "
                          + "app whether a subscription is currently active, and nothing else.")

                paragraph("If you have iCloud Backup or an encrypted device backup switched on, "
                          + "this app's data is included in that backup, the same as any other "
                          + "app's. Erasing everything on the Data & export screen clears the copy "
                          + "on this device; it does not reach into a backup you have already "
                          + "made.")
            }
        }
    }

    // MARK: - Documents

    /// The full documents, and the support contact if there is one.
    ///
    /// These are `NavigationLink`s into the bundled documents rather than `Link`s to a web page:
    /// the policies are compiled into the app and rendered natively, so they open in a tunnel, on
    /// aeroplane mode, and in a basement parts room — and nothing is fetched to show them.
    private var documentsCard: some View {
        SectionCard(title: "Policies and support", systemImage: "questionmark.circle") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                documentRow(
                    .privacyPolicy,
                    symbol: "hand.raised",
                    hint: "Opens the privacy policy, stored inside the app."
                )

                Divider().overlay(Palette.hairline)

                documentRow(
                    .termsOfUse,
                    symbol: "doc.text",
                    hint: "Opens the terms of use, stored inside the app."
                )

                Divider().overlay(Palette.hairline)

                documentRow(
                    .localDataAndBackup,
                    symbol: "internaldrive",
                    hint: "Opens the note on local storage, backups, and erasing."
                )

                Divider().overlay(Palette.hairline)

                supportRow

                if AppConfiguration.isSupportContactConfigured == false {
                    placeholderNote("A support contact hasn't been set up for this app yet, so "
                                    + "there is no address to show.")
                }

                Text("Subscription options, restoring a purchase, and managing billing are all on "
                     + "the Subscription screen in Settings.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func documentRow(
        _ documentID: LegalDocumentID,
        symbol: String,
        hint: String
    ) -> some View {
        NavigationLink {
            LegalDocumentView(documentID: documentID)
        } label: {
            navigationRowLabel(title: documentID.displayName, symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(documentID.displayName))
        .accessibilityHint(Text(hint))
    }

    /// Always a link to the same support screen, whether or not a contact exists yet — that screen
    /// is the one place in the app that decides what can honestly be shown.
    private var supportRow: some View {
        NavigationLink {
            LegalSupportView()
        } label: {
            navigationRowLabel(title: "Support and contact", symbol: "lifepreserver")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Support and contact"))
        .accessibilityHint(Text("Opens the app version and, if one has been set up, the support "
                                + "contact."))
    }

    private func navigationRowLabel(title: String, symbol: String) -> some View {
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

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// An honest caption about something that is not configured yet.
    ///
    /// It never contains an address. The stand-ins in `AppConfiguration` exist so the app compiles
    /// and so `AppConfiguration.isPlaceholder(_:)` can hide the rows that depend on them; printing
    /// one here would only invite a shop to write to a mailbox that does not exist.
    private func placeholderNote(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.small)
                .accessibilityHidden(true)

            Text(message)
                .font(Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(message))
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("About") {
    NavigationStack {
        AboutView()
    }
}
