//
//  BinListView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The physical places old cores sit while they wait to go back: shelves, cages, totes, pallets.
///
/// A bin is a label and a hint about where to walk, nothing more. It carries no policy and no
/// deadline — it exists so that "where is that alternator?" has an answer at 7 a.m. with a customer
/// waiting.
///
/// Retiring a bin (Active off) hides it when logging a new core but keeps it attached to the cores
/// already stored there. Deleting one is explained in full before it happens: the relationship
/// nullifies, so the cores themselves always survive.
struct BinListView: View {

    @Query private var bins: [StorageBin]

    @State private var isPresentingNewBin = false

    init() { }

    var body: some View {
        Group {
            if bins.isEmpty {
                emptyState
            } else {
                binList
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Storage bins")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingNewBin = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add bin"))
                .accessibilityHint(Text("Adds a shelf, cage, or tote where cores are kept."))
            }
        }
        .sheet(isPresented: $isPresentingNewBin) {
            NavigationStack {
                BinEditor(bin: nil)
            }
        }
    }

    // MARK: - List

    private var binList: some View {
        List {
            if !activeBins.isEmpty {
                Section {
                    ForEach(activeBins, id: \.id) { bin in
                        binRow(bin)
                    }
                } header: {
                    Text("Active")
                } footer: {
                    Text("The bin label is printed on the core's tag and shown on its row in the "
                         + "ledger, so anyone in the shop can find the part without asking.")
                }
                .listRowBackground(Palette.surface)
            }

            if !retiredBins.isEmpty {
                Section {
                    ForEach(retiredBins, id: \.id) { bin in
                        binRow(bin)
                    }
                } header: {
                    Text("Retired")
                } footer: {
                    Text("Retired bins are hidden when you log a new core, but the cores already "
                         + "stored in them keep the label.")
                }
                .listRowBackground(Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func binRow(_ bin: StorageBin) -> some View {
        NavigationLink {
            BinEditor(bin: bin)
        } label: {
            BinRow(
                label: bin.displayName,
                locationNote: bin.locationNote.trimmingCharacters(in: .whitespacesAndNewlines),
                coreCount: bin.items.count,
                isActive: bin.isActive
            )
        }
    }

    private var emptyState: some View {
        ScrollView {
            EmptyStateView(
                symbol: "tray.full",
                title: "No bins yet",
                message: "Name the places you actually put old cores — \"A3\", \"Core cage\", "
                    + "\"Pallet by the roll-up door\". Every core you log can then say where it is "
                    + "sitting.",
                actionTitle: "Add a bin",
                action: { isPresentingNewBin = true }
            )
            .padding(.vertical, Spacing.xxl)
        }
    }

    // MARK: - Grouping

    private var activeBins: [StorageBin] {
        sorted(bins.filter { $0.isActive })
    }

    private var retiredBins: [StorageBin] {
        sorted(bins.filter { !$0.isActive })
    }

    private func sorted(_ list: [StorageBin]) -> [StorageBin] {
        list.sorted { lhs, rhs in
            let comparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
            if comparison == .orderedSame { return lhs.createdAt < rhs.createdAt }
            return comparison == .orderedAscending
        }
    }
}

// MARK: - Row

/// One bin: its label, where it is, and how many cores are on it.
private struct BinRow: View {

    let label: String
    let locationNote: String
    let coreCount: Int
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(label)
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

            Text(countText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            if !locationNote.isEmpty {
                Text(locationNote)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spokenValue))
        .accessibilityHint(Text("Opens this bin's details."))
    }

    private var countText: String {
        coreCount == 1 ? "1 core stored here" : String(coreCount) + " cores stored here"
    }

    private var spokenValue: String {
        var phrase = countText
        if !isActive { phrase += ", retired" }
        if !locationNote.isEmpty { phrase += ", " + locationNote }
        return phrase
    }
}

// MARK: - Editor

/// Add or edit one bin. Presented as a sheet when adding, pushed when editing an existing bin.
private struct BinEditor: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let bin: StorageBin?

    @State private var label = ""
    @State private var locationNote = ""
    @State private var isActive = true

    @State private var hasLoaded = false
    @State private var labelError: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let errorMessage = errorMessage {
                Section {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                        .listRowBackground(Color.clear)
                }
            }

            labelSection
            statusSection
            saveSection

            if bin != nil {
                deleteSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(bin == nil ? "New bin" : "Bin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                cancelButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .font(.body.weight(.semibold))
                    .accessibilityHint(Text("Saves this bin."))
            }
        }
        .task { load() }
    }

    /// Only a sheet needs a Cancel button; a pushed editor already has a back button.
    @ViewBuilder
    private var cancelButton: some View {
        if bin == nil {
            Button("Cancel") { dismiss() }
        }
    }

    // MARK: Sections

    private var labelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Label")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                TextField("A3", text: $label)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityLabel(Text("Bin label"))

                FormErrorText(labelError)
            }
            .padding(.vertical, Spacing.xs)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Where it is")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                TextField("Back wall, top shelf", text: $locationNote, axis: .vertical)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2...4)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityLabel(Text("Where this bin is"))
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Bin")
        } footer: {
            Text("Short labels work best — they end up on a printed tag and on every ledger row "
                 + "that uses this bin.")
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
            .accessibilityLabel(Text("Active bin"))
            .accessibilityHint(Text("Turn this off for a shelf you no longer use. The cores "
                                    + "already stored there keep the label."))
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
                PrimaryButtonLabel(bin == nil ? "Add bin" : "Save bin", systemImage: "checkmark")
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
                title: "Delete bin",
                confirmationTitle: "Delete bin",
                message: deletionMessage,
                action: { deleteBin() }
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

    // MARK: Copy

    private var binNameForCopy: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this bin" : trimmed
    }

    /// Says what happens to the cores on the shelf, with the real count in it.
    private var deletionMessage: String {
        let cores = bin?.items.count ?? 0

        var message = "Deleting "
        message += binNameForCopy
        message += " removes the bin from this list. "

        if cores == 0 {
            message += "No cores are stored in it, so nothing else changes. "
        } else {
            message += cores == 1 ? "The 1 core " : "The " + String(cores) + " cores "
            message += "stored in it stay in the ledger with their money, photos, and history "
            message += "intact — they simply stop showing a bin, and you can move them to another "
            message += "bin afterwards. "
        }

        message += "Deleting the bin itself cannot be undone. If you only want it to stop "
        message += "appearing when you log a core, turn Active off instead."
        return message
    }

    // MARK: Load and save

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true

        guard let bin = bin else { return }
        label = bin.label
        locationNote = bin.locationNote
        isActive = bin.isActive
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            labelError = "Give the bin a label, for example A3."
            return
        }
        labelError = nil

        let trimmedNote = locationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = appEnvironment.itemService(modelContext)

        do {
            let target: StorageBin
            if let existing = bin {
                target = existing
            } else {
                target = try service.createBin(label: trimmedLabel, locationNote: trimmedNote)
            }

            target.label = trimmedLabel
            target.locationNote = trimmedNote
            target.isActive = isActive

            try service.updateBin(target)

            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = BinEditor.message(for: error)
        }
    }

    private func deleteBin() {
        guard let bin = bin else { return }
        do {
            try appEnvironment.itemService(modelContext).deleteBin(bin)
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = BinEditor.message(for: error)
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
