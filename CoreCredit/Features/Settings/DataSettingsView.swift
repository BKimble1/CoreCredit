//
//  DataSettingsView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI
// `.json` for the backup importer's allowed content types.
import UniformTypeIdentifiers

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

    /// The system file importer.
    @State private var isChoosingBackupFile = false

    /// A validated, not-yet-applied restore. Non-`nil` means the preflight is on screen and the
    /// ledger has not been touched.
    @State private var restorePlan: BackupRestorePlan?

    /// True only while the single save is in flight, so the action cannot be double-tapped.
    @State private var isRestoring = false

    /// Set after a restore lands, so the screen says so rather than just emptying and refilling.
    @State private var restoreConfirmation: String?

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

                if let restoreConfirmation = restoreConfirmation {
                    Section {
                        ConfirmationBanner(message: restoreConfirmation,
                                           systemImage: "arrow.down.doc",
                                           onDismiss: { self.restoreConfirmation = nil })
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
                restoreSection
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
        // `.json` only. A backup this app wrote is a JSON file, and narrowing the picker is the
        // cheapest way to stop somebody choosing a photo and being told it is not a backup.
        .fileImporter(isPresented: $isChoosingBackupFile,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleBackupSelection(result)
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

    // MARK: - Restore

    /// Reading a backup file back in.
    ///
    /// Three deliberate steps, in this order, because this is the one action in the app that can
    /// destroy a ledger on purpose:
    ///
    /// 1. **Choose a file.** The system importer, restricted to JSON.
    /// 2. **Read what is in it.** `BackupRestoreService.plan(from:)` decodes and checks the file
    ///    and reports what it holds — before anything is deleted. Every rejection happens here.
    /// 3. **Confirm the replacement.** The counts of what is coming in and what is going out are
    ///    both on screen, and the destructive button restates what it does.
    private var restoreSection: some View {
        Section {
            if let plan = restorePlan {
                restorePreflight(plan)
            } else {
                Button {
                    isChoosingBackupFile = true
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "arrow.down.doc")
                            .imageScale(.medium)
                            .accessibilityHidden(true)
                        Text("Restore from backup")
                            .font(.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.s)
                    }
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget,
                           alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRestoring)
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier(A11y.Data.restore)
                .accessibilityLabel(Text("Restore from backup"))
                .accessibilityHint(Text("Choose a backup file. Nothing changes until you confirm."))
            }
        } header: {
            Text("Restore")
        } footer: {
            Text(restoreFooterText)
        }
    }

    /// What the file holds, what it would replace, and the two ways out.
    @ViewBuilder
    private func restorePreflight(_ plan: BackupRestorePlan) -> some View {
        let summary = plan.summary

        VStack(alignment: .leading, spacing: Spacing.s) {
            LabeledValueRow("From", value: summary.shopName, symbol: "storefront")
            LabeledValueRow("Written",
                            value: summary.exportedAt.formatted(date: .abbreviated, time: .shortened),
                            symbol: "calendar")
            LabeledValueRow("Cores", value: String(summary.itemCount), symbol: "shippingbox")
            LabeledValueRow("Vendors", value: String(summary.vendorCount), symbol: "building.2")
            LabeledValueRow("Bins", value: String(summary.binCount), symbol: "tray.full")
            LabeledValueRow("Returns", value: String(summary.batchCount), symbol: "arrow.uturn.left")
            LabeledValueRow("History entries", value: String(summary.eventCount), symbol: "clock")
            LabeledValueRow("Money at risk in this file",
                            value: summary.moneyAtRisk.formatted(currencyCode: currencyCode),
                            symbol: "dollarsign.circle")
        }
        .padding(.vertical, Spacing.xs)
        .listRowBackground(Palette.surface)
        .accessibilityIdentifier(A11y.Data.restorePreflight)

        Text(restoreReplacementWarning(summary))
            .font(.subheadline)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .listRowBackground(Palette.surface)

        DestructiveConfirmButton(
            title: "Replace everything with this backup",
            confirmationTitle: "Replace everything",
            message: restoreFinalMessage(summary),
            action: { performRestore(plan) }
        )
        .listRowBackground(Color.clear)
        .listRowInsets(DataSettingsView.buttonInsets)

        Button {
            restorePlan = nil
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
        .accessibilityIdentifier(A11y.Data.restoreCancel)
        .accessibilityLabel(Text("Cancel the restore"))
    }

    private var restoreFooterText: String {
        "Reads a backup file this app wrote. A restore REPLACES everything on this device — it is "
            + "not a merge, and it cannot be undone. Evidence photos are not stored in a backup "
            + "file and cannot be restored from one; your device backup does keep them."
    }

    private func restoreReplacementWarning(_ summary: BackupRestoreSummary) -> String {
        let existing = summary.existingItemCount
        let replaced = existing == 1 ? "1 core" : String(existing) + " cores"
        if existing == 0 {
            return "There is nothing on this device to replace. Restoring adds the records above."
        }
        return "Restoring deletes the " + replaced + " currently on this device, and everything "
            + "attached to them, and puts the records above in their place. This cannot be undone."
    }

    private func restoreFinalMessage(_ summary: BackupRestoreSummary) -> String {
        "Everything on this device is replaced by the "
            + String(summary.itemCount)
            + " cores in this file. Evidence photos are not restored. This cannot be undone."
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
    // MARK: - Restore

    /// Reads the chosen file and validates it. Nothing is written, and nothing is deleted.
    private func handleBackupSelection(_ result: Result<[URL], any Error>) {
        restoreConfirmation = nil
        switch result {
        case .failure(let error):
            // Cancelling the picker is not a failure worth shouting about, but a genuine one is.
            errorMessage = DataSettingsView.message(for: error)
        case .success(let urls):
            guard let url = urls.first else { return }
            loadBackup(at: url)
        }
    }

    private func loadBackup(at url: URL) {
        // A file chosen through the importer lives outside the app's container, so it has to be
        // opened inside a security scope. Without this the read fails with a permission error on a
        // real device while working perfectly in the simulator.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            errorMessage = DataSettingsView.message(
                for: BackupRestoreError.unreadableFile(String(describing: error))
            )
            return
        }

        do {
            restorePlan = try restoreService.plan(from: data)
            errorMessage = nil
        } catch {
            restorePlan = nil
            errorMessage = DataSettingsView.message(for: error)
        }
    }

    /// Applies an already-confirmed plan, then puts the app back into a consistent state.
    private func performRestore(_ plan: BackupRestorePlan) {
        guard isRestoring == false else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try restoreService.restore(plan)

            restorePlan = nil
            errorMessage = nil
            didErase = false
            isEraseArmed = false
            restoreConfirmation = DataSettingsView.restoredMessage(plan.summary)

            // The queue was built from records that no longer exist. Rebuilding it from the store
            // is what stops a reminder firing for a core the shop has just replaced — and what
            // schedules the deadlines the restored ledger actually has.
            let reminders = appEnvironment.reminders
            let context = modelContext
            Task {
                await reminders.cancelAll()
                await reminders.refreshFromStore(context)
            }
        } catch {
            // The service rolled the whole transaction back; the ledger is untouched. Keep the
            // preflight on screen so the owner can read the error and try the same file again.
            errorMessage = DataSettingsView.message(for: error)
        }
    }

    private var restoreService: BackupRestoreService {
        BackupRestoreService(context: modelContext, dateProvider: appEnvironment.dateProvider)
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private static func restoredMessage(_ summary: BackupRestoreSummary) -> String {
        let cores = summary.itemCount == 1 ? "1 core" : String(summary.itemCount) + " cores"
        return "Restored " + cores + " from the backup. Evidence photos are not part of a backup "
            + "file and were not restored."
    }

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
