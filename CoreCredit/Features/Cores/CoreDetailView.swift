//
//  CoreDetailView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// Everything known about one core, and every legal thing that can be done to it.
///
/// The screen is organised the way an owner argues a credit: what it is, what it is worth, what
/// actually came back, what is still missing, and then the dated history that proves it.
///
/// Three rules hold this together:
///
/// - **Nothing is mutated here.** Every write goes through `CoreItemService`, which is the only
///   thing that can append to the timeline, so a status can never move without leaving a record.
/// - **No action is offered that the machine would reject.** The status buttons are built from
///   `CoreStatusMachine.userSelectableTransitions(from:)`, and the ones `isReversal` marks are
///   labelled as an undo rather than as progress.
/// - **Failures are shown, never swallowed.** Anything thrown lands in an `ErrorBanner` with the
///   `DomainError` sentence and its recovery suggestion.
struct CoreDetailView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [ShopProfile]

    @State private var model = CoreDetailModel()

    private let item: CoreItem

    init(item: CoreItem) {
        self.item = item
    }

    var body: some View {
        Group {
            if model.isDeleted {
                deletedPlaceholder
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        errorSection
                        headerCard
                        primaryActions
                        moneyCard
                        detailsCard
                        photosCard
                        returnCard
                        statusCard
                        toolsCard
                        historyCard
                    }
                    .padding(Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A pushed screen still sits inside the tab bar's safe-area inset. The background is
        // painted behind rather than stacked beside the scroll view, for the same reason it is on
        // the Dashboard: a `ZStack` holding a safe-area-ignoring child grows past that inset and
        // takes it away from everything else in the stack.
        .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
        .background {
            Palette.background.ignoresSafeArea()
        }
        // An overlay rather than another stack layer: it covers the screen while an export runs
        // and must not influence the layout underneath it at any other time.
        .overlay {
            if model.isAwaitingExport && appEnvironment.exports.inFlight {
                LoadingOverlay(message: "Building dispute packet…")
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Detail.root)
        // One sheet, not four: stacked `.sheet` modifiers on the same view shadow one another, so
        // every presentation this screen owns goes through `CoreDetailModel.Route`.
        .sheet(item: routeBinding) { route in
            sheetContent(for: route)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for route: CoreDetailModel.Route) -> some View {
        switch route {
        case .editor:
            NavigationStack {
                CoreEditorView(mode: .edit(item))
            }
        case .credit:
            NavigationStack {
                RecordCreditSheet(item: item)
            }
        case .binTag:
            NavigationStack {
                BinTagSheet(item: item)
            }
        case .export(let document):
            exportShareSheet(for: document)
        }
    }

    // MARK: - Shared values

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private var now: Date { appEnvironment.dateProvider.now }

    private var calendar: Calendar { appEnvironment.dateProvider.calendar }

    private var isOverdue: Bool {
        RiskCalculator.isOverdue(item, now: now, calendar: calendar)
    }

    private var navigationTitleText: String {
        model.isDeleted ? "Core" : item.displayTitle
    }

    // MARK: - Header

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.errorMessage {
            ErrorBanner(message: message, onDismiss: { model.clearError() })
        }

        // Only this screen's own export failure. `ExportCoordinator` is shared, so an error raised
        // by Settings must not surface here as if the packet had failed.
        if model.isAwaitingExport, let exportError = appEnvironment.exports.lastError {
            ErrorBanner(
                message: exportError,
                retryTitle: "Try again",
                onRetry: { exportPacket() },
                onDismiss: {
                    appEnvironment.exports.clearError()
                    model.isAwaitingExport = false
                }
            )
        }
    }

    private var headerCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(item.displayTitle)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Spacing.m) {
                    StatusBadge(status: item.status, isOverdue: isOverdue)
                        .accessibilityIdentifier(A11y.Detail.status)
                    Spacer(minLength: Spacing.s)
                }

                HStack(spacing: Spacing.s) {
                    Image(systemName: deadlineSymbol)
                        .imageScale(.small)
                    Text(deadlineText)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(deadlineTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(deadlineText))
            }
        }
    }

    // MARK: - Primary actions

    /// The one action most likely to be wanted, given where the core is standing. Recording the
    /// credit is a sheet rather than a plain status move, because it captures the memo number and
    /// the amount that decide whether this core closes or turns into a dispute.
    @ViewBuilder
    private var primaryActions: some View {
        if item.status == .returnedAwaitingCredit || item.status == .disputed {
            Button {
                model.route = .credit
            } label: {
                PrimaryButtonLabel("Record vendor credit", systemImage: "checkmark.seal")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Detail.recordCredit)
            .accessibilityHint(Text("Enter the credit memo number and the amount the vendor "
                                    + "actually credited."))
        }
    }

    // MARK: - Money

    private var moneyCard: some View {
        SectionCard(title: "Money", systemImage: "dollarsign.circle") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabeledValueRow(
                    "Core charge",
                    value: item.expectedCredit.formatted(currencyCode: currencyCode),
                    isMonospaced: true
                )

                LabeledValueRow(
                    "Credit received",
                    value: actualCreditText,
                    isMonospaced: true
                )

                if let display = discrepancyDisplay {
                    discrepancyRow(display)
                }

                LabeledValueRow(
                    "Still at risk",
                    value: RiskCalculator.remainingExposure(for: item)
                        .formatted(currencyCode: currencyCode),
                    isMonospaced: true
                )

                if !trimmed(item.creditReference).isEmpty {
                    LabeledValueRow(
                        "Credit memo",
                        value: trimmed(item.creditReference),
                        symbol: "doc.text",
                        isMonospaced: true
                    )
                }

                if let credited = item.creditedDate {
                    LabeledValueRow(
                        "Credit date",
                        value: credited.formatted(date: .abbreviated, time: .omitted),
                        symbol: "calendar"
                    )
                }
            }
        }
    }

    private func discrepancyRow(_ display: DiscrepancyDisplay) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: display.symbol)
                .imageScale(.medium)
            Text(display.text)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(display.tint)
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(display.tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(display.tint.opacity(0.32), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(display.text))
    }

    // MARK: - Details

    private var detailsCard: some View {
        SectionCard(title: "Core details", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabeledValueRow(
                    "Part number",
                    value: trimmed(item.partNumber),
                    isMonospaced: true
                )
                LabeledValueRow(
                    "Vendor",
                    value: item.vendorName ?? "",
                    symbol: "building.2"
                )
                LabeledValueRow(
                    "Bin",
                    value: item.binLabel ?? "",
                    symbol: "tray.full"
                )
                LabeledValueRow(
                    "Invoice",
                    value: trimmed(item.invoiceReference),
                    symbol: "doc.text",
                    isMonospaced: true
                )
                LabeledValueRow(
                    "Repair order",
                    value: trimmed(item.repairOrderReference),
                    symbol: "wrench.and.screwdriver",
                    isMonospaced: true
                )
                LabeledValueRow(
                    "Received",
                    value: item.receivedDate.formatted(date: .abbreviated, time: .omitted),
                    symbol: "calendar"
                )
                LabeledValueRow(
                    "Return by",
                    value: dueDateText,
                    symbol: "calendar.badge.exclamationmark"
                )
                if let returned = item.returnedDate {
                    LabeledValueRow(
                        "Returned",
                        value: returned.formatted(date: .abbreviated, time: .omitted),
                        symbol: "arrow.uturn.left"
                    )
                }
                LabeledValueRow(
                    "Notes",
                    value: trimmed(item.notes),
                    symbol: "note.text"
                )
            }
        }
    }

    // MARK: - Photos

    @ViewBuilder
    private var photosCard: some View {
        if !item.photos.isEmpty {
            SectionCard(title: "Photos", systemImage: "camera") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    AttachmentStrip(
                        attachments: item.photos,
                        onDelete: { attachment in
                            removePhoto(attachment)
                        }
                    )

                    Text("Press and hold a photo to remove it. Photos are the evidence behind a "
                         + "short credit, so nothing is deleted by a single tap.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Return batch

    @ViewBuilder
    private var returnCard: some View {
        if let batch = item.returnBatch {
            SectionCard(title: "Return", systemImage: "arrow.uturn.left") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    LabeledValueRow(
                        "Vendor",
                        value: batch.vendor?.displayName ?? "",
                        symbol: "building.2"
                    )
                    LabeledValueRow(
                        "Returned",
                        value: batch.returnDate.formatted(date: .abbreviated, time: .omitted),
                        symbol: "calendar"
                    )
                    LabeledValueRow(
                        "Method",
                        value: batch.method.displayName,
                        symbol: batch.method.symbolName
                    )
                    LabeledValueRow(
                        "Return reference",
                        value: trimmed(batch.reference),
                        symbol: "number",
                        isMonospaced: true
                    )

                    if !batch.receipts.isEmpty {
                        Text("Return receipts")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                        AttachmentStrip(attachments: batch.receipts)
                    }
                }
            }
        }
    }

    // MARK: - Status moves

    private var statusCard: some View {
        SectionCard(title: "Move this core", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                let transitions = CoreStatusMachine.userSelectableTransitions(from: item.status)

                if transitions.isEmpty {
                    Text("There is nowhere left to move this core.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(transitions) { target in
                        transitionButton(for: target)

                        if target != transitions.last {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transitionButton(for target: CoreStatus) -> some View {
        let isMarkReady = target == .readyToReturn
            && !CoreStatusMachine.isReversal(from: item.status, to: target)

        if isMarkReady {
            transitionButtonBody(for: target)
                .accessibilityIdentifier(A11y.Detail.markReady)
        } else {
            transitionButtonBody(for: target)
        }
    }

    private func transitionButtonBody(for target: CoreStatus) -> some View {
        Button {
            move(to: target)
        } label: {
            actionRowLabel(
                model.transitionTitle(from: item.status, to: target),
                systemImage: target.symbolName,
                tint: Palette.color(for: target)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(model.transitionHint(to: target)))
    }

    // MARK: - Tools

    private var toolsCard: some View {
        SectionCard(title: "Tools", systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Button {
                    model.route = .binTag
                } label: {
                    actionRowLabel("Print a bin tag", systemImage: "qrcode")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.Detail.binTag)
                .accessibilityHint(Text("Makes a label with a QR code that scans straight back to "
                                        + "this record."))

                Divider()

                Button {
                    exportPacket()
                } label: {
                    actionRowLabel("Export dispute packet", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(appEnvironment.exports.inFlight)
                .accessibilityIdentifier(A11y.Detail.exportPacket)
                .accessibilityHint(Text("Builds a PDF with the invoice, the photos, and the full "
                                        + "history to send to the vendor."))

                Divider()

                Button {
                    model.route = .editor
                } label: {
                    actionRowLabel("Edit core", systemImage: "pencil")
                }
                .buttonStyle(.plain)

                Divider()

                DestructiveConfirmButton(
                    title: "Delete core",
                    confirmationTitle: "Delete core",
                    message: "This removes the core, its photos, and its history. This cannot be "
                        + "undone.",
                    action: { deleteCore() }
                )
                .padding(.top, Spacing.s)
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        SectionCard(title: "History", systemImage: "clock.arrow.circlepath") {
            CoreTimelineView(events: item.timeline, currencyCode: currencyCode)
        }
    }

    private var deletedPlaceholder: some View {
        EmptyStateView(
            symbol: "trash",
            title: "Core deleted",
            message: "This record and everything attached to it has been removed from the ledger."
        )
    }

    // MARK: - Mutations

    /// Every status move lands here so the service — and therefore the timeline — is never bypassed.
    ///
    /// Writing a core off has its own service call rather than a plain transition, because it
    /// records *why* the shop gave up on the money as its own timeline entry.
    private func move(to target: CoreStatus) {
        let service = appEnvironment.itemService(modelContext)
        do {
            if target == .writtenOff {
                try service.writeOff(item, reason: "")
            } else {
                try service.transition(item, to: target, detail: nil)
            }
            model.clearError()
        } catch {
            model.present(error)
        }
    }

    private func removePhoto(_ attachment: Attachment) {
        let service = appEnvironment.itemService(modelContext)
        do {
            try service.removeAttachment(attachment, from: item)
            model.clearError()
        } catch {
            model.present(error)
        }
    }

    private func deleteCore() {
        let service = appEnvironment.itemService(modelContext)
        do {
            try service.delete(item)
            model.isDeleted = true
            dismiss()
        } catch {
            model.present(error)
        }
    }

    /// Renders the dispute packet.
    ///
    /// `isAwaitingExport` is raised first so this screen presents only the document it asked for —
    /// `ExportCoordinator` is shared, and a background screen must not open a share sheet over it.
    private func exportPacket() {
        let service = appEnvironment.itemService(modelContext)
        do {
            let profile = try service.shopProfile()
            model.clearError()
            model.isAwaitingExport = true
            let exports = appEnvironment.exports
            let core = item
            Task {
                await exports.exportDisputePacket(for: core, profile: profile)
            }
        } catch {
            model.present(error)
        }
    }

    // MARK: - Share

    private func exportShareSheet(for document: ExportDocument) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("The dispute packet is ready to send.")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledValueRow("File", value: document.suggestedName, symbol: "doc.richtext")

                ShareLink(item: document.url) {
                    PrimaryButtonLabel("Share packet", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Dispute packet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        closeExportSheet()
                    }
                }
            }
        }
    }

    private func closeExportSheet() {
        model.isAwaitingExport = false
        appEnvironment.exports.dismiss()
    }

    // MARK: - Copy

    private var actualCreditText: String {
        guard let actual = item.actualCredit else { return "" }
        return actual.formatted(currencyCode: currencyCode)
    }

    private var dueDateText: String {
        guard let due = item.dueDate else { return "" }
        return due.formatted(date: .abbreviated, time: .omitted)
    }

    /// The plain-language gap between what the vendor owed and what actually arrived.
    private var discrepancyDisplay: DiscrepancyDisplay? {
        guard let difference = RiskCalculator.discrepancy(for: item) else { return nil }

        if difference.isZero {
            return DiscrepancyDisplay(
                text: "Credited in full",
                symbol: "checkmark.seal",
                tint: Palette.positive
            )
        }
        if difference.isPositive {
            return DiscrepancyDisplay(
                text: "Short by " + difference.formatted(currencyCode: currencyCode),
                symbol: "exclamationmark.triangle",
                tint: Palette.danger
            )
        }
        return DiscrepancyDisplay(
            text: "Over by " + difference.magnitude.formatted(currencyCode: currencyCode),
            symbol: "arrow.up.circle",
            tint: Palette.neutral
        )
    }

    private var deadlineText: String {
        if item.status.isClosed {
            let verb = item.status == .credited ? "Credited" : "Closed"
            if let credited = item.creditedDate {
                return verb + " " + credited.formatted(date: .abbreviated, time: .omitted)
            }
            return item.status == .credited ? "Credited" : "Written off"
        }

        guard let due = item.dueDate else {
            return "Received " + item.receivedDate.formatted(date: .abbreviated, time: .omitted)
        }

        let dueText = due.formatted(date: .abbreviated, time: .omitted)
        guard let days = RiskCalculator.daysUntilDue(item, now: now, calendar: calendar) else {
            return "Due " + dueText
        }
        if days < 0 {
            return CoreDetailView.dayCount(-days) + " overdue — was due " + dueText
        }
        if days == 0 {
            return "Due today, " + dueText
        }
        if days == 1 {
            return "Due tomorrow, " + dueText
        }
        return "Due in " + CoreDetailView.dayCount(days) + ", " + dueText
    }

    private var deadlineSymbol: String {
        if item.status.isClosed { return item.status.symbolName }
        if isOverdue { return "exclamationmark.circle" }
        return "calendar"
    }

    private var deadlineTint: Color {
        if item.status.isClosed { return Palette.textSecondary }
        if isOverdue { return Palette.danger }
        if let days = RiskCalculator.daysUntilDue(item, now: now, calendar: calendar),
           days <= CoreDetailView.soonThresholdDays {
            return Palette.accent
        }
        return Palette.textSecondary
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func actionRowLabel(_ title: String,
                                systemImage: String,
                                tint: Color = Palette.textSecondary) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.s)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }

    /// A deadline inside this many days is drawn in amber.
    private static let soonThresholdDays = 3

    private static func dayCount(_ days: Int) -> String {
        days == 1 ? "1 day" : String(days) + " days"
    }

    // MARK: - Bindings

    /// The sheet that should be on screen right now.
    ///
    /// The finished dispute packet is only ever presented while *this* screen is the one waiting
    /// for it: `ExportCoordinator` is shared, and a document another screen asked for must not open
    /// a share sheet over this one.
    private var presentedRoute: CoreDetailModel.Route? {
        if model.isAwaitingExport, let document = appEnvironment.exports.presentedDocument {
            return .export(document)
        }
        return model.route
    }

    /// True while the sheet on screen is the finished dispute packet rather than one of the
    /// screen's own modals. Written as a `switch` so a new route case has to be considered here.
    private var isPresentingExport: Bool {
        guard let route = presentedRoute else { return false }
        switch route {
        case .export:
            return true
        case .editor, .credit, .binTag:
            return false
        }
    }

    private var routeBinding: Binding<CoreDetailModel.Route?> {
        Binding(
            get: { presentedRoute },
            set: { newValue in
                // SwiftUI only ever writes `nil` here — a sheet closing.
                guard newValue == nil else { return }
                if isPresentingExport {
                    closeExportSheet()
                }
                model.route = nil
            }
        )
    }
}

/// The one-line verdict on a recorded credit, with the glyph and tint that say the same thing
/// without colour.
private struct DiscrepancyDisplay {
    var text: String
    var symbol: String
    var tint: Color
}
