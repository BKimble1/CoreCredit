//
//  BatchDetailView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

// MARK: - Routing

/// The modal `BatchDetailView` currently has open. `nil` means the return itself is in front.
///
/// One enum, presented by a single `.sheet(item:)`, rather than an optional plus a flag: two
/// `.sheet` modifiers attached to the *same* view can shadow one another, so only one of them would
/// ever present. The credit case keys its `id` off the core it was opened with *and* a per-case
/// prefix, so it can never collide with another sheet's identity. This screen keeps its state in
/// `@State` rather than an observable model, so the route lives here beside it.
private enum BatchDetailRoute: Identifiable {

    /// `RecordCreditSheet`, opened on one core from this return.
    case credit(CoreItem)

    /// The camera / library picker for the signed return slip.
    case receiptPicker

    var id: String {
        switch self {
        case .credit(let item):
            return "credit." + item.id.uuidString
        case .receiptPicker:
            return "receiptPicker"
        }
    }
}

/// Everything about one physical hand-off to a vendor: what went back, what it was worth, what has
/// been credited, and the receipt that proves it.
///
/// The batch header can be corrected in place — a mistyped return slip number is common and must
/// not require deleting the return. Removing a core or deleting the whole batch only changes
/// *membership*: statuses are left exactly as they are, because undoing a return is a separate,
/// explicit decision made on the core itself.
struct BatchDetailView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [ShopProfile]

    private let batch: ReturnBatch

    @State private var isEditing = false
    @State private var draftReturnDate = Date()
    @State private var draftMethod: ReturnMethod = .counterDropOff
    @State private var draftReference = ""
    @State private var draftNotes = ""
    @State private var errorMessage: String?
    @State private var route: BatchDetailRoute?
    @State private var pendingRemoval: CoreItem?

    init(batch: ReturnBatch) {
        self.batch = batch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let errorMessage = errorMessage {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                }

                totalsCard
                detailsCard
                receiptsCard
                itemsCard
                deleteCard
            }
            .padding(Spacing.l)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // A pushed screen still sits inside the tab bar's safe-area inset, and "Delete return" is
        // the last thing on this one. Same fix as the root screens: paint the background behind
        // the scroll view rather than stacking it beside one that ignores the safe area.
        .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
        .background {
            Palette.background.ignoresSafeArea()
        }
        .navigationTitle(batch.vendor?.displayName ?? "Return")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Cancel" : "Edit") {
                    if isEditing {
                        isEditing = false
                    } else {
                        beginEditing()
                    }
                }
                .accessibilityHint(Text(isEditing
                                        ? "Discards the changes to this return's details."
                                        : "Lets you correct the date, method, reference, and notes."))
            }
        }
        // One sheet, not two: stacked `.sheet` modifiers on the same view shadow one another, so
        // both presentations go through `BatchDetailRoute`. The confirmation dialog below is
        // unaffected — only sheets shadow each other.
        .sheet(item: $route) { presented in
            sheetContent(for: presented)
        }
        .confirmationDialog(
            "Remove this core from the return?",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Remove core", role: .destructive) {
                confirmRemoval()
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("The core stays in your ledger with the status it has now. Only its link to this return is removed.")
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for presented: BatchDetailRoute) -> some View {
        switch presented {
        case .credit(let item):
            RecordCreditSheet(item: item)
        case .receiptPicker:
            AttachmentPickerSheet(kind: .receipt) { captured in
                addReceipt(captured)
            }
        }
    }

    // MARK: - Derived state

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private var now: Date {
        appEnvironment.dateProvider.now
    }

    private var calendar: Calendar {
        appEnvironment.dateProvider.calendar
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if isPresented == false { pendingRemoval = nil }
            }
        )
    }

    // MARK: - Totals

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            StatTile(
                title: "Expected credit on this return",
                value: batch.totalExpectedCredit.formatted(currencyCode: currencyCode),
                symbol: "dollarsign.circle",
                tint: Palette.textPrimary,
                caption: ReturnsModel.coreCountText(batch.itemCount),
                accessibilityValue: batch.totalExpectedCredit.accessibilityText(currencyCode: currencyCode)
            )

            StatTile(
                title: batch.isFullyCredited ? "Fully credited" : "Still outstanding",
                value: batch.outstandingCredit.formatted(currencyCode: currencyCode),
                symbol: batch.isFullyCredited ? CoreStatus.credited.symbolName : CoreStatus.returnedAwaitingCredit.symbolName,
                tint: batch.isFullyCredited ? Palette.positive : Palette.textPrimary,
                caption: batch.isFullyCredited
                    ? "Every core on this return was credited."
                    : "This money is still with the vendor.",
                accessibilityValue: batch.outstandingCredit.accessibilityText(currencyCode: currencyCode)
            )
        }
    }

    // MARK: - Details

    private var detailsCard: some View {
        SectionCard(title: "Hand-off details", systemImage: "doc.text") {
            if isEditing {
                editingFields
            } else {
                readOnlyFields
            }
        }
    }

    private var readOnlyFields: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            LabeledValueRow("Vendor", value: batch.vendor?.displayName ?? "", symbol: "building.2")
            LabeledValueRow(
                "Return date",
                value: batch.returnDate.formatted(date: .abbreviated, time: .omitted),
                symbol: "calendar"
            )
            LabeledValueRow("Method", value: batch.method.displayName, symbol: batch.method.symbolName)
            LabeledValueRow("Reference", value: batch.reference, symbol: "number", isMonospaced: true)
            LabeledValueRow("Notes", value: batch.notes, symbol: "note.text")
        }
    }

    private var editingFields: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            BatchDetailFieldWell(title: "Return date") {
                DatePicker(
                    "Return date",
                    selection: $draftReturnDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(Palette.accent)
                .accessibilityLabel(Text("Return date"))
            }

            BatchDetailFieldWell(title: "How it went back") {
                Picker("How it went back", selection: $draftMethod) {
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

            BatchDetailFieldWell(title: "Reference") {
                TextField("Return slip number", text: $draftReference)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .accessibilityIdentifier(A11y.Returns.editReference)
                    .accessibilityLabel(Text("Return reference"))
            }

            BatchDetailFieldWell(title: "Notes") {
                TextField("Anything worth remembering", text: $draftNotes, axis: .vertical)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2...5)
                    .accessibilityLabel(Text("Notes"))
            }

            Button {
                saveEdits()
            } label: {
                PrimaryButtonLabel("Save changes", systemImage: "checkmark")
            }
            .buttonStyle(.plain)

            Text("Correcting these details never rewrites the cores' history — each core keeps the return date it was stamped with.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Receipts

    private var receiptsCard: some View {
        SectionCard(title: "Return receipts", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if batch.receipts.isEmpty {
                    Text("No receipt photo yet. One photo of the signed slip covers every core on this return, and it is the first thing a vendor asks for when a credit is short.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AttachmentStrip(attachments: batch.receipts, onDelete: { attachment in
                        removeReceipt(attachment)
                    })

                    Text("Touch and hold a photo to delete it.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                Button {
                    route = .receiptPicker
                } label: {
                    BatchDetailActionLabel(title: "Add receipt photo", systemImage: "camera")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Items

    private var itemsCard: some View {
        SectionCard(title: "Cores on this return", systemImage: "shippingbox") {
            let items = batch.coreItems

            if items.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "No cores on this return",
                    message: "Every core has been taken off this return. You can delete it, or add cores to it from the Returns screen."
                )
            } else {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(items, id: \.id) { item in
                        itemRow(item)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: CoreItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            NavigationLink {
                CoreDetailView(item: item)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(item.displayTitle)
                            .font(Typography.rowTitle)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(itemSubtitle(item))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Spacing.s)

                    MoneyLabel(item.expectedCredit, currencyCode: currencyCode, style: .row)
                        .accessibilityLabel(Text("Expected credit"))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Spacing.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens this core."))

            HStack(spacing: Spacing.m) {
                StatusBadge(
                    status: item.status,
                    isOverdue: RiskCalculator.isOverdue(item, now: now, calendar: calendar),
                    compact: true
                )

                Spacer(minLength: Spacing.s)

                if canRecordCredit(item) {
                    Button {
                        route = .credit(item)
                    } label: {
                        BatchDetailActionLabel(
                            title: "Record credit",
                            systemImage: CoreStatus.credited.symbolName
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Record credit for " + item.displayTitle))
                }

                Button(role: .destructive) {
                    pendingRemoval = item
                } label: {
                    Image(systemName: "minus.circle")
                        .imageScale(.medium)
                        .foregroundStyle(Palette.danger)
                        .frame(width: Spacing.minimumTapTarget, height: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove " + item.displayTitle + " from this return"))
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    /// A credit can only be recorded from `.returnedAwaitingCredit` or `.disputed`; anywhere else
    /// `CoreItemService.recordCredit` throws `.invalidTransition`, so the action is not offered.
    private func canRecordCredit(_ item: CoreItem) -> Bool {
        item.status == .returnedAwaitingCredit || item.status == .disputed
    }

    private func itemSubtitle(_ item: CoreItem) -> String {
        var parts: [String] = []

        let partNumber = item.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if partNumber.isEmpty == false {
            parts.append(partNumber)
        }

        if let actual = item.actualCredit {
            parts.append("Credited " + actual.formatted(currencyCode: currencyCode))
        }

        if let discrepancy = RiskCalculator.discrepancy(for: item), discrepancy.isPositive {
            parts.append("Short by " + discrepancy.formatted(currencyCode: currencyCode))
        }

        if parts.isEmpty {
            parts.append(item.status.displayName)
        }

        return parts.joined(separator: " • ")
    }

    // MARK: - Delete

    private var deleteCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Deleting this return detaches its cores and deletes its receipt photos. The cores stay in your ledger with the status they have now — nothing is credited or written off by deleting a return.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DestructiveConfirmButton(
                    title: "Delete this return",
                    confirmationTitle: "Delete return",
                    message: deleteConfirmationMessage,
                    action: { deleteBatch() }
                )
            }
        }
    }

    /// States plainly that deleting the paperwork does not touch the money.
    private var deleteConfirmationMessage: String {
        let count = batch.itemCount
        let verb = count == 1 ? " stays" : " stay"
        let possessive = count == 1 ? "the status it has now" : "the status they have now"
        return "The "
            + ReturnsModel.coreCountText(count)
            + " on this return"
            + verb
            + " in your ledger with "
            + possessive
            + ". Only the return record and its receipt photos are deleted."
    }

    // MARK: - Actions

    private func beginEditing() {
        draftReturnDate = batch.returnDate
        draftMethod = batch.method
        draftReference = batch.reference
        draftNotes = batch.notes
        errorMessage = nil
        isEditing = true
    }

    private func saveEdits() {
        errorMessage = nil
        do {
            try appEnvironment.batchService(modelContext).updateBatch(
                batch,
                returnDate: draftReturnDate,
                method: draftMethod,
                reference: draftReference,
                notes: draftNotes
            )
            isEditing = false
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }

    private func addReceipt(_ attachment: Attachment) {
        errorMessage = nil
        do {
            try appEnvironment.batchService(modelContext).attachReceipt(attachment, to: batch)
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }

    private func removeReceipt(_ attachment: Attachment) {
        errorMessage = nil
        do {
            try appEnvironment.batchService(modelContext).removeReceipt(attachment, from: batch)
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }

    private func confirmRemoval() {
        guard let item = pendingRemoval else { return }
        pendingRemoval = nil
        errorMessage = nil
        do {
            try appEnvironment.batchService(modelContext).removeItem(item, from: batch)
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }

    private func deleteBatch() {
        errorMessage = nil
        do {
            try appEnvironment.batchService(modelContext).delete(batch)
            dismiss()
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }
}

// MARK: - BatchDetailFieldWell

/// A labelled entry well, matching the treatment used by `CurrencyTextField`.
private struct BatchDetailFieldWell<Content: View>: View {

    private let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
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
        }
    }
}

// MARK: - BatchDetailActionLabel

/// A secondary action inside a core row.
private struct BatchDetailActionLabel: View {

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
