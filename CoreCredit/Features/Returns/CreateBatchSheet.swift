//
//  CreateBatchSheet.swift
//  CoreCredit
//

import SwiftData
import SwiftUI
import UIKit

/// Sends a vendor's staged cores back in one hand-off.
///
/// **A batch is one vendor.** The vendor is fixed for the life of this sheet and the only
/// selectable cores are that vendor's `.readyToReturn` items, so there is no interaction that could
/// produce a mixed-vendor return. `ReturnBatchService` is still the authority — its
/// `.mixedVendorBatch`, `.emptyBatch`, and `.missingVendor` errors are caught and shown rather than
/// assumed impossible.
///
/// Confirming moves every selected core to **Returned — awaiting credit**. That status is still
/// unresolved: the money stays in Money at Risk until a real credit is recorded, and the
/// confirmation copy says so before the user taps.
struct CreateBatchSheet: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CoreItem.createdAt, order: .reverse) private var allItems: [CoreItem]
    @Query private var profiles: [ShopProfile]

    private let vendor: Vendor?

    @State private var selectedIdentifiers: Set<UUID>
    @State private var returnDate = Date()
    @State private var hasSeededReturnDate = false
    @State private var method: ReturnMethod = .counterDropOff
    @State private var reference = ""
    @State private var notes = ""
    @State private var receipt: Attachment?
    @State private var isPresentingReceiptPicker = false
    @State private var errorMessage: String?
    @State private var savedBatch: ReturnBatch?
    @State private var isSaving = false

    /// - Parameters:
    ///   - vendor: The single vendor this return goes back to. `nil` is handled with an explanation
    ///     rather than a crash, because `ReturnBatchService` requires a vendor.
    ///   - preselected: Cores to tick on open — normally the whole vendor group tapped on the
    ///     Returns screen. Only the identifiers are kept: the live list always comes from this
    ///     vendor's ready cores, so a preselected core belonging to anyone else is simply never
    ///     offered, and the selection is single-vendor by construction.
    init(vendor: Vendor?, preselected: [CoreItem]) {
        self.vendor = vendor
        _selectedIdentifiers = State(initialValue: Set(preselected.map { $0.id }))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    vendorCard

                    if vendor == nil {
                        missingVendorCard
                    } else {
                        selectionCard
                        detailsCard
                        receiptCard
                        confirmationCard
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
            // Confirm is the last thing on this sheet. A `ZStack` around a safe-area-ignoring
            // background grew past the home indicator and took that inset off the scroll view;
            // painting the background behind it instead leaves the inset where SwiftUI put it.
            .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
            .background {
                Palette.background.ignoresSafeArea()
            }
            .navigationTitle("New return")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityHint(Text("Closes without creating a return."))
                }
                // The only two text-entry sheets in this app that had no way out of the
                // keyboard. Every other one either carries this button or dismisses the keyboard
                // on a drag, and this sheet has a money field: a decimal pad has no return key, so
                // without this there is nothing to press and nothing to swipe.
                //
                // Resigning the first responder rather than clearing a `@FocusState`, because the
                // fields here keep their own — the same reason the core editor's Done needed it.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil,
                                                        from: nil,
                                                        for: nil)
                    }
                }
            }
            .onAppear {
                if hasSeededReturnDate == false {
                    returnDate = appEnvironment.dateProvider.now
                    hasSeededReturnDate = true
                }
            }
            .sheet(isPresented: $isPresentingReceiptPicker) {
                AttachmentPickerSheet(kind: .receipt) { captured in
                    receipt = captured
                }
            }
        }
    }

    // MARK: - Derived state

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    /// This vendor's cores that are ready to go back and are not already on another return.
    ///
    /// Filtering on the vendor here — rather than trusting `preselected` — is what makes a
    /// mixed-vendor batch unreachable from the UI.
    private var candidates: [CoreItem] {
        guard let vendor = vendor else { return [] }
        let vendorIdentifier = vendor.id
        let ready = allItems.filter { item in
            item.status == .readyToReturn
                && item.vendorIdentifier == vendorIdentifier
                && item.returnBatch == nil
        }
        return CoreItemQuery.sort(ready, by: .dueDateAscending)
    }

    /// Ready cores for this vendor that are already attached to another return, and therefore not
    /// offered here. Surfaced as a caption so the count is never silently wrong.
    private var alreadyOnAnotherReturnCount: Int {
        guard let vendor = vendor else { return 0 }
        let vendorIdentifier = vendor.id
        return allItems.reduce(into: 0) { total, item in
            if item.status == .readyToReturn
                && item.vendorIdentifier == vendorIdentifier
                && item.returnBatch != nil {
                total += 1
            }
        }
    }

    private var selectedItems: [CoreItem] {
        candidates.filter { selectedIdentifiers.contains($0.id) }
    }

    private var selectedTotal: Money {
        selectedItems.reduce(Money.zero) { partial, item in partial + item.expectedCredit }
    }

    private var isEverythingSelected: Bool {
        candidates.isEmpty == false && selectedItems.count == candidates.count
    }

    private var canConfirm: Bool {
        vendor != nil && selectedItems.isEmpty == false && isSaving == false && savedBatch == nil
    }

    // MARK: - Vendor

    private var vendorCard: some View {
        SectionCard(title: "Returning to", systemImage: "building.2") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(vendor?.displayName ?? "No vendor")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("One return, one vendor. Cores going back to anyone else stay on the Returns screen for their own trip.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var missingVendorCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ErrorBanner(message: ReturnsModel.message(for: DomainError.missingVendor))

                Button {
                    dismiss()
                } label: {
                    PrimaryButtonLabel("Close", systemImage: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Selection

    private var selectionCard: some View {
        SectionCard(title: "Cores going back", systemImage: CoreStatus.readyToReturn.symbolName) {
            if candidates.isEmpty {
                EmptyStateView(
                    symbol: CoreStatus.readyToReturn.symbolName,
                    title: "Nothing ready for this vendor",
                    message: "Mark a core Ready to return once the old unit is on the shelf, then come back and send it with the next trip."
                )
            } else {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(spacing: Spacing.m) {
                        Button {
                            toggleSelectAll()
                        } label: {
                            Text(isEverythingSelected ? "Select none" : "Select all")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.accent)
                                .frame(minHeight: Spacing.minimumTapTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: Spacing.s)

                        Text(selectionCountText)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }

                    VStack(spacing: Spacing.xs) {
                        ForEach(candidates, id: \.id) { item in
                            selectionRow(item)
                        }
                    }

                    Divider()
                        .overlay(Palette.hairline)

                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Text("Expected credit on this return")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: Spacing.s)

                        MoneyLabel(selectedTotal, currencyCode: currencyCode, style: .prominent)
                            .accessibilityLabel(Text("Expected credit on this return"))
                    }

                    if alreadyOnAnotherReturnCount > 0 {
                        Text(hiddenCoresNotice)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Explains the gap between "this vendor's ready cores" and "the cores listed here".
    private var hiddenCoresNotice: String {
        let count = alreadyOnAnotherReturnCount
        let verb = count == 1 ? " is" : " are"
        let pronoun = count == 1 ? "it isn't" : "they aren't"
        return ReturnsModel.coreCountText(count)
            + " for this vendor"
            + verb
            + " already on another return, so "
            + pronoun
            + " listed here."
    }

    private var selectionCountText: String {
        String(selectedItems.count) + " of " + String(candidates.count) + " selected"
    }

    private func selectionRow(_ item: CoreItem) -> some View {
        let isSelected = selectedIdentifiers.contains(item.id)

        return Button {
            toggle(item)
        } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(item.displayTitle)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = rowSubtitle(item) {
                        Text(subtitle)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Spacing.s)

                MoneyLabel(item.expectedCredit, currencyCode: currencyCode, style: .caption)
                    .accessibilityLabel(Text("Expected credit"))
            }
            .padding(.vertical, Spacing.s)
            .frame(minHeight: Spacing.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.displayTitle))
        .accessibilityValue(Text(isSelected ? "Included in this return" : "Not included"))
        .accessibilityHint(Text("Double tap to include or exclude this core."))
    }

    private func rowSubtitle(_ item: CoreItem) -> String? {
        var parts: [String] = []

        let partNumber = item.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if partNumber.isEmpty == false {
            parts.append(partNumber)
        }

        let invoice = item.invoiceReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if invoice.isEmpty == false {
            parts.append("Invoice " + invoice)
        }

        if let binLabel = item.binLabel {
            parts.append(binLabel)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Details

    private var detailsCard: some View {
        SectionCard(title: "Hand-off details", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: Spacing.l) {
                BatchFieldWell(title: "Return date") {
                    DatePicker(
                        "Return date",
                        selection: $returnDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Palette.accent)
                    .accessibilityLabel(Text("Return date"))
                }

                BatchFieldWell(title: "How it went back") {
                    Picker("How it went back", selection: $method) {
                        ForEach(ReturnMethod.allCases) { option in
                            Label(option.displayName, systemImage: option.symbolName)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(Palette.accent)
                    .accessibilityLabel(Text("How it went back"))
                }

                BatchFieldWell(
                    title: "Reference",
                    hint: "The return slip or pickup number from the counter."
                ) {
                    TextField("Return slip number", text: $reference)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier(A11y.Returns.reference)
                        .accessibilityLabel(Text("Return reference"))
                }

                BatchFieldWell(title: "Notes") {
                    TextField("Anything worth remembering", text: $notes, axis: .vertical)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2...5)
                        .accessibilityLabel(Text("Notes"))
                }
            }
        }
    }

    // MARK: - Receipt

    private var receiptCard: some View {
        SectionCard(title: "Return receipt", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Photograph the signed slip once. One receipt covers every core on this return, and it is the proof you will attach if a credit comes up short.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let receipt = receipt {
                    AttachmentStrip(attachments: [receipt], onDelete: { _ in
                        self.receipt = nil
                    })

                    Button {
                        self.receipt = nil
                    } label: {
                        BatchActionLabel(title: "Remove receipt photo", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        isPresentingReceiptPicker = true
                    } label: {
                        BatchActionLabel(title: "Add receipt photo", systemImage: "camera")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Attaches one photo to the whole return."))
                }
            }
        }
    }

    // MARK: - Confirmation

    private var confirmationCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(confirmationText)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = errorMessage {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                }

                Button {
                    confirm()
                } label: {
                    PrimaryButtonLabel(
                        savedBatch == nil ? "Create return" : "Done",
                        systemImage: savedBatch == nil ? "arrow.uturn.left" : "checkmark"
                    )
                }
                .buttonStyle(.plain)
                .disabled(savedBatch == nil && canConfirm == false)
                .accessibilityIdentifier(A11y.Returns.confirm)
                .accessibilityHint(Text(confirmationText))
            }
        }
    }

    private var confirmationText: String {
        if savedBatch != nil {
            return "The return was saved. Close this sheet to get back to the ledger."
        }

        let count = selectedItems.count
        if count == 0 {
            return "Select at least one core to send back."
        }

        return ReturnsModel.coreCountText(count)
            + " worth "
            + selectedTotal.formatted(currencyCode: currencyCode)
            + " will move to Returned — awaiting credit. That money stays in Money at Risk until you record the vendor's credit."
    }

    // MARK: - Actions

    private func toggle(_ item: CoreItem) {
        if selectedIdentifiers.contains(item.id) {
            selectedIdentifiers.remove(item.id)
        } else {
            selectedIdentifiers.insert(item.id)
        }
    }

    private func toggleSelectAll() {
        if isEverythingSelected {
            selectedIdentifiers.removeAll()
        } else {
            selectedIdentifiers = Set(candidates.map { $0.id })
        }
    }

    /// Creates the batch, then attaches the receipt.
    ///
    /// The two writes are reported separately on purpose: if the batch saves and the photo does
    /// not, the cores really have moved, so the button becomes "Done" rather than inviting a second
    /// tap that would create a duplicate return.
    private func confirm() {
        if savedBatch != nil {
            dismiss()
            return
        }

        let items = selectedItems
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        let service = appEnvironment.batchService(modelContext)

        do {
            let batch = try service.createBatch(
                vendor: vendor,
                items: items,
                returnDate: returnDate,
                method: method,
                reference: reference,
                notes: notes
            )
            savedBatch = batch

            if let receipt = receipt {
                try service.attachReceipt(receipt, to: batch)
            }

            dismiss()
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }
}

// MARK: - BatchFieldWell

/// A labelled entry well matching `CurrencyTextField`'s treatment, so every field on this sheet
/// has the same 44-point target and the same border.
private struct BatchFieldWell<Content: View>: View {

    private let title: String
    private let hint: String?
    private let content: Content

    init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            content
                .padding(.horizontal, Spacing.m)
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.fieldBorder, lineWidth: 1)
                )

            if let hint = hint, hint.isEmpty == false {
                Text(hint)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - BatchActionLabel

/// A secondary action on this sheet: amber, glyphed, and a full 44 points tall.
private struct BatchActionLabel: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: Spacing.minimumTapTarget)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
