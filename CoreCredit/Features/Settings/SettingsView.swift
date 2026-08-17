//
//  SettingsView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The Settings tab: one grouped list that leads to everything a shop can change.
///
/// The list is deliberately flat and boring. Each row says what it is and what it is currently set
/// to, so an owner can answer "is that switched on?" without opening the screen. Nothing is
/// configured here directly — every setting lives on its own screen where there is room to explain
/// what it does.
///
/// Rows are `NavigationLink { destination } label: { row }` rather than typed navigation
/// destinations, because on iPad these screens share a `NavigationSplitView` column with other
/// features' stacks and a value-typed destination registered here would be ambiguous there.
struct SettingsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [ShopProfile]
    @Query private var vendors: [Vendor]
    @Query private var bins: [StorageBin]

    @State private var errorMessage: String?

    init() { }

    var body: some View {
        List {
            errorSection
            shopSection
            remindersSection
            planSection
            dataSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .accessibilityIdentifier(A11y.Settings.root)
        .task { ensureProfileExists() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage = errorMessage {
            Section {
                ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
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
    }

    private var shopSection: some View {
        Section {
            NavigationLink {
                ShopProfileEditor()
            } label: {
                SettingsRow(
                    title: "Shop profile",
                    value: shopSummary,
                    symbol: "storefront",
                    hint: "Name, contact details, address, and the currency the ledger is kept in."
                )
            }

            NavigationLink {
                VendorListView()
            } label: {
                SettingsRow(
                    title: "Vendors",
                    value: vendorSummary,
                    symbol: "building.2",
                    hint: "Suppliers you return cores to, and each one's own return window."
                )
            }
            .accessibilityIdentifier(A11y.Settings.vendors)

            NavigationLink {
                BinListView()
            } label: {
                SettingsRow(
                    title: "Storage bins",
                    value: binSummary,
                    symbol: "tray.full",
                    hint: "Shelves, cages, and totes where old cores sit until they go back."
                )
            }
        } header: {
            Text("Shop")
        } footer: {
            Text("Vendors and bins are shared by every core you log, so it is worth setting them "
                 + "up once the way the shop actually works.")
        }
        .listRowBackground(Palette.surface)
    }

    private var remindersSection: some View {
        Section {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                SettingsRow(
                    title: "Notifications",
                    value: reminderSummary,
                    symbol: "bell",
                    hint: "Choose whether to be reminded before a core's return window closes, "
                        + "and when."
                )
            }
        } header: {
            Text("Reminders")
        }
        .listRowBackground(Palette.surface)
    }

    private var planSection: some View {
        Section {
            NavigationLink {
                SubscriptionStatusView()
            } label: {
                SettingsRow(
                    title: "Subscription",
                    value: planSummary,
                    symbol: "person.crop.circle",
                    hint: "See the current plan, restore a purchase, or manage the subscription."
                )
            }
            .accessibilityIdentifier(A11y.Settings.subscription)
        } header: {
            Text("Plan")
        }
        .listRowBackground(Palette.surface)
    }

    private var dataSection: some View {
        Section {
            NavigationLink {
                DataSettingsView()
            } label: {
                SettingsRow(
                    title: "Data & export",
                    value: "Spreadsheet export, backup file, erase",
                    symbol: "square.and.arrow.up",
                    hint: "Export the ledger, save a portable backup, or erase everything on this "
                        + "device."
                )
            }

            NavigationLink {
                AboutView()
            } label: {
                SettingsRow(
                    title: "About",
                    value: "Version " + AppConfiguration.versionDisplayString,
                    symbol: "info.circle",
                    hint: "Version, terms, privacy, and support."
                )
            }
        } header: {
            Text("App")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Summaries

    private var shopSummary: String {
        let profile = profiles.first
        let name = profile?.displayName ?? "Not set up yet"
        let currency = profile?.currencyCode ?? AppConfiguration.defaultCurrencyCode
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrency.isEmpty { return name }
        return name + " • " + trimmedCurrency
    }

    private var vendorSummary: String {
        if vendors.isEmpty { return "None added yet" }
        let active = vendors.reduce(into: 0) { total, vendor in
            if vendor.isActive { total += 1 }
        }
        let retired = vendors.count - active
        var summary = active == 1 ? "1 active" : String(active) + " active"
        if retired > 0 {
            summary += retired == 1 ? ", 1 retired" : ", " + String(retired) + " retired"
        }
        return summary
    }

    private var binSummary: String {
        if bins.isEmpty { return "None added yet" }
        let active = bins.reduce(into: 0) { total, bin in
            if bin.isActive { total += 1 }
        }
        let retired = bins.count - active
        var summary = active == 1 ? "1 active" : String(active) + " active"
        if retired > 0 {
            summary += retired == 1 ? ", 1 retired" : ", " + String(retired) + " retired"
        }
        return summary
    }

    private var reminderSummary: String {
        guard let profile = profiles.first else { return "Not set up yet" }
        guard profile.remindersEnabled else { return "Off" }

        let lead = profile.reminderLeadDays
        if lead <= 0 { return "On, on the day a core is due" }
        if lead == 1 { return "On, 1 day before a deadline" }
        return "On, " + String(lead) + " days before a deadline"
    }

    private var planSummary: String {
        appEnvironment.subscriptions.entitlement.tier.displayName
    }

    // MARK: - Loading

    /// Makes sure the single shop profile row exists before any child screen tries to bind to it.
    ///
    /// `CoreItemService.shopProfile()` creates it lazily, so this is a no-op on every launch after
    /// the first. A failure here is surfaced rather than swallowed: if the store cannot be written
    /// to, saving a setting would fail too and the owner should know before they try.
    private func ensureProfileExists() {
        guard profiles.isEmpty else { return }
        do {
            _ = try appEnvironment.itemService(modelContext).shopProfile()
            errorMessage = nil
        } catch {
            errorMessage = SettingsView.message(for: error)
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

// MARK: - Row

/// One line in the settings list: glyph, what it is, and what it is currently set to.
///
/// Collapsed into a single accessibility element so VoiceOver reads "Vendors, 3 active" as one
/// phrase instead of three, and the whole row keeps the 44-point minimum height.
private struct SettingsRow: View {

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
