//
//  CoreFilterSheet.swift
//  CoreCredit
//

import SwiftUI

/// The Cores screen's filter sheet: statuses, overdue-only, vendor, and a received-date range.
///
/// The sheet edits a **local copy** and only hands it back on Apply, so half-set criteria never
/// make the list flicker underneath, and Cancel is a genuine cancel. Search text passes straight
/// through untouched — it belongs to the search field, not to this sheet.
///
/// Nothing here computes a match. It builds a `CoreItemFilter` and the caller gives that to
/// `CoreItemQuery`.
struct CoreFilterSheet: View {

    @Environment(\.dismiss) private var dismiss

    private let vendors: [Vendor]
    private let searchText: String
    private let onApply: (CoreItemFilter) -> Void

    @State private var statuses: Set<CoreStatus>
    @State private var vendorIdentifier: UUID?
    @State private var onlyOverdue: Bool
    @State private var usesFromDate: Bool
    @State private var fromDate: Date
    @State private var usesToDate: Bool
    @State private var toDate: Date

    /// - Parameters:
    ///   - filter: The filter currently applied to the list.
    ///   - vendors: Vendors to offer in the picker, already ordered.
    ///   - now: `AppEnvironment.dateProvider.now`, used as the starting point for the date pickers
    ///     so the sheet never reads the system clock behind the injected one.
    ///   - onApply: Receives the new filter. Not called when the sheet is cancelled.
    init(filter: CoreItemFilter,
         vendors: [Vendor],
         now: Date,
         onApply: @escaping (CoreItemFilter) -> Void) {
        self.vendors = vendors
        self.searchText = filter.searchText
        self.onApply = onApply
        _statuses = State(initialValue: filter.statuses)
        _vendorIdentifier = State(initialValue: filter.vendorIdentifier)
        _onlyOverdue = State(initialValue: filter.onlyOverdue)
        _usesFromDate = State(initialValue: filter.receivedOnOrAfter != nil)
        _fromDate = State(initialValue: filter.receivedOnOrAfter ?? now)
        _usesToDate = State(initialValue: filter.receivedOnOrBefore != nil)
        _toDate = State(initialValue: filter.receivedOnOrBefore ?? now)
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                overdueSection
                vendorSection
                receivedSection
                clearSection
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        onApply(makeFilter())
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            ForEach(orderedStatuses) { status in
                statusRow(status)
            }
        } header: {
            Text("Status")
        } footer: {
            Text(statuses.isEmpty
                 ? "No status selected, so every status is shown."
                 : "Only the selected statuses are shown.")
        }
    }

    private func statusRow(_ status: CoreStatus) -> some View {
        let isSelected = statuses.contains(status)

        return Button {
            toggle(status)
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: status.symbolName)
                    .imageScale(.medium)
                    .foregroundStyle(Palette.color(for: status))
                    .frame(width: 24)

                Text(status.displayName)
                    .font(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.s)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
            }
            .frame(minHeight: Spacing.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(status.displayName))
        .accessibilityValue(Text(isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var overdueSection: some View {
        Section {
            Toggle(isOn: $onlyOverdue) {
                Label("Only overdue", systemImage: "exclamationmark.circle")
            }
            .frame(minHeight: Spacing.minimumTapTarget)
        } footer: {
            Text("Shows only open cores whose return window has already closed.")
        }
    }

    private var vendorSection: some View {
        Section {
            Picker(selection: $vendorIdentifier) {
                Text("Any vendor").tag(UUID?.none)
                ForEach(vendors, id: \.id) { vendor in
                    Text(vendor.displayName).tag(UUID?.some(vendor.id))
                }
            } label: {
                Label("Vendor", systemImage: "building.2")
            }
            .frame(minHeight: Spacing.minimumTapTarget)
        } header: {
            Text("Vendor")
        }
    }

    private var receivedSection: some View {
        Section {
            Toggle(isOn: $usesFromDate) {
                Text("Received on or after")
            }
            .frame(minHeight: Spacing.minimumTapTarget)

            if usesFromDate {
                DatePicker(
                    "Earliest received date",
                    selection: $fromDate,
                    displayedComponents: .date
                )
                .frame(minHeight: Spacing.minimumTapTarget)
            }

            Toggle(isOn: $usesToDate) {
                Text("Received on or before")
            }
            .frame(minHeight: Spacing.minimumTapTarget)

            if usesToDate {
                DatePicker(
                    "Latest received date",
                    selection: $toDate,
                    displayedComponents: .date
                )
                .frame(minHeight: Spacing.minimumTapTarget)
            }
        } header: {
            Text("Received")
        } footer: {
            Text("Both bounds are inclusive and compared by calendar day.")
        }
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                clearAll()
            } label: {
                Text("Clear all filters")
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
            }
            .disabled(!hasAnyCriteria)
        }
    }

    // MARK: - State

    private var orderedStatuses: [CoreStatus] {
        CoreStatus.allCases.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var hasAnyCriteria: Bool {
        makeFilter().isActive
    }

    private func toggle(_ status: CoreStatus) {
        if statuses.contains(status) {
            statuses.remove(status)
        } else {
            statuses.insert(status)
        }
    }

    private func clearAll() {
        statuses = []
        vendorIdentifier = nil
        onlyOverdue = false
        usesFromDate = false
        usesToDate = false
    }

    /// Builds the filter the list will actually run, preserving the caller's search text.
    private func makeFilter() -> CoreItemFilter {
        CoreItemFilter(
            searchText: searchText,
            statuses: statuses,
            vendorIdentifier: vendorIdentifier,
            onlyOverdue: onlyOverdue,
            receivedOnOrAfter: usesFromDate ? fromDate : nil,
            receivedOnOrBefore: usesToDate ? toDate : nil
        )
    }
}
