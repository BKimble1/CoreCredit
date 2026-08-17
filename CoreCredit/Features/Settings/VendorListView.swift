//
//  VendorListView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// Every supplier the shop returns cores to.
///
/// The return window is shown on each row, not buried in the editor, because it is the number that
/// decides every deadline this app calculates. It belongs to the vendor and to nothing else: two
/// vendors on the same screen routinely disagree, and a single core can still override its own due
/// date in the core editor.
///
/// Retired vendors stay in the list under their own heading rather than disappearing. Their history
/// is still attached to real cores, and hiding them would make an old ledger entry look like a
/// mistake.
struct VendorListView: View {

    @Query private var vendors: [Vendor]

    @State private var searchText = ""
    @State private var isPresentingNewVendor = false

    init() { }

    var body: some View {
        Group {
            if vendors.isEmpty {
                emptyLedger
            } else if activeMatches.isEmpty && inactiveMatches.isEmpty {
                noMatches
            } else {
                vendorList
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Vendors")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Vendor, contact, or account number")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingNewVendor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier(A11y.Settings.addVendor)
                .accessibilityLabel(Text("Add vendor"))
                .accessibilityHint(Text("Adds a supplier you send cores back to."))
            }
        }
        .sheet(isPresented: $isPresentingNewVendor) {
            NavigationStack {
                VendorEditorView(vendor: nil)
            }
        }
    }

    // MARK: - List

    private var vendorList: some View {
        List {
            if !activeMatches.isEmpty {
                Section {
                    ForEach(activeMatches, id: \.id) { vendor in
                        vendorRow(vendor)
                    }
                } header: {
                    Text("Active")
                } footer: {
                    Text("Each vendor keeps its own return window. It is only the starting point "
                         + "for a new core's deadline — change it any time, and give an individual "
                         + "core its own due date in the core's own screen when the counter agrees "
                         + "to something different.")
                }
                .listRowBackground(Palette.surface)
            }

            if !inactiveMatches.isEmpty {
                Section {
                    ForEach(inactiveMatches, id: \.id) { vendor in
                        vendorRow(vendor)
                    }
                } header: {
                    Text("Retired")
                } footer: {
                    Text("Retired vendors are hidden when you log a new core, but they stay here "
                         + "and stay attached to the cores they already have.")
                }
                .listRowBackground(Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func vendorRow(_ vendor: Vendor) -> some View {
        NavigationLink {
            VendorEditorView(vendor: vendor)
        } label: {
            VendorRow(
                name: vendor.displayName,
                windowDays: vendor.defaultReturnWindowDays,
                detail: detailLine(for: vendor),
                coreCount: vendor.items.count,
                isActive: vendor.isActive
            )
        }
    }

    // MARK: - Empty states

    private var emptyLedger: some View {
        ScrollView {
            EmptyStateView(
                symbol: "building.2",
                title: "No vendors yet",
                message: "Add the parts suppliers you send old cores back to. Each one gets its "
                    + "own return window, which is what CoreCredit uses to work out when a core "
                    + "has to be back on their counter.",
                actionTitle: "Add a vendor",
                action: { isPresentingNewVendor = true }
            )
            .padding(.vertical, Spacing.xxl)
        }
    }

    private var noMatches: some View {
        ScrollView {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No vendors match",
                message: "Nothing matches \"" + trimmedSearch + "\". Clear the search to see every "
                    + "vendor again."
            )
            .padding(.vertical, Spacing.xxl)
        }
    }

    // MARK: - Filtering

    private var activeMatches: [Vendor] {
        sorted(matches.filter { $0.isActive })
    }

    private var inactiveMatches: [Vendor] {
        sorted(matches.filter { !$0.isActive })
    }

    private var matches: [Vendor] {
        let text = trimmedSearch
        guard !text.isEmpty else { return vendors }
        return vendors.filter { vendor in
            VendorListView.searchableText(for: vendor).localizedStandardContains(text)
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name first, then everything a counter person might be looked up by.
    private static func searchableText(for vendor: Vendor) -> String {
        [vendor.name, vendor.contactName, vendor.accountNumber, vendor.phone, vendor.email,
         vendor.notes]
            .joined(separator: " ")
    }

    private func sorted(_ list: [Vendor]) -> [Vendor] {
        list.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame { return lhs.createdAt < rhs.createdAt }
            return comparison == .orderedAscending
        }
    }

    /// The second line of a row: whoever answers the phone, or the account number, or nothing.
    private func detailLine(for vendor: Vendor) -> String {
        var parts: [String] = []

        let contact = vendor.contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contact.isEmpty { parts.append(contact) }

        let account = vendor.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !account.isEmpty { parts.append("Account " + account) }

        return parts.joined(separator: " • ")
    }
}

// MARK: - Row

/// One vendor: its name, its own return window, and how much of the ledger is pointed at it.
///
/// "Retired" is spelled out in words next to a paused glyph. The dimmer colour is a second signal,
/// never the only one.
private struct VendorRow: View {

    let name: String
    let windowDays: Int
    let detail: String
    let coreCount: Int
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(name)
                    .font(Typography.rowTitle)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.s)

                if !isActive {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "pause.circle")
                            .imageScale(.small)
                        Text("Retired")
                            .font(Typography.caption)
                    }
                    .foregroundStyle(Palette.muted)
                }
            }

            Text(windowText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !detail.isEmpty {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(spokenValue))
        .accessibilityHint(Text("Opens this vendor's details."))
    }

    private var windowText: String {
        let days = windowDays == 1 ? "1-day" : String(windowDays) + "-day"
        let cores = coreCount == 1 ? "1 core" : String(coreCount) + " cores"
        return days + " return window • " + cores
    }

    private var spokenValue: String {
        var phrase = windowDays == 1
            ? "1 day return window"
            : String(windowDays) + " day return window"
        phrase += coreCount == 1 ? ", 1 core" : ", " + String(coreCount) + " cores"
        if !isActive { phrase += ", retired" }
        if !detail.isEmpty { phrase += ", " + detail }
        return phrase
    }
}
