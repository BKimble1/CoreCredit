//
//  DataSettingsView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// Getting the ledger out of the app, and — deliberately last, deliberately awkward — erasing it.
///
/// # Three exports, three jobs
///
/// The CSV is for a person: it opens in any spreadsheet and is what an owner sends a bookkeeper.
/// The ledger summary PDF is for a conversation: totals first, then one row per core, on a page
/// that can be printed and put in front of someone. The JSON backup is for the data: it carries
/// every field the app stores, including the timeline, so a copy of the ledger exists somewhere
/// other than one phone.
///
/// # Presentation lives here
///
/// `ExportCoordinator` only writes the file and publishes `presentedDocument`; the share sheet is
/// this screen's job. Because that coordinator is shared with the rest of the app, the sheet is
/// gated behind `isAwaitingExport` — a document produced by the core detail screen must never pop
/// a share sheet over Settings.
///
/// # Erasing says exactly what it destroys
///
/// "Delete all local data" is confirmed twice and spelled out in full, because it is the one action
/// in CoreCredit that cannot be undone from inside the app.
struct DataSettingsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [ShopProfile]
    @Query private var items: [CoreItem]
    @Query private var vendors: [Vendor]
    @Query private var bins: [StorageBin]
    @Query private var batches: [ReturnBatch]

    @State private var isAwaitingExport = false
    @State private var isEraseArmed = false
    @State private var didErase = false
    @State private var errorMessage: String?

    init() { }

    var body: some View {
        ZStack {
            Form {
                if let errorMessage = errorMessage {
                    Section {
                        ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                            .listRowBackground(Color.clear)
                    }
                }

                if isAwaitingExport, let exportError = appEnvironment.exports.lastError {
                    Section {
                        ErrorBanner(
                            message: exportError,
                            onDismiss: {
                                appEnvironment.exports.clearError()
                                isAwaitingExport = false
                            }
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                summarySection
                csvSection
                ledgerPDFSection
                backupSection
                eraseSection
            }
            .scrollContentBackground(.hidden)

            if isAwaitingExport && appEnvironment.exports.inFlight {
                LoadingOverlay(message: "Preparing the file…")
            }
        }
        .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Data & export")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: exportDocumentBinding) { document in
            shareSheet(for: document)
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            LabeledValueRow("Shop", value: shopName, symbol: "storefront")
            LabeledValueRow("Cores", value: String(items.count), symbol: "shippingbox")
            LabeledValueRow("Vendors", value: String(vendors.count), symbol: "building.2")
            LabeledValueRow("Bins", value: String(bins.count), symbol: "tray.full")
            LabeledValueRow("Returns", value: String(batches.count), symbol: "arrow.uturn.left")
        } header: {
            Text("On this device")
        } footer: {
            Text("Everything CoreCredit knows is stored here, in the app's own storage on this "
                 + "device. Exports are copies you make on purpose.")
        }
        .listRowBackground(Palette.surface)
    }

    private var shopName: String {
        profiles.first?.displayName ?? "Not set up yet"
    }

    // MARK: - CSV

    private var csvSection: some View {
        Section {
            Button {
                exportCSV()
            } label: {
                PrimaryButtonLabel("Export all cores as CSV", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty || appEnvironment.exports.inFlight)
            .listRowBackground(Color.clear)
            .listRowInsets(DataSettingsView.buttonInsets)
            .accessibilityIdentifier(A11y.Settings.exportCSV)
            .accessibilityLabel(Text("Export all cores as CSV"))
            .accessibilityHint(Text("Writes a spreadsheet file of the whole ledger and opens the "
                                    + "share sheet."))
        } header: {
            Text("Spreadsheet export")
        } footer: {
            Text(csvFooterText)
        }
    }

    // MARK: - Ledger summary

    private var ledgerPDFSection: some View {
        Section {
            Button {
                exportLedgerPDF()
            } label: {
                PrimaryButtonLabel("Ledger summary (PDF)", systemImage: "doc.richtext")
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty || appEnvironment.exports.inFlight)
            .listRowBackground(Color.clear)
            .listRowInsets(DataSettingsView.buttonInsets)
            .accessibilityLabel(Text("Ledger summary PDF"))
            .accessibilityHint(Text("Writes a printable page of the ledger totals and every core, "
                                    + "then opens the share sheet."))
        } header: {
            Text("Printable summary")
        } footer: {
            Text(ledgerPDFFooterText)
        }
    }

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                PrimaryButtonLabel("Save a backup file", systemImage: "externaldrive")
            }
            .buttonStyle(.plain)
            .disabled(appEnvironment.exports.inFlight)
            .listRowBackground(Color.clear)
            .listRowInsets(DataSettingsView.buttonInsets)
            .accessibilityLabel(Text("Save a backup file"))
            .accessibilityHint(Text("Writes a JSON backup of everything and opens the share sheet."))
        } header: {
            Text("Backup")
        } footer: {
            Text(backupFooterText)
        }
    }

    // MARK: - Erase

    /// Erasing takes three deliberate taps and shows the consequences in between.
    ///
    /// The first tap only *reveals* the warning and the real button — it destroys nothing. That is
    /// the first confirmation; the destructive button's own dialog is the second. Two separate
    /// confirmations, and no modal presented on top of another one.
    private var eraseSection: some View {
        Section {
            if isEraseArmed {
                Text(eraseConfirmationMessage)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
                    .listRowBackground(Palette.surface)

                DestructiveConfirmButton(
                    title: "Erase everything now",
                    confirmationTitle: "Erase everything",
                    message: eraseFinalMessage,
                    action: { eraseEverything() }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(DataSettingsView.buttonInsets)

                Button {
                    isEraseArmed = false
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(DataSettingsView.buttonInsets)
                .accessibilityLabel(Text("Cancel erasing"))
            } else {
                Button {
                    isEraseArmed = true
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "trash")
                            .imageScale(.medium)
                            .accessibilityHidden(true)
                        Text("Delete all local data")
                            .font(.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.s)
                    }
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.surface)
                .accessibilityLabel(Text("Delete all local data"))
                .accessibilityHint(Text("Shows what erasing removes. Nothing is deleted until you "
                                        + "confirm twice."))
            }

            if didErase {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "checkmark.circle")
                        .imageScale(.medium)
                        .accessibilityHidden(true)
                    Text("Everything on this device has been erased.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Everything on this device has been erased."))
            }
        } header: {
            Text("Erase")
        } footer: {
            Text(eraseFooterText)
        }
    }

    // MARK: - Share sheet

    private func shareSheet(for document: ExportDocument) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text(shareHeadline(for: document))
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledValueRow("File", value: document.suggestedName, symbol: "doc")

                ShareLink(item: document.url) {
                    PrimaryButtonLabel("Share file", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Text("Send it to yourself, drop it in Files, or hand it to whichever app you keep "
                     + "shop records in. The copy on this device is cleaned up automatically after "
                     + "a day; anything you have already sent is yours to keep.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(shareTitle(for: document))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { closeShareSheet() }
                }
            }
        }
    }

    private func shareHeadline(for document: ExportDocument) -> String {
        switch document.kind {
        case .csv:
            return "The spreadsheet is ready."
        case .pdf:
            return "The ledger summary is ready."
        case .json:
            return "The backup file is ready."
        }
    }

    private func shareTitle(for document: ExportDocument) -> String {
        switch document.kind {
        case .csv:
            return "Spreadsheet"
        case .pdf:
            return "Ledger summary"
        case .json:
            return "Backup"
        }
    }

    // MARK: - Actions

    private func exportCSV() {
        do {
            let profile = try appEnvironment.itemService(modelContext).shopProfile()
            errorMessage = nil
            isAwaitingExport = true

            let exports = appEnvironment.exports
            let ledger = items
            Task {
                await exports.exportCSVLedger(items: ledger, profile: profile)
            }
        } catch {
            errorMessage = DataSettingsView.message(for: error)
        }
    }

    private func exportLedgerPDF() {
        do {
            let profile = try appEnvironment.itemService(modelContext).shopProfile()
            errorMessage = nil
            isAwaitingExport = true

            let exports = appEnvironment.exports
            let ledger = items
            Task {
                await exports.exportLedgerPDF(items: ledger, profile: profile)
            }
        } catch {
            errorMessage = DataSettingsView.message(for: error)
        }
    }

    private func exportBackup() {
        do {
            let profile = try appEnvironment.itemService(modelContext).shopProfile()
            errorMessage = nil
            isAwaitingExport = true

            let exports = appEnvironment.exports
            let allVendors = vendors
            let allBins = bins
            let ledger = items
            let allBatches = batches
            Task {
                await exports.exportJSONBackup(
                    profile: profile,
                    vendors: allVendors,
                    bins: allBins,
                    items: ledger,
                    batches: allBatches
                )
            }
        } catch {
            errorMessage = DataSettingsView.message(for: error)
        }
    }

    /// Erases the store, then drops every queued reminder — a notification for a core that no
    /// longer exists would be the app lying about data it has just destroyed.
    private func eraseEverything() {
        do {
            try ModelContainerFactory.deleteAllData(in: modelContext)
            errorMessage = nil
            didErase = true
            isEraseArmed = false

            let reminders = appEnvironment.reminders
            Task {
                await reminders.cancelAll()
            }
        } catch {
            didErase = false
            errorMessage = DataSettingsView.message(for: error)
        }
    }

    private func closeShareSheet() {
        isAwaitingExport = false
        appEnvironment.exports.dismiss()
    }

    // MARK: - Copy

    private var csvFooterText: String {
        var text = "One row per core, with the part, the vendor, the references, the dates, the "
        text += "expected credit, whatever was actually credited, and the current status. "
        text += "Amounts are written as plain figures such as 86.50 — no currency symbol and no "
        text += "grouping separators — so the file opens correctly in any spreadsheet, anywhere. "

        if items.isEmpty {
            text += "There is nothing to export yet: no cores have been logged."
        } else {
            text += "This export covers all "
            text += items.count == 1 ? "1 core" : String(items.count) + " cores"
            text += " in the ledger, on any plan."
        }
        return text
    }

    private var ledgerPDFFooterText: String {
        var text = "A printable page you can hand to someone. The totals come first — the money "
        text += "still at risk, how many cores are unresolved, how many are past their return "
        text += "deadline, and how the outstanding money splits across the aging buckets — then "
        text += "one row per core with the part, the vendor, the status, the due date, the core "
        text += "charge, and whatever has been credited so far. "

        if items.isEmpty {
            text += "There is nothing to summarise yet: no cores have been logged."
        } else {
            text += "This summary covers all "
            text += items.count == 1 ? "1 core" : String(items.count) + " cores"
            text += " in the ledger."
        }
        return text
    }

    private var backupFooterText: String {
        var text = "A single JSON file holding the shop profile, every vendor and bin, every core "
        text += "with its full status timeline, and every return batch. It is the documented "
        text += "backup format (version "
        text += String(BackupPayload.currentFormatVersion)
        text += "): plain text, sorted keys, ISO 8601 dates, amounts in exact cents. "
        text += "Photographs are not included — they are large, and this file is meant to be easy "
        text += "to keep and to read. Keep a copy somewhere other than this device."
        return text
    }

    private var eraseConfirmationMessage: String {
        var text = "This permanently removes every core, photo, timeline entry, vendor, bin, "
        text += "return batch, and your shop details from this device. "
        text += "It cannot be undone from inside CoreCredit. "
        text += "Files you have already exported or shared are not affected. "
        text += "If you have not saved a backup file yet, cancel and do that first. "
        text += "You will be asked once more to confirm."
        return text
    }

    private var eraseFinalMessage: String {
        var text = "Last chance. "
        text += summaryPhrase
        text += " will be deleted from this device and cannot be recovered from inside the app."
        return text
    }

    private var eraseFooterText: String {
        var text = "Use this when you are handing the device on, or starting the ledger again from "
        text += "scratch. It does not cancel a subscription and it does not touch anything you "
        text += "have already exported or shared. Queued reminders are cancelled as well."
        return text
    }

    /// "6 cores, 2 vendors, 2 bins and 1 return" — the real numbers, so the confirmation is about
    /// this shop's data rather than an abstraction.
    private var summaryPhrase: String {
        var parts: [String] = []
        parts.append(items.count == 1 ? "1 core" : String(items.count) + " cores")
        parts.append(vendors.count == 1 ? "1 vendor" : String(vendors.count) + " vendors")
        parts.append(bins.count == 1 ? "1 bin" : String(bins.count) + " bins")
        parts.append(batches.count == 1 ? "1 return" : String(batches.count) + " returns")

        guard let last = parts.last else { return "Everything stored here" }
        let leading = parts.dropLast().joined(separator: ", ")
        if leading.isEmpty { return last }
        return leading + " and " + last
    }

    // MARK: - Bindings

    /// Only ever presents a document this screen asked for.
    private var exportDocumentBinding: Binding<ExportDocument?> {
        Binding(
            get: { isAwaitingExport ? appEnvironment.exports.presentedDocument : nil },
            set: { newValue in
                if newValue == nil { closeShareSheet() }
            }
        )
    }

    private static let buttonInsets = EdgeInsets(
        top: Spacing.s,
        leading: Spacing.l,
        bottom: Spacing.s,
        trailing: Spacing.l
    )

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
