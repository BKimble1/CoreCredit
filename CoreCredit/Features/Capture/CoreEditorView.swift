//
//  CoreEditorView.swift
//  CoreCredit
//
//  Capture feature — the Add/Edit Core screen.
//
//  ## What this screen is
//
//  A mechanic with dirty hands, standing at a parts counter, with a customer waiting. Speed of
//  entry is the feature. Everything here follows from that:
//
//  - **The manual path is always available.** No camera, no scanner, no OCR, no network — the form
//    still fills in and still saves. Scanning and photo-reading are buttons *beside* the fields,
//    never gates in front of them.
//  - **Nothing is set up elsewhere.** A missing vendor or bin is created inline, in place, without
//    abandoning the entry.
//  - **Money is text until it is parsed.** The amount binds to a `String` and only `Money.parse`
//    ever reads it, so a core charge can never pick up a floating-point error.
//  - **The deadline comes from the vendor.** The due date is derived from the selected vendor's own
//    return window; no policy is written into this file.
//

import SwiftData
import SwiftUI
import UIKit

// MARK: - Mode

/// Whether the editor is creating a record or changing one that already exists.
enum CoreEditorMode: Equatable {

    /// A brand-new core charge.
    case create

    /// An existing record. Editing is never gated by the subscription tier.
    case edit(CoreItem)

    /// Written out rather than synthesised so identity is compared by the record's own `id`, which
    /// is stable across contexts, rather than by object identity.
    static func == (lhs: CoreEditorMode, rhs: CoreEditorMode) -> Bool {
        switch (lhs, rhs) {
        case (.create, .create):
            return true
        case (.edit(let left), .edit(let right)):
            return left.id == right.id
        case (.create, .edit), (.edit, .create):
            return false
        }
    }
}

// MARK: - Editor

/// Add / edit one core charge.
@MainActor
struct CoreEditorView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var vendors: [Vendor]
    @Query private var bins: [StorageBin]
    @Query private var profiles: [ShopProfile]

    @State private var model: CoreEditorModel
    @FocusState private var focusedField: CoreItemField?

    /// - Parameters:
    ///   - mode: Creating a record, or editing one that already exists.
    ///   - initialRoute: A modal to open on top of the form as it appears. This is how the
    ///     Dashboard's "Scan core" action reaches the scanner *without* presenting a second copy of
    ///     the intake form: there is one editor, and the scanner is a sheet over it, so cancelling
    ///     the camera lands on the form the user was always going to fill in.
    init(mode: CoreEditorMode, initialRoute: CoreEditorModel.Route? = nil) {
        let model = CoreEditorModel(mode: mode)
        model.route = initialRoute
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            messages
                        }
                        .id(CoreEditorView.topAnchorID)
                        partCard
                        vendorCard
                        moneyCard
                        referenceCard
                        dateCard
                        binCard
                        photoCard
                        notesCard
                        saveButton(proxy: proxy)
                    }
                    .padding(Spacing.l)
                    .frame(maxWidth: CoreEditorView.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .background(Palette.background)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier(A11y.Editor.cancel)
                            .accessibilityHint(Text("Closes without saving."))
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { performSave(proxy: proxy) }
                            .disabled(model.isSaving)
                            .accessibilityIdentifier(A11y.Editor.save)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }
                // Attached here rather than beside the paywall sheet below: two `.sheet` modifiers
                // on the *same* view can shadow one another, so each lives on its own view.
                .sheet(item: $model.route) { route in
                    sheetContent(for: route)
                }
            }
        }
        .tint(Palette.accent)
        .task {
            // Use the app's injected calendar so due dates match the rest of the ledger.
            model.calendar = appEnvironment.dateProvider.calendar
        }
        .onChange(of: model.draft) { _, _ in
            model.revalidateIfNeeded()
        }
        .onChange(of: model.draft.usesCustomDueDate) { _, isOn in
            if isOn { model.seedCustomDueDateIfNeeded(vendorWindowDays: vendorWindowDays) }
        }
        .sheet(item: $model.paywallTrigger) { trigger in
            PaywallView(trigger: trigger)
        }
    }

    // MARK: - Layout constants

    /// Keeps the form readable on an iPad instead of stretching one text field across 1024 points.
    private static let contentMaxWidth: CGFloat = 680

    /// Scroll anchor for the banner strip, so a store failure with no field attached to it is
    /// still brought on screen rather than left above the fold.
    private static let topAnchorID = "editor.topAnchor"

    /// Fields the editor can actually move keyboard focus into. The amount lives inside
    /// `CurrencyTextField`, which owns its own focus, and the vendor and due date are not text at
    /// all — for those the editor scrolls to the problem instead of stealing focus.
    private static let focusableFields: Set<CoreItemField> = [
        .partName, .partNumber, .invoiceReference, .repairOrderReference, .notes
    ]

    // MARK: - Messages

    @ViewBuilder
    private var messages: some View {
        if let message = model.errorMessage {
            ErrorBanner(message: message, onDismiss: { model.errorMessage = nil })
        }
        if let notice = model.noticeMessage {
            NoticeBanner(message: notice, onDismiss: { model.noticeMessage = nil })
        }
    }

    // MARK: - Part

    private var partCard: some View {
        SectionCard(title: "Part", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: Spacing.l) {
                EditorField(
                    title: "Part name or description",
                    placeholder: "Alternator",
                    field: .partName,
                    identifier: A11y.Editor.partName,
                    text: $model.draft.partName,
                    focusedField: $focusedField,
                    keyboardType: .default,
                    autocapitalization: .words,
                    submitLabel: .next,
                    errorMessage: model.message(for: .partName),
                    hint: "What came off the vehicle.",
                    onSubmit: { focusedField = .partNumber }
                )

                EditorField(
                    title: "Part number",
                    placeholder: "03-1887",
                    field: .partNumber,
                    identifier: A11y.Editor.partNumber,
                    text: $model.draft.partNumber,
                    focusedField: $focusedField,
                    keyboardType: .numbersAndPunctuation,
                    autocapitalization: .characters,
                    disablesAutocorrection: true,
                    submitLabel: .next,
                    errorMessage: model.message(for: .partNumber),
                    hint: "Optional. Scan it, or type it in.",
                    onSubmit: { focusedField = .invoiceReference }
                )

                Button {
                    focusedField = nil
                    model.route = .scan
                } label: {
                    SecondaryActionLabel(title: "Scan barcode", systemImage: "barcode.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.Editor.scan)
                .accessibilityLabel(Text("Scan barcode"))
                .accessibilityHint(Text("Opens the scanner. You can also type the number in."))
            }
        }
        .id(CoreItemField.partName)
    }

    // MARK: - Vendor

    private var vendorCard: some View {
        SectionCard(title: "Vendor", systemImage: "building.2") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Menu {
                    ForEach(selectableVendors, id: \.id) { vendor in
                        Button {
                            model.draft.vendorIdentifier = vendor.id
                            model.revalidateIfNeeded()
                        } label: {
                            Label(vendor.displayName,
                                  systemImage: vendor.id == model.draft.vendorIdentifier
                                      ? "checkmark"
                                      : "building.2")
                        }
                    }
                    Divider()
                    Button {
                        focusedField = nil
                        model.isAddingVendor = true
                    } label: {
                        Label("Add new vendor…", systemImage: "plus")
                    }
                } label: {
                    PickerRowLabel(
                        title: "Vendor",
                        value: selectedVendor?.displayName,
                        placeholder: "Choose vendor",
                        symbol: "building.2",
                        hasError: model.message(for: .vendor) != nil
                    )
                }
                .accessibilityIdentifier(A11y.Editor.vendor)
                .accessibilityLabel(Text("Vendor"))
                .accessibilityValue(Text(selectedVendor?.displayName ?? "Not chosen"))
                .accessibilityHint(Text("Choose the vendor this core goes back to, or add a new one."))

                FormErrorText(model.message(for: .vendor))

                if let vendor = selectedVendor {
                    Text(vendor.displayName + " allows " + String(vendorWindowDays)
                         + (vendorWindowDays == 1 ? " day" : " days") + " to return a core.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isAddingVendor {
                    newVendorForm
                }
            }
        }
        .id(CoreItemField.vendor)
    }

    private var newVendorForm: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New vendor")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.textPrimary)

            PlainEntryField(title: "Vendor name",
                            placeholder: "NAPA Auto Parts",
                            text: $model.newVendorName,
                            keyboardType: .default,
                            autocapitalization: .words)

            Stepper(value: $model.newVendorWindowDays,
                    in: DueDateCalculator.minimumWindowDays...DueDateCalculator.maximumWindowDays) {
                Text("Return window: " + String(model.newVendorWindowDays)
                     + (model.newVendorWindowDays == 1 ? " day" : " days"))
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Return window in days"))
            .accessibilityValue(Text(String(model.newVendorWindowDays)))

            HStack(spacing: Spacing.m) {
                Button("Cancel") { model.cancelVendorCreation() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minHeight: Spacing.minimumTapTarget)

                Spacer(minLength: Spacing.s)

                Button {
                    model.createVendor(using: itemService)
                } label: {
                    SecondaryActionLabel(title: "Add vendor", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.newVendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    // MARK: - Money

    private var moneyCard: some View {
        SectionCard(title: "Expected core credit", systemImage: "dollarsign.circle") {
            CurrencyTextField(
                title: "Expected credit",
                text: $model.draft.expectedCreditText,
                currencyCode: currencyCode,
                errorMessage: model.message(for: .expectedCredit),
                focusHint: "The core charge printed on the invoice.",
                fieldIdentifier: A11y.Editor.amount
            )
        }
        .id(CoreItemField.expectedCredit)
    }

    // MARK: - References

    private var referenceCard: some View {
        SectionCard(title: "References", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: Spacing.l) {
                EditorField(
                    title: "Invoice or reference",
                    placeholder: "INV-55219",
                    field: .invoiceReference,
                    identifier: A11y.Editor.invoice,
                    text: $model.draft.invoiceReference,
                    focusedField: $focusedField,
                    keyboardType: .numbersAndPunctuation,
                    autocapitalization: .characters,
                    disablesAutocorrection: true,
                    submitLabel: .next,
                    errorMessage: model.message(for: .invoiceReference),
                    hint: "The vendor's invoice this core came off.",
                    onSubmit: { focusedField = .repairOrderReference }
                )

                EditorField(
                    title: "Repair order",
                    placeholder: "RO 4471",
                    field: .repairOrderReference,
                    identifier: A11y.Editor.repairOrder,
                    text: $model.draft.repairOrderReference,
                    focusedField: $focusedField,
                    keyboardType: .numbersAndPunctuation,
                    autocapitalization: .characters,
                    disablesAutocorrection: true,
                    submitLabel: .next,
                    errorMessage: model.message(for: .repairOrderReference),
                    hint: "Your own ticket number, so the core ties back to the job.",
                    onSubmit: { focusedField = .notes }
                )
            }
        }
    }

    // MARK: - Dates

    private var dateCard: some View {
        SectionCard(title: "Dates", systemImage: "calendar") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                DatePicker("Received",
                           selection: $model.draft.receivedDate,
                           displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityLabel(Text("Received date"))

                Text(dueDateSummary)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(dueDateSummary))

                Toggle("Set the due date by hand", isOn: $model.draft.usesCustomDueDate)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityHint(Text("Overrides the vendor's return window for this core only."))

                if model.draft.usesCustomDueDate {
                    DatePicker("Due",
                               selection: customDueDateBinding,
                               displayedComponents: [.date])
                        .datePickerStyle(.compact)
                        .frame(minHeight: Spacing.minimumTapTarget)
                        .accessibilityLabel(Text("Due date"))

                    FormErrorText(model.message(for: .dueDate))
                }
            }
        }
        .id(CoreItemField.dueDate)
    }

    // MARK: - Bin

    private var binCard: some View {
        SectionCard(title: "Storage bin", systemImage: "tray.full") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Menu {
                    Button {
                        model.draft.binIdentifier = nil
                    } label: {
                        Label("No bin yet",
                              systemImage: model.draft.binIdentifier == nil ? "checkmark" : "tray")
                    }
                    ForEach(selectableBins, id: \.id) { bin in
                        Button {
                            model.draft.binIdentifier = bin.id
                        } label: {
                            Label(bin.displayName,
                                  systemImage: bin.id == model.draft.binIdentifier
                                      ? "checkmark"
                                      : "tray.full")
                        }
                    }
                    Divider()
                    Button {
                        focusedField = nil
                        model.isAddingBin = true
                    } label: {
                        Label("Add new bin…", systemImage: "plus")
                    }
                } label: {
                    PickerRowLabel(
                        title: "Bin",
                        value: selectedBin?.displayName,
                        placeholder: "No bin yet",
                        symbol: "tray.full",
                        hasError: false
                    )
                }
                .accessibilityIdentifier(A11y.Editor.bin)
                .accessibilityLabel(Text("Storage bin"))
                .accessibilityValue(Text(selectedBin?.displayName ?? "No bin yet"))
                .accessibilityHint(Text("Where the old core physically sits, or add a new bin."))

                if let bin = selectedBin, !bin.locationNote.isEmpty {
                    Text(bin.locationNote)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isAddingBin {
                    newBinForm
                }
            }
        }
    }

    private var newBinForm: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New bin")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.textPrimary)

            PlainEntryField(title: "Bin label",
                            placeholder: "Rack C — shelf 2",
                            text: $model.newBinLabel,
                            keyboardType: .default,
                            autocapitalization: .characters)

            PlainEntryField(title: "Where it is (optional)",
                            placeholder: "Back wall, by the roll-up door",
                            text: $model.newBinLocationNote,
                            keyboardType: .default,
                            autocapitalization: .sentences)

            HStack(spacing: Spacing.m) {
                Button("Cancel") { model.cancelBinCreation() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minHeight: Spacing.minimumTapTarget)

                Spacer(minLength: Spacing.s)

                Button {
                    model.createBin(using: itemService)
                } label: {
                    SecondaryActionLabel(title: "Add bin", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.newBinLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    // MARK: - Photos

    private var photoCard: some View {
        SectionCard(title: "Photos", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Photos are the evidence when a credit comes up short. All optional.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)],
                          spacing: Spacing.m) {
                    photoButton(kind: .part, title: "Part")
                    photoButton(kind: .box, title: "Box or label")
                    photoButton(kind: .invoice, title: "Invoice")
                    photoButton(kind: .receipt, title: "Return receipt")
                }

                Button {
                    focusedField = nil
                    model.route = .documentScan
                } label: {
                    SecondaryActionLabel(title: "Scan an invoice or receipt",
                                         systemImage: "doc.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Scan an invoice or receipt"))
                .accessibilityHint(
                    Text("Opens the document camera for a multi-page invoice. "
                         + "Nothing is filled in until you confirm each value.")
                )

                if !model.photos.isEmpty {
                    AttachmentStrip(
                        attachments: model.photos,
                        onDelete: { attachment in
                            model.removePhoto(attachment, using: itemService)
                        }
                    )

                    if let data = model.latestPhotoData {
                        Button {
                            focusedField = nil
                            model.route = .readPhoto(data)
                        } label: {
                            SecondaryActionLabel(title: "Read details from the latest photo",
                                                 systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            Text("Suggests values from the photo. Nothing changes until you confirm.")
                        )
                    }
                }
            }
        }
    }

    private func photoButton(kind: AttachmentKind, title: String) -> some View {
        Button {
            focusedField = nil
            model.route = .attachment(kind)
        } label: {
            SecondaryActionLabel(title: title, systemImage: kind.symbolName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add " + kind.displayName.lowercased() + " photo"))
    }

    // MARK: - Notes

    private var notesCard: some View {
        SectionCard(title: "Notes", systemImage: "note.text") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                TextField("Anything the counter needs to know",
                          text: $model.draft.notes,
                          axis: .vertical)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .notes)
                    .padding(Spacing.m)
                    .frame(minHeight: Spacing.minimumTapTarget * 2, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                            .fill(Palette.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                            .strokeBorder(focusedField == .notes ? Palette.accent : Palette.hairline,
                                          lineWidth: focusedField == .notes ? 2 : 1)
                    )
                    .accessibilityLabel(Text("Notes"))
            }
        }
    }

    // MARK: - Save

    private func saveButton(proxy: ScrollViewProxy) -> some View {
        Button {
            performSave(proxy: proxy)
        } label: {
            PrimaryButtonLabel(model.isCreatingNewRecord ? "Save core" : "Save changes",
                               systemImage: "checkmark")
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel(Text(model.isCreatingNewRecord ? "Save core" : "Save changes"))
        .padding(.top, Spacing.s)
    }

    /// Validates, saves, and either closes or points the user at the first problem.
    private func performSave(proxy: ScrollViewProxy) {
        focusedField = nil

        let saved = model.save(using: itemService,
                               vendor: selectedVendor,
                               bin: selectedBin,
                               tier: appEnvironment.subscriptions.entitlement.tier)
        if saved {
            dismiss()
            return
        }

        guard let field = model.firstInvalidField else {
            // No field owns this failure — a store error, or a paywall block. Bring the banners
            // (and the paywall's own presentation) back into view.
            if model.errorMessage != nil {
                withAnimation {
                    proxy.scrollTo(CoreEditorView.topAnchorID, anchor: .top)
                }
            }
            return
        }
        if CoreEditorView.focusableFields.contains(field) {
            focusedField = field
        }
        withAnimation {
            proxy.scrollTo(field, anchor: .center)
        }
    }

    // MARK: - Sheets

    /// One sheet, one route. A capture hands its result *back* to the model, which swaps the route
    /// to `.scanReview`; the capture sheet never dismisses itself on success, so a dismissal cannot
    /// race the presentation that follows it.
    @ViewBuilder
    private func sheetContent(for route: CoreEditorModel.Route) -> some View {
        switch route {
        case .scan:
            ScanSheet { session in
                model.beginReview(of: session)
            }
        case .attachment(let kind):
            AttachmentPickerSheet(kind: kind) { attachment in
                model.addPhoto(attachment, using: itemService)
            }
        case .readPhoto(let data):
            OCRReviewSheet(imageData: data) { candidates in
                model.apply(candidates, vendors: vendors)
            }
        case .scanReview(let session):
            ScanReviewSheet(
                session: session,
                onApply: { candidates in
                    model.apply(candidates, vendors: vendors)
                },
                onRetake: {
                    model.route = .scan
                }
            )
        case .documentScan:
            DocumentScanSheet { candidates in
                model.apply(candidates, vendors: vendors)
                model.route = nil
            }
        }
    }

    // MARK: - Derived values

    private var itemService: CoreItemService {
        appEnvironment.itemService(modelContext)
    }

    /// Currency for every amount on this screen, from the shop profile.
    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    /// Active vendors, plus whichever vendor this record already points at even if it was retired.
    private var selectableVendors: [Vendor] {
        vendors
            .filter { $0.isActive || $0.id == model.draft.vendorIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Active bins, plus whichever bin this record already points at even if it was retired.
    private var selectableBins: [StorageBin] {
        bins
            .filter { $0.isActive || $0.id == model.draft.binIdentifier }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var selectedVendor: Vendor? {
        guard let identifier = model.draft.vendorIdentifier else { return nil }
        return vendors.first(where: { $0.id == identifier })
    }

    private var selectedBin: StorageBin? {
        guard let identifier = model.draft.binIdentifier else { return nil }
        return bins.first(where: { $0.id == identifier })
    }

    /// The return window driving the due date: the selected vendor's own policy, falling back to
    /// the app's configured default only while no vendor has been chosen.
    private var vendorWindowDays: Int {
        selectedVendor?.defaultReturnWindowDays ?? AppConfiguration.defaultVendorReturnWindowDays
    }

    /// One sentence naming the deadline and where it came from, e.g.
    /// "Due 12 Sep 2026 — NAPA Auto Parts' 30-day window."
    private var dueDateSummary: String {
        let due = model.resolvedDueDate(vendorWindowDays: vendorWindowDays)
        let dateText = due.formatted(date: .abbreviated, time: .omitted)

        if model.draft.usesCustomDueDate {
            return "Due " + dateText + " — set by hand for this core."
        }
        let dayText = String(vendorWindowDays) + "-day window"
        if let vendor = selectedVendor {
            return "Due " + dateText + " — " + possessive(vendor.displayName) + " " + dayText + "."
        }
        return "Due " + dateText + " — default " + dayText + " until you choose a vendor."
    }

    /// English possessive that does not double a trailing "s" ("NAPA's", "Parts'").
    private func possessive(_ name: String) -> String {
        guard let last = name.last else { return name }
        return (last == "s" || last == "S") ? name + "'" : name + "'s"
    }

    /// A non-optional date for the override picker. Reading falls back to the computed deadline so
    /// the picker never opens on an unrelated day.
    private var customDueDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.customDueDate ?? model.resolvedDueDate(vendorWindowDays: vendorWindowDays) },
            set: { model.draft.customDueDate = $0 }
        )
    }
}

// MARK: - Notice banner

/// A neutral, dismissible note — "part number filled in from the scan", "added NAPA".
///
/// Deliberately not amber or green: in this app amber means "act now" and green means "money
/// arrived", and a confirmation of a typed-in convenience is neither.
@MainActor
private struct NoticeBanner: View {

    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "info.circle.fill")
                .imageScale(.medium)
                .foregroundStyle(Palette.neutral)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Spacing.minimumTapTarget, height: Spacing.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Editor field

/// One labelled text field in the editor, with its error text and its place in the focus chain.
///
/// Focus is forwarded from the screen so a failed save can move the keyboard to the first field
/// that needs attention.
@MainActor
private struct EditorField: View {

    private let title: String
    private let placeholder: String
    private let field: CoreItemField
    private let identifier: String
    @Binding private var text: String
    @FocusState.Binding private var focusedField: CoreItemField?
    private let keyboardType: UIKeyboardType
    private let autocapitalization: TextInputAutocapitalization
    private let disablesAutocorrection: Bool
    private let submitLabel: SubmitLabel
    private let errorMessage: String?
    private let hint: String?
    private let onSubmit: () -> Void

    init(title: String,
         placeholder: String,
         field: CoreItemField,
         identifier: String,
         text: Binding<String>,
         focusedField: FocusState<CoreItemField?>.Binding,
         keyboardType: UIKeyboardType = .default,
         autocapitalization: TextInputAutocapitalization = .sentences,
         disablesAutocorrection: Bool = false,
         submitLabel: SubmitLabel = .next,
         errorMessage: String? = nil,
         hint: String? = nil,
         onSubmit: @escaping () -> Void = { }) {
        self.title = title
        self.placeholder = placeholder
        self.field = field
        self.identifier = identifier
        self._text = text
        self._focusedField = focusedField
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
        self.disablesAutocorrection = disablesAutocorrection
        self.submitLabel = submitLabel
        self.errorMessage = errorMessage
        self.hint = hint
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .submitLabel(submitLabel)
                .focused($focusedField, equals: field)
                .onSubmit(onSubmit)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Spacing.minimumTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(spokenHint))

            if hasError {
                FormErrorText(errorMessage)
            } else if let hint = hint, !hint.isEmpty {
                Text(hint)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    private var hasError: Bool {
        guard let errorMessage = errorMessage else { return false }
        return !errorMessage.isEmpty
    }

    private var borderColor: Color {
        if hasError { return Palette.danger }
        return focusedField == field ? Palette.accent : Palette.hairline
    }

    /// Error and focus both thicken the border, so neither state depends on colour alone.
    private var borderWidth: CGFloat {
        (hasError || focusedField == field) ? 2 : 1
    }

    private var spokenHint: String {
        if let errorMessage = errorMessage, !errorMessage.isEmpty { return errorMessage }
        return hint ?? ""
    }
}

// MARK: - Plain entry field

/// A labelled text field with no validation attached — used by the inline vendor and bin forms.
@MainActor
private struct PlainEntryField: View {

    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let autocapitalization: TextInputAutocapitalization

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .submitLabel(.done)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Spacing.minimumTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .accessibilityLabel(Text(title))
        }
    }
}

// MARK: - Picker row label

/// The tappable row a `Menu` uses as its label: title, current value, and a chevron.
@MainActor
private struct PickerRowLabel: View {

    let title: String
    let value: String?
    let placeholder: String
    let symbol: String
    let hasError: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text(displayedValue)
                    .font(Typography.rowTitle)
                    .foregroundStyle(value == nil ? Palette.textSecondary : Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.s)

            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: Spacing.minimumTapTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(hasError ? Palette.danger : Palette.hairline,
                              lineWidth: hasError ? 2 : 1)
        )
        .contentShape(Rectangle())
    }

    private var displayedValue: String {
        guard let value = value, !value.isEmpty else { return placeholder }
        return value
    }
}

// MARK: - Secondary action label

/// The label for a supporting action — scan, add a photo, add a vendor.
///
/// Outlined rather than filled: amber is reserved for the one primary action on a screen.
@MainActor
private struct SecondaryActionLabel: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
