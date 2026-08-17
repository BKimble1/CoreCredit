//
//  ShopProfileEditor.swift
//  CoreCredit
//

import SwiftData
import SwiftUI
import UIKit

/// The shop's own details: what goes on an exported ledger, a dispute packet, and a bin tag.
///
/// The screen edits a local copy and writes it back through `CoreItemService.updateShopProfile(_:)`
/// when Save is tapped, rather than binding controls straight at the SwiftData object. Two reasons:
/// a half-typed phone number never reaches the store, and the save is a single point where a
/// persistence failure can be caught and shown instead of disappearing.
///
/// Currency is one code for the whole ledger in this version. Formatting stays locale-aware — the
/// symbol, grouping, and decimal separator come from the device's language and region settings —
/// so choosing `CAD` on a device set to English (Canada) shows `$1,234.56`, not a raw code.
struct ShopProfileEditor: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var region = ""
    @State private var postalCode = ""
    @State private var currencyCode = AppConfiguration.defaultCurrencyCode

    @State private var hasLoaded = false
    @State private var didSave = false
    @State private var errorMessage: String?

    init() { }

    var body: some View {
        Form {
            if let errorMessage = errorMessage {
                Section {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                        .listRowBackground(Color.clear)
                }
            }

            identitySection
            contactSection
            addressSection
            currencySection
            saveSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Shop profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .font(.body.weight(.semibold))
                    .accessibilityHint(Text("Saves the shop details."))
            }
        }
        .onChange(of: editedFingerprint) { _, _ in
            // Any further typing means the "Saved." confirmation no longer describes what is
            // on screen, so it is withdrawn rather than left standing over unsaved edits.
            didSave = false
        }
        .task { load() }
    }

    /// Every editable value in one comparable string, used only to notice that something changed.
    private var editedFingerprint: String {
        [name, phone, email, addressLine1, addressLine2, city, region, postalCode, currencyCode]
            .joined(separator: "\u{1F}")
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            SettingsTextField(
                title: "Shop name",
                placeholder: "Sample Auto Service",
                text: $name,
                contentType: .organizationName,
                keyboardType: .default,
                autocapitalization: .words
            )
        } header: {
            Text("Shop")
        } footer: {
            Text("The shop name appears at the top of exported ledgers, dispute packets, and "
                 + "printed bin tags.")
        }
        .listRowBackground(Palette.surface)
    }

    private var contactSection: some View {
        Section {
            SettingsTextField(
                title: "Phone",
                placeholder: "555-0142",
                text: $phone,
                contentType: .telephoneNumber,
                keyboardType: .phonePad,
                autocapitalization: .never
            )

            SettingsTextField(
                title: "Email",
                placeholder: "service@yourshop.com",
                text: $email,
                contentType: .emailAddress,
                keyboardType: .emailAddress,
                autocapitalization: .never,
                disablesAutocorrection: true
            )
        } header: {
            Text("Contact")
        } footer: {
            Text("Printed on anything you hand a vendor, so a parts manager can call the right "
                 + "person back.")
        }
        .listRowBackground(Palette.surface)
    }

    private var addressSection: some View {
        Section {
            SettingsTextField(
                title: "Address line 1",
                placeholder: "18 Shop Lane",
                text: $addressLine1,
                contentType: .streetAddressLine1,
                keyboardType: .default,
                autocapitalization: .words
            )

            SettingsTextField(
                title: "Address line 2",
                placeholder: "Unit B",
                text: $addressLine2,
                contentType: .streetAddressLine2,
                keyboardType: .default,
                autocapitalization: .words
            )

            SettingsTextField(
                title: "City",
                placeholder: "Columbus",
                text: $city,
                contentType: .addressCity,
                keyboardType: .default,
                autocapitalization: .words
            )

            SettingsTextField(
                title: "State or region",
                placeholder: "OH",
                text: $region,
                contentType: .addressState,
                keyboardType: .default,
                autocapitalization: .characters
            )

            SettingsTextField(
                title: "Postal code",
                placeholder: "43004",
                text: $postalCode,
                contentType: .postalCode,
                keyboardType: .numbersAndPunctuation,
                autocapitalization: .characters,
                disablesAutocorrection: true
            )
        } header: {
            Text("Address")
        }
        .listRowBackground(Palette.surface)
    }

    private var currencySection: some View {
        Section {
            Picker(selection: $currencyCode) {
                ForEach(currencyOptions) { option in
                    Text(option.displayName).tag(option.code)
                }
            } label: {
                Text("Currency")
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
            }
            .pickerStyle(.menu)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Ledger currency"))
            .accessibilityValue(Text(currencyCode))
            .accessibilityHint(Text("The currency every core charge in this ledger is recorded in."))

            LabeledValueRow("Example amount", value: exampleAmountText, isMonospaced: true)
        } header: {
            Text("Currency")
        } footer: {
            Text(currencyFooterText)
        }
        .listRowBackground(Palette.surface)
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                PrimaryButtonLabel("Save shop profile", systemImage: "checkmark")
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

            if didSave {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "checkmark.circle")
                        .imageScale(.medium)
                        .accessibilityHidden(true)
                    Text("Saved.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Shop profile saved."))
            }
        } footer: {
            Text("Nothing here is sent anywhere. These details are stored on this device and are "
                 + "only used to fill in the exports and labels you produce yourself.")
        }
    }

    // MARK: - Currency options

    /// The picker's list: a short set of currencies a shop is realistically kept in, plus this
    /// device's own currency and whatever is already stored, so an existing choice can never
    /// silently disappear from the list it is selected in.
    private var currencyOptions: [CurrencyOption] {
        var codes = ShopProfileEditor.baseCurrencyCodes

        if let deviceCode = ShopProfileEditor.deviceCurrencyCode, !codes.contains(deviceCode) {
            codes.append(deviceCode)
        }

        let stored = normalisedCurrencyCode
        if !codes.contains(stored) {
            codes.append(stored)
        }

        return codes.map { CurrencyOption(code: $0) }
    }

    private var normalisedCurrencyCode: String {
        let trimmed = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? AppConfiguration.defaultCurrencyCode : trimmed
    }

    /// A worked example in the selected currency, formatted exactly the way the ledger will format
    /// it. Showing it beats describing it: the owner can see the symbol and separators immediately.
    private var exampleAmountText: String {
        Money(cents: 8_650).formatted(currencyCode: normalisedCurrencyCode)
    }

    private var currencyFooterText: String {
        var text = "CoreCredit keeps one currency for the whole ledger. "
        text += "Amounts are still formatted using this device's language and region settings, "
        text += "so they read the way money reads everywhere else on the device."

        guard let deviceCode = ShopProfileEditor.deviceCurrencyCode else { return text }

        if deviceCode == normalisedCurrencyCode {
            text += " This device's own currency is "
            text += deviceCode
            text += ", which matches the ledger."
            return text
        }

        text += " This device's own currency is "
        text += deviceCode
        text += ", which is not the ledger currency. That is fine if the shop bills in "
        text += normalisedCurrencyCode
        text += "."
        return text
    }

    /// The device's currency code, uppercased. `nil` when the region provides none.
    private static var deviceCurrencyCode: String? {
        guard let identifier = Locale.current.currency?.identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Ordered so the currencies an independent repair shop is most likely to bill in come first.
    private static let baseCurrencyCodes = [
        "USD", "CAD", "MXN", "GBP", "EUR", "AUD", "NZD",
        "CHF", "DKK", "NOK", "SEK", "PLN", "CZK",
        "ZAR", "INR", "SGD", "HKD", "JPY", "BRL", "AED"
    ]

    // MARK: - Load and save

    /// Copies the stored profile into the editing fields exactly once.
    ///
    /// The guard matters: `task` can run again after a background/foreground cycle, and reloading
    /// would throw away whatever the owner had half-typed.
    private func load() {
        guard !hasLoaded else { return }
        do {
            let profile = try appEnvironment.itemService(modelContext).shopProfile()
            name = profile.name
            phone = profile.phone
            email = profile.email
            addressLine1 = profile.addressLine1
            addressLine2 = profile.addressLine2
            city = profile.city
            region = profile.region
            postalCode = profile.postalCode

            let stored = profile.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
            currencyCode = stored.isEmpty
                ? (ShopProfileEditor.deviceCurrencyCode ?? AppConfiguration.defaultCurrencyCode)
                : stored.uppercased()

            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = ShopProfileEditor.message(for: error)
        }
    }

    private func save() {
        let service = appEnvironment.itemService(modelContext)
        do {
            let profile = try service.shopProfile()
            profile.name = trimmed(name)
            profile.phone = trimmed(phone)
            profile.email = trimmed(email)
            profile.addressLine1 = trimmed(addressLine1)
            profile.addressLine2 = trimmed(addressLine2)
            profile.city = trimmed(city)
            profile.region = trimmed(region)
            profile.postalCode = trimmed(postalCode)
            profile.currencyCode = normalisedCurrencyCode

            try service.updateShopProfile(profile)

            errorMessage = nil
            didSave = true
        } catch {
            didSave = false
            errorMessage = ShopProfileEditor.message(for: error)
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Currency option

/// One entry in the currency picker: the ISO code, plus the device's own name for it when it has
/// one ("USD — US Dollar"). Falling back to the bare code keeps the row honest rather than blank.
private struct CurrencyOption: Identifiable, Hashable {

    let code: String

    var id: String { code }

    var displayName: String {
        guard let localized = Locale.current.localizedString(forCurrencyCode: code),
              !localized.isEmpty,
              localized.caseInsensitiveCompare(code) != .orderedSame else {
            return code
        }
        return code + " — " + localized
    }
}

// MARK: - Field

/// A labelled text field sized for a settings form.
///
/// The label sits above the field rather than beside it so it never competes for width at large
/// Dynamic Type sizes, and it is hidden from VoiceOver because the field itself carries the label.
private struct SettingsTextField: View {

    let title: String
    let placeholder: String
    @Binding var text: String
    var contentType: UITextContentType?
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var disablesAutocorrection: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(Typography.rowTitle)
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
