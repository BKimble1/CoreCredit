//
//  VendorEditorView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI
import UIKit

/// Add or edit one vendor.
///
/// # The return window belongs to the vendor
///
/// The window on this screen is *this supplier's* policy and nothing more. CoreCredit never treats
/// one vendor's deadline as universal: the number seeds the due date when a core is logged against
/// this vendor, it stays editable here forever, and an individual core can be given its own due
/// date in the core editor. `CoreItemService.updateVendor(_:)` refreshes the deadlines of this
/// vendor's *open* cores when the window changes, and deliberately leaves closed ones alone —
/// rewriting the history of a credited core would be a lie.
///
/// # Deleting is explained before it happens
///
/// The vendor relationship is `.nullify`, so deleting a vendor never destroys a core. The
/// confirmation says exactly that, with the real counts, because "delete" on a screen full of money
/// is otherwise a reasonable thing to be afraid of.
struct VendorEditorView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let vendor: Vendor?

    @State private var name = ""
    @State private var contactName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var accountNumber = ""
    @State private var windowDaysText = String(AppConfiguration.defaultVendorReturnWindowDays)
    @State private var notes = ""
    @State private var isActive = true

    @State private var hasLoaded = false
    @State private var nameError: String?
    @State private var errorMessage: String?

    /// - Parameter vendor: The vendor to edit, or `nil` to add a new one.
    init(vendor: Vendor?) {
        self.vendor = vendor
    }

    var body: some View {
        Form {
            if let errorMessage = errorMessage {
                Section {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                        .listRowBackground(Color.clear)
                }
            }

            identitySection
            windowSection
            contactSection
            notesSection
            statusSection
            saveSection

            if vendor != nil {
                deleteSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(vendor == nil ? "New vendor" : "Vendor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                cancelButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier(A11y.Settings.vendorSave)
                    .accessibilityHint(Text("Saves this vendor."))
            }
        }
        .task { load() }
    }

    /// Only a sheet needs a Cancel button; a pushed editor already has a back button.
    @ViewBuilder
    private var cancelButton: some View {
        if vendor == nil {
            Button("Cancel") { dismiss() }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Vendor name")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                TextField("NAPA", text: $name)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityIdentifier(A11y.Settings.vendorName)
                    .accessibilityLabel(Text("Vendor name"))

                FormErrorText(nameError)
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Vendor")
        }
        .listRowBackground(Palette.surface)
    }

    private var windowSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.m) {
                    Text("Days")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)

                    TextField("30", text: $windowDaysText)
                        .font(Typography.rowTitle.monospacedDigit())
                        .foregroundStyle(Palette.textPrimary)
                        .keyboardType(.numberPad)
                        .submitLabel(.done)
                        .frame(minWidth: 64, minHeight: Spacing.minimumTapTarget)
                        .accessibilityIdentifier(A11y.Settings.vendorWindow)
                        .accessibilityLabel(Text("Default return window in days"))
                        .accessibilityValue(Text(String(windowDays)))

                    Spacer(minLength: Spacing.s)

                    Stepper(value: windowDaysBinding,
                            in: DueDateCalculator.minimumWindowDays...DueDateCalculator.maximumWindowDays) {
                        Text("Return window")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Adjust return window"))
                    .accessibilityValue(Text(windowSentence))
                }

                Text(windowSentence)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Return window")
        } footer: {
            Text(windowFooterText)
        }
        .listRowBackground(Palette.surface)
    }

    private var contactSection: some View {
        Section {
            VendorField(
                title: "Contact name",
                placeholder: "Parts manager",
                text: $contactName,
                contentType: .name,
                keyboardType: .default,
                autocapitalization: .words
            )

            VendorField(
                title: "Phone",
                placeholder: "555-0142",
                text: $phone,
                contentType: .telephoneNumber,
                keyboardType: .phonePad,
                autocapitalization: .never
            )

            VendorField(
                title: "Email",
                placeholder: "parts@vendor.com",
                text: $email,
                contentType: .emailAddress,
                keyboardType: .emailAddress,
                autocapitalization: .never,
                disablesAutocorrection: true
            )

            VendorField(
                title: "Account number",
                placeholder: "88-41207",
                text: $accountNumber,
                contentType: nil,
                keyboardType: .numbersAndPunctuation,
                autocapitalization: .characters,
                disablesAutocorrection: true,
                isMonospaced: true
            )
        } header: {
            Text("Contact")
        } footer: {
            Text("Used on dispute packets so the person chasing a credit has the account number "
                 + "and a name to ask for.")
        }
        .listRowBackground(Palette.surface)
    }

    private var notesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Notes")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                TextField("Won't take a core without the original box.",
                          text: $notes,
                          axis: .vertical)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3...6)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityLabel(Text("Notes about this vendor"))
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Notes")
        }
        .listRowBackground(Palette.surface)
    }

    private var statusSection: some View {
        Section {
            Toggle(isOn: $isActive) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Active")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(isActive ? "Offered when logging a core" : "Hidden when logging a core")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .tint(Palette.accent)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Active vendor"))
            .accessibilityHint(Text("Turn this off to retire a vendor you no longer buy from. "
                                    + "Its existing cores are not affected."))
        } header: {
            Text("Status")
        }
        .listRowBackground(Palette.surface)
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                PrimaryButtonLabel(vendor == nil ? "Add vendor" : "Save vendor",
                                   systemImage: "checkmark")
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(
                    top: Spacing.s,
                    leading: Spacing.l,
                    bottom: Spacing.s,
                    trailing: Spacing.l
                )
            )
        }
    }

    private var deleteSection: some View {
        Section {
            DestructiveConfirmButton(
                title: "Delete vendor",
                confirmationTitle: "Delete vendor",
                message: deletionMessage,
                action: { deleteVendor() }
            )
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(
                    top: Spacing.s,
                    leading: Spacing.l,
                    bottom: Spacing.s,
                    trailing: Spacing.l
                )
            )
        } footer: {
            Text(deletionMessage)
        }
    }

    // MARK: - Copy

    private var vendorNameForCopy: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this vendor" : trimmed
    }

    private var windowSentence: String {
        let days = windowDays == 1 ? "1 day" : String(windowDays) + " days"
        return "Cores are due back " + days + " after the day they are received."
    }

    /// The whole point of this screen, said plainly: the window is one vendor's policy, it is
    /// always editable, and a single core can still overrule it.
    private var windowFooterText: String {
        var text = "This is this vendor's own policy, and only a starting point. "
        text += "When you log a core against "
        text += vendorNameForCopy
        text += ", the deadline is set this many days after the day you received the part — and "
        text += "you can still give that one core a different due date in the core's own screen. "
        text += "No return window in CoreCredit applies to every vendor. "
        text += "Changing it here updates the deadline on this vendor's open cores and leaves "
        text += "settled ones exactly as they were. Anything from "
        text += String(DueDateCalculator.minimumWindowDays)
        text += " to "
        text += String(DueDateCalculator.maximumWindowDays)
        text += " days is accepted."
        return text
    }

    /// Spells out what survives the delete, with this vendor's real numbers in it.
    private var deletionMessage: String {
        let cores = vendor?.items.count ?? 0
        let batches = vendor?.batches.count ?? 0

        var message = "Deleting "
            + vendorNameForCopy
            + " removes the supplier from this list. "

        if cores == 0 && batches == 0 {
            message += "No cores or returns are linked to it, so nothing else changes. "
        } else {
            var linked: [String] = []
            if cores > 0 {
                linked.append(cores == 1 ? "1 core" : String(cores) + " cores")
            }
            if batches > 0 {
                linked.append(batches == 1 ? "1 return" : String(batches) + " returns")
            }
            message += "The "
                + linked.joined(separator: " and ")
                + " linked to it stay in the ledger with their money, photos, and history intact — "
                + "they simply stop showing a vendor, and you can point them at another vendor "
                + "afterwards. "
        }

        message += "Deleting the vendor itself cannot be undone. If you only want it to stop "
            + "appearing when you log a core, turn Active off instead."
        return message
    }

    // MARK: - Return window

    private var windowDays: Int {
        let digits = windowDaysText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(digits) else {
            return AppConfiguration.defaultVendorReturnWindowDays
        }
        return DueDateCalculator.clampWindowDays(parsed)
    }

    /// The stepper writes back through the same text state the field edits, so the two controls can
    /// never disagree and every value that leaves here has been through `clampWindowDays`.
    private var windowDaysBinding: Binding<Int> {
        Binding(
            get: { windowDays },
            set: { newValue in
                windowDaysText = String(DueDateCalculator.clampWindowDays(newValue))
            }
        )
    }

    // MARK: - Load and save

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true

        guard let vendor = vendor else { return }
        name = vendor.name
        contactName = vendor.contactName
        phone = vendor.phone
        email = vendor.email
        accountNumber = vendor.accountNumber
        windowDaysText = String(DueDateCalculator.clampWindowDays(vendor.defaultReturnWindowDays))
        notes = vendor.notes
        isActive = vendor.isActive
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            nameError = "Enter the vendor's name, for example NAPA."
            return
        }
        nameError = nil

        let service = appEnvironment.itemService(modelContext)
        do {
            let target: Vendor
            if let existing = vendor {
                target = existing
            } else {
                target = try service.createVendor(name: trimmedName, returnWindowDays: windowDays)
            }

            target.name = trimmedName
            target.contactName = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
            target.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            target.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            target.accountNumber = accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            target.defaultReturnWindowDays = windowDays
            target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            target.isActive = isActive

            // Also re-derives the deadlines of this vendor's open cores from the saved window.
            try service.updateVendor(target)

            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = VendorEditorView.message(for: error)
        }
    }

    private func deleteVendor() {
        guard let vendor = vendor else { return }
        do {
            try appEnvironment.itemService(modelContext).deleteVendor(vendor)
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = VendorEditorView.message(for: error)
        }
    }

    private static func message(for error: any Error) -> String {
        guard let localized = error as? any LocalizedError,
              let description = localized.errorDescription else {
            return error.localizedDescription
        }
        if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
            return description + " " + suggestion
        }
        return description
    }
}

// MARK: - Field

/// A labelled text field for the vendor form.
private struct VendorField: View {

    let title: String
    let placeholder: String
    @Binding var text: String
    var contentType: UITextContentType?
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var disablesAutocorrection: Bool = false
    var isMonospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(isMonospaced ? Typography.rowTitle.monospacedDigit() : Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .textContentType(contentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .submitLabel(.done)
                .frame(minHeight: Spacing.minimumTapTarget)
                .accessibilityLabel(Text(title))
        }
        .padding(.vertical, Spacing.xs)
    }
}
