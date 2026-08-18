//
//  RecordCreditSheet.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The reconciliation moment: the vendor's credit memo, compared against what was expected.
///
/// The amount is pre-filled with the expected credit, so the common case — the vendor credited
/// exactly the core charge — is one tap. Anything else is previewed *before* it is saved: as the
/// amount changes, `CreditReconciler.outcome(expected:actual:)` is recomputed and the consequence
/// is spelled out in words, with a glyph, never in colour alone.
///
/// `0.00` is a legitimate entry. "The vendor never credited us" is exactly the case this app exists
/// to make provable, so it is accepted and produces a full-value dispute. Only empty or unreadable
/// input is a validation error.
struct RecordCreditSheet: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @Query private var profiles: [ShopProfile]

    private let item: CoreItem

    @State private var creditDate = Date()
    @State private var hasSeededCreditDate = false
    @State private var reference: String
    @State private var amountText: String
    @State private var errorMessage: String?
    @State private var savedOutcome: CreditOutcome?

    init(item: CoreItem) {
        self.item = item
        _amountText = State(initialValue: item.expectedCredit.plainDecimalString)
        _reference = State(initialValue: item.creditReference)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    contextCard

                    if let outcome = savedOutcome {
                        resultCard(outcome)
                    } else {
                        if canRecordCredit == false {
                            wrongStatusCard
                        }
                        entryCard
                        previewCard
                        saveCard
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Save is the last thing on this sheet, so the same fix the root screens got: the
            // background is painted behind the scroll view rather than stacked beside one that
            // ignores the safe area and drags the whole stack past it.
            .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
            .background {
                Palette.background.ignoresSafeArea()
            }
            .navigationTitle("Record credit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedOutcome == nil ? "Cancel" : "Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if hasSeededCreditDate == false {
                    creditDate = item.creditedDate ?? appEnvironment.dateProvider.now
                    hasSeededCreditDate = true
                }
            }
            .sheet(item: exportDocumentBinding) { document in
                CreditExportShareView(document: document)
            }
        }
    }

    // MARK: - Derived state

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    /// A credit is only legal from `.returnedAwaitingCredit` and `.disputed`; anywhere else
    /// `CoreItemService.recordCredit` throws `DomainError.invalidTransition`.
    private var canRecordCredit: Bool {
        item.status == .returnedAwaitingCredit || item.status == .disputed
    }

    /// The amount the vendor actually credited, parsed from the field.
    ///
    /// Parsing goes through `Money.parse` and nothing else — no `Double` is ever built from typed
    /// input, so a cent cannot be lost between the keyboard and the ledger.
    private var parsedAmount: Money? {
        Money.parse(amountText, locale: locale)
    }

    /// Validation message for the amount field, or `nil` when the entry is usable.
    ///
    /// Zero is deliberately *not* an error.
    private var amountError: String? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter the amount the vendor credited. Enter 0.00 if no credit arrived."
        }
        guard let amount = parsedAmount else {
            return "That isn't an amount this app can read. Enter it like 86.50."
        }
        if amount.isNegative {
            return "A credit can't be a negative amount."
        }
        return nil
    }

    /// The live comparison shown under the field. `nil` while the entry is unusable.
    private var previewOutcome: CreditOutcome? {
        guard amountError == nil, let amount = parsedAmount else { return nil }
        return CreditReconciler.outcome(expected: item.expectedCredit, actual: amount)
    }

    /// Money that would come off Money at Risk if this core closed right now.
    private var currentExposure: Money {
        RiskCalculator.remainingExposure(for: item)
    }

    private var exportDocumentBinding: Binding<ExportDocument?> {
        Binding(
            get: { appEnvironment.exports.presentedDocument },
            set: { newValue in appEnvironment.exports.presentedDocument = newValue }
        )
    }

    // MARK: - Context

    private var contextCard: some View {
        SectionCard(title: item.displayTitle, systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.m) {
                    StatusBadge(status: item.status, compact: false)
                    Spacer(minLength: Spacing.s)
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    LabeledValueRow("Vendor", value: item.vendorName ?? "", symbol: "building.2")
                    LabeledValueRow(
                        "Expected credit",
                        value: item.expectedCredit.formatted(currencyCode: currencyCode),
                        symbol: "dollarsign.circle",
                        isMonospaced: true
                    )
                    LabeledValueRow(
                        "Invoice",
                        value: item.invoiceReference,
                        symbol: "doc.text",
                        isMonospaced: true
                    )
                    if let returnedDate = item.returnedDate {
                        LabeledValueRow(
                            "Returned",
                            value: returnedDate.formatted(date: .abbreviated, time: .omitted),
                            symbol: "calendar"
                        )
                    }
                    if let actual = item.actualCredit {
                        LabeledValueRow(
                            "Already credited",
                            value: actual.formatted(currencyCode: currencyCode),
                            symbol: CoreStatus.credited.symbolName,
                            isMonospaced: true
                        )
                    }
                }
            }
        }
    }

    private var wrongStatusCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label("This core hasn't gone back yet", systemImage: "exclamationmark.triangle")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)

                Text("A credit can only be recorded once a core has been returned to the vendor, or while it is in dispute. This one is "
                     + item.status.displayName
                     + ". Send it back on a return first, then record the credit here.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Entry

    private var entryCard: some View {
        SectionCard(title: "Vendor credit", systemImage: CoreStatus.credited.symbolName) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                CreditFieldWell(title: "Credit date") {
                    DatePicker(
                        "Credit date",
                        selection: $creditDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Palette.accent)
                    .accessibilityLabel(Text("Credit date"))
                }

                CreditFieldWell(
                    title: "Credit memo number",
                    hint: "The reference printed on the vendor's credit memo."
                ) {
                    TextField("Credit memo number", text: $reference)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier(A11y.Credit.reference)
                        .accessibilityLabel(Text("Credit memo number"))
                }

                CurrencyTextField(
                    title: "Amount credited",
                    text: $amountText,
                    currencyCode: currencyCode,
                    errorMessage: amountError,
                    focusHint: "Pre-filled with the expected credit. Enter 0.00 if the vendor never credited you.",
                    fieldIdentifier: A11y.Credit.amount
                )
            }
        }
    }

    // MARK: - Live preview

    @ViewBuilder
    private var previewCard: some View {
        if let outcome = previewOutcome, let amount = parsedAmount {
            CreditOutcomeCallout(
                title: previewTitle(outcome, amount: amount),
                detail: previewDetail(outcome, amount: amount),
                symbol: calloutSymbol(for: outcome),
                tint: calloutTint(for: outcome)
            )
        }
    }

    private func previewTitle(_ outcome: CreditOutcome, amount: Money) -> String {
        switch outcome {
        case .exact:
            return "Matches the core charge"
        case .short:
            if amount.isZero { return "No credit received" }
            return outcome.summaryText + outcome.difference.formatted(currencyCode: currencyCode)
        case .over:
            return "Credited more than expected"
        }
    }

    private func previewDetail(_ outcome: CreditOutcome, amount: Money) -> String {
        switch outcome {
        case .exact:
            return "Closes this core. Money at risk drops by "
                + currentExposure.formatted(currencyCode: currencyCode)
                + "."

        case .short(let difference):
            if amount.isZero {
                return "Recording zero is how you log a credit that never arrived. This core moves to Disputed for the full "
                    + item.expectedCredit.formatted(currencyCode: currencyCode)
                    + ", and that money stays in Money at Risk until it is settled or written off."
            }
            return "Short by "
                + difference.formatted(currencyCode: currencyCode)
                + ". This core moves to Disputed so you can chase it, and the shortfall stays in Money at Risk."

        case .over(let difference):
            return "Vendor credited "
                + difference.formatted(currencyCode: currencyCode)
                + " more than expected. This core will close."
        }
    }

    /// Glyph for an outcome. Green is reserved for credits that actually landed, red for the
    /// dispute a short credit opens — the two colours this app allows to carry meaning.
    private func calloutSymbol(for outcome: CreditOutcome) -> String {
        switch outcome {
        case .exact: return CoreStatus.credited.symbolName
        case .short: return CoreStatus.disputed.symbolName
        case .over: return "plus.circle"
        }
    }

    private func calloutTint(for outcome: CreditOutcome) -> Color {
        switch outcome {
        case .exact, .over: return Palette.positive
        case .short: return Palette.danger
        }
    }

    // MARK: - Save

    private var saveCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let errorMessage = errorMessage {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                }

                Button {
                    save()
                } label: {
                    PrimaryButtonLabel("Save credit", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                .disabled(amountError != nil)
                .accessibilityIdentifier(A11y.Credit.save)
                .accessibilityHint(Text(saveHint))

                Text("Every credit is written to this core's history with its date and memo number, so the paper trail survives the argument.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var saveHint: String {
        if let error = amountError { return error }
        guard let outcome = previewOutcome, let amount = parsedAmount else {
            return "Records the vendor's credit against this core."
        }
        return previewTitle(outcome, amount: amount) + ". " + previewDetail(outcome, amount: amount)
    }

    // MARK: - Result

    private func resultCard(_ outcome: CreditOutcome) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.l) {
                CreditOutcomeCallout(
                    title: resultTitle(outcome),
                    detail: resultDetail(outcome),
                    symbol: calloutSymbol(for: outcome),
                    tint: calloutTint(for: outcome)
                )

                if isShort(outcome) {
                    disputeActions
                }

                Button {
                    dismiss()
                } label: {
                    PrimaryButtonLabel("Done", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// True only for a short credit — the one outcome that leaves money on the table and therefore
    /// the only one that offers the dispute packet.
    private func isShort(_ outcome: CreditOutcome) -> Bool {
        if case .short = outcome { return true }
        return false
    }

    private func resultTitle(_ outcome: CreditOutcome) -> String {
        switch outcome {
        case .exact: return "Credit recorded"
        case .short: return "Dispute opened"
        case .over: return "Credit recorded"
        }
    }

    private func resultDetail(_ outcome: CreditOutcome) -> String {
        switch outcome {
        case .exact:
            return "This core is Credited and out of Money at Risk."

        case .short(let difference):
            return "The credit was short by "
                + difference.formatted(currencyCode: currencyCode)
                + ". This core is now Disputed and the shortfall stays in Money at Risk until you settle it or write it off."

        case .over(let difference):
            return "The vendor credited "
                + difference.formatted(currencyCode: currencyCode)
                + " more than expected. This core is Credited and out of Money at Risk."
        }
    }

    /// Straight from the dispute into the paperwork that settles it.
    private var disputeActions: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let exportError = appEnvironment.exports.lastError {
                ErrorBanner(message: exportError)
            }

            Button {
                exportDisputePacket()
            } label: {
                PrimaryButtonLabel("Export dispute packet", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(appEnvironment.exports.inFlight)
            .accessibilityHint(Text("Builds a PDF with the invoice, the photos, and the expected-versus-actual figures to send to the vendor."))

            if appEnvironment.exports.inFlight {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("Building the packet…")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(minHeight: Spacing.minimumTapTarget, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func save() {
        guard let amount = parsedAmount, amount.isNegative == false else {
            errorMessage = amountError ?? "Enter the amount the vendor credited."
            return
        }

        errorMessage = nil

        let reconciliation = CreditReconciliation(
            creditDate: creditDate,
            reference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount
        )

        do {
            savedOutcome = try appEnvironment
                .itemService(modelContext)
                .recordCredit(item, reconciliation: reconciliation)
        } catch DomainError.invalidTransition(let from, _) {
            // Not a crash and not developer jargon: say which state the core is actually in and
            // what has to happen first.
            errorMessage = "This core is "
                + from.displayName
                + ". A vendor credit can only be recorded once the core has gone back on a return, or while it is in dispute."
        } catch {
            errorMessage = ReturnsModel.message(for: error)
        }
    }

    private func exportDisputePacket() {
        guard let profile = resolvedProfile() else {
            errorMessage = "Your shop details couldn't be loaded, so the packet can't be built yet. Open Settings and fill in your shop name."
            return
        }
        let target = item
        Task {
            await appEnvironment.exports.exportDisputePacket(for: target, profile: profile)
        }
    }

    /// The stored shop profile, creating the single row if it does not exist yet.
    private func resolvedProfile() -> ShopProfile? {
        if let profile = profiles.first { return profile }
        return try? appEnvironment.itemService(modelContext).shopProfile()
    }
}

// MARK: - CreditOutcomeCallout

/// The discrepancy preview, and the confirmation that replaces it after saving.
///
/// Glyph, headline, and sentence all carry the same message, so the outcome is never signalled by
/// colour alone. The whole callout is one accessibility element and is read as a single phrase.
private struct CreditOutcomeCallout: View {

    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title + ". " + detail))
    }
}

// MARK: - CreditFieldWell

/// A labelled entry well matching `CurrencyTextField`'s treatment.
private struct CreditFieldWell<Content: View>: View {

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
                        .strokeBorder(Palette.hairline, lineWidth: 1)
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

// MARK: - CreditExportShareView

/// Hands the finished dispute packet to the share sheet.
private struct CreditExportShareView: View {

    @Environment(\.dismiss) private var dismiss

    let document: ExportDocument

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background
                    .ignoresSafeArea()

                VStack(spacing: Spacing.l) {
                    Image(systemName: "doc.text")
                        .font(.system(.largeTitle, design: .default, weight: .regular))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)

                    Text("Dispute packet ready")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.textPrimary)

                    Text(document.suggestedName)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    ShareLink("Send to the vendor", item: document.url)
                        .font(.body.weight(.semibold))
                        .frame(minHeight: Spacing.minimumTapTarget)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 420)
            }
            .navigationTitle("Dispute packet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
