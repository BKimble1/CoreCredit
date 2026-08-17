//
//  ScanReviewSheet.swift
//  CoreCredit
//
//  Capture feature — the step between "the camera saw something" and "the draft says something".
//
//  ## Why this screen exists at all
//
//  A scan is evidence, not an instruction. Everything that reaches this sheet is a *proposal* with
//  its reasoning attached, and the only way any of it moves into the intake form is a deliberate tap
//  on **Apply Selected Suggestions**. Even then, nothing is written to the store: applying edits the
//  in-memory `CoreItemDraft`, and the record is still created by the editor's own Save action.
//
//  Three rules are load-bearing:
//
//  1. **Only `.high` starts selected.** `ScanCandidate.isSafeToPreselect` is the single gate, and a
//     row whose target field has nowhere to go starts off as well. A medium-confidence guess that
//     nobody looked at can never reach the ledger.
//  2. **`rawValue` survives.** The user edits `normalizedValue`; the recognised string is shown
//     underneath and is carried through untouched when the candidate is applied.
//  3. **Alternatives are offered, never applied.** Tapping a confusion variant (`O`/`0`, `I`/`1`)
//     fills the editable field so the user can see it before they accept it.
//
//  Confidence is spoken as High / Medium / Low. A percentage would imply a calibration these
//  heuristics do not have, and it invites arithmetic against an amount of money.
//

import SwiftUI
import UIKit

// MARK: - Session

/// One capture handed to the review UI: what was read, where it came from, and a preview.
///
/// `previewImageData` is held in memory for the life of the sheet and is never persisted — it is
/// there so a technician can check a value against the thing they photographed, not so the app can
/// keep a copy of it.
struct ScanReviewSession: Equatable, Sendable, Identifiable {

    var id: UUID

    var source: ScanSource

    /// Ranked highest-confidence first by whichever extractor produced them. The review sheet keeps
    /// that order rather than re-sorting, so the reasoning stays the extractor's.
    var candidates: [ScanCandidate]

    /// Everything that was recognised, for the "what did it actually see?" disclosure.
    var rawLines: [String]

    /// Preview only. Never written to the store.
    var previewImageData: Data?

    init(id: UUID = UUID(),
         source: ScanSource,
         candidates: [ScanCandidate],
         rawLines: [String] = [],
         previewImageData: Data? = nil) {
        self.id = id
        self.source = source
        self.candidates = candidates
        self.rawLines = rawLines
        self.previewImageData = previewImageData
    }
}

// MARK: - Sheet

/// Confirms — or corrects, or refuses — what a scan produced.
@MainActor
struct ScanReviewSheet: View {

    private let session: ScanReviewSession

    /// Called with the candidates the user ticked, carrying their edits and any retargeting.
    private let onApply: ([ScanCandidate]) -> Void

    /// Called when the user wants another go at the capture. The caller decides what "again" means
    /// — re-open the scanner, re-read the photo — and owns the presentation that follows.
    private let onRetake: () -> Void

    init(session: ScanReviewSession,
         onApply: @escaping ([ScanCandidate]) -> Void,
         onRetake: @escaping () -> Void) {
        self.session = session
        self.onApply = onApply
        self.onRetake = onRetake
    }

    @Environment(\.dismiss) private var dismiss

    /// Keeps the rows readable on an iPad instead of stretching one value across the whole width.
    private static let contentMaxWidth: CGFloat = 640

    var body: some View {
        NavigationStack {
            ScrollView {
                ScanCandidateReview(
                    session: session,
                    onApply: { candidates in
                        onApply(candidates)
                        dismiss()
                    },
                    onRetake: { onRetake() },
                    retakeTitle: "Retake",
                    onCancel: { dismiss() }
                )
                .padding(Spacing.l)
                .frame(maxWidth: ScanReviewSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Check the scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityHint(Text("Closes without changing anything."))
                }
            }
        }
        .tint(Palette.accent)
    }
}

// MARK: - Shared review content

/// The candidate list, shared by every path that produces candidates.
///
/// Live scanning, a photo read, and a multi-page document scan all end up here, so the rules about
/// selection, editing, and retargeting are written once. Hosts differ only in their chrome and in
/// what "retake" means to them.
@MainActor
struct ScanCandidateReview: View {

    private let session: ScanReviewSession
    private let onApply: ([ScanCandidate]) -> Void
    private let onRetake: (() -> Void)?
    private let retakeTitle: String
    private let onCancel: () -> Void

    /// One editable line per candidate. Seeded once per session and re-seeded when the host hands
    /// over a different one, so a re-read replaces the rows instead of leaving stale edits behind.
    @State private var rows: [ScanReviewRow]

    @State private var previewImage: UIImage?

    @State private var isShowingRawLines = false

    @FocusState private var focusedRow: UUID?

    /// - Parameters:
    ///   - session: What was captured.
    ///   - onApply: Receives the confirmed candidates. Never called with an empty array.
    ///   - onRetake: `nil` hides the retake action, for hosts where there is nothing to retake.
    ///   - retakeTitle: Wording for that action, e.g. "Retake" or "Read the photo again".
    ///   - onCancel: Leaves everything as it was.
    init(session: ScanReviewSession,
         onApply: @escaping ([ScanCandidate]) -> Void,
         onRetake: (() -> Void)? = nil,
         retakeTitle: String = "Retake",
         onCancel: @escaping () -> Void) {
        self.session = session
        self.onApply = onApply
        self.onRetake = onRetake
        self.retakeTitle = retakeTitle
        self.onCancel = onCancel
        _rows = State(initialValue: ScanCandidateReview.makeRows(from: session.candidates))
    }

    private static let previewHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            previewSection
            candidateSection
            rawLinesSection
            actionSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(A11y.ScanReview.root)
        .task(id: session.id) {
            previewImage = ScanCandidateReview.makePreviewImage(from: session.previewImageData)
        }
        .onChange(of: session.id) { _, _ in
            rows = ScanCandidateReview.makeRows(from: session.candidates)
            focusedRow = nil
            isShowingRawLines = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedRow = nil }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        if let previewImage = previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: ScanCandidateReview.previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("What was captured"))
                .accessibilityAddTraits(.isImage)
        }
    }

    // MARK: - Candidates

    @ViewBuilder
    private var candidateSection: some View {
        if rows.isEmpty {
            SectionCard {
                EmptyStateView(
                    symbol: "text.viewfinder",
                    title: "Nothing was recognised",
                    message: "Nothing readable came back from that capture. Try again in better "
                        + "light, or close this and type the details in — the form behind here "
                        + "works with no camera at all."
                )
            }
        } else {
            SectionCard(title: "What was read", systemImage: "text.viewfinder") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(guidanceText)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach($rows) { $row in
                        ScanCandidateRowView(row: $row, focusedRow: $focusedRow)
                    }
                }
            }
        }
    }

    private var guidanceText: String {
        "Read from " + session.source.displayName.lowercased()
            + ". Nothing changes until you tap Apply Selected Suggestions, and only the values "
            + "marked High start switched on — check every one against what is in front of you. "
            + "A misread digit is a wrong amount."
    }

    // MARK: - Raw lines

    @ViewBuilder
    private var rawLinesSection: some View {
        if session.rawLines.isEmpty == false {
            SectionCard(title: "Everything it saw", systemImage: "doc.plaintext") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Button {
                        isShowingRawLines.toggle()
                    } label: {
                        HStack(spacing: Spacing.s) {
                            Image(systemName: isShowingRawLines ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                            Text(isShowingRawLines ? "Hide the recognised text" : "Show the recognised text")
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Spacing.s)
                        }
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity,
                               minHeight: Spacing.minimumTapTarget,
                               alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isShowingRawLines
                                             ? "Hide the recognised text"
                                             : "Show the recognised text"))
                    .accessibilityHint(Text("Lists every line the scan read, in order."))

                    if isShowingRawLines {
                        ForEach(Array(session.rawLines.enumerated()), id: \.offset) { pair in
                            Text(pair.element)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Button {
                applySelected()
            } label: {
                PrimaryButtonLabel("Apply Selected Suggestions", systemImage: "checkmark")
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .accessibilityIdentifier(A11y.ScanReview.apply)
            .accessibilityLabel(Text("Apply selected suggestions"))
            .accessibilityValue(Text(selectedPhrase))
            .accessibilityHint(Text("Fills the form behind this sheet. Nothing is saved until you "
                                    + "tap Save on the form."))

            if let onRetake = onRetake {
                Button {
                    focusedRow = nil
                    onRetake()
                } label: {
                    ScanActionLabel(title: retakeTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.ScanReview.retake)
                .accessibilityLabel(Text(retakeTitle))
                .accessibilityHint(Text("Throws this reading away and captures again."))
            }

            Button {
                focusedRow = nil
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.ScanReview.cancel)
            .accessibilityLabel(Text("Cancel"))
            .accessibilityHint(Text("Closes without changing anything on the form."))
        }
    }

    /// How many rows would actually be applied right now — a ticked row with an empty value, or one
    /// pointed at nothing, is not one of them.
    private var selectedCount: Int {
        rows.reduce(into: 0) { total, row in
            if ScanCandidateReview.isApplicable(row) { total += 1 }
        }
    }

    private var selectedPhrase: String {
        let count = selectedCount
        return count == 1 ? "1 suggestion selected" : String(count) + " suggestions selected"
    }

    /// Hands the confirmed candidates to the host.
    ///
    /// Each one keeps its original `rawValue` and its reasoning, and carries the user's edited text
    /// as `normalizedValue`. Retargeting changes the `kind`, which is what decides the field the
    /// draft receives it in.
    private func applySelected() {
        focusedRow = nil
        let confirmed = rows.compactMap { row -> ScanCandidate? in
            guard ScanCandidateReview.isApplicable(row) else { return nil }
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = row.candidate
            return ScanCandidate(kind: row.targetKind,
                                 rawValue: original.rawValue,
                                 normalizedValue: value,
                                 confidence: original.confidence,
                                 source: original.source,
                                 reason: original.reason,
                                 barcodeSymbology: original.barcodeSymbology,
                                 page: original.page,
                                 boundingBox: original.boundingBox,
                                 alternatives: original.alternatives,
                                 id: original.id)
        }
        guard confirmed.isEmpty == false else { return }
        onApply(confirmed)
    }

    // MARK: - Seeding

    /// Builds the editable rows.
    ///
    /// **This is where "nothing low-confidence auto-selects" lives.** A row starts ticked only when
    /// `ScanCandidate.isSafeToPreselect` is true — which is `.high` and nothing else — and only when
    /// its kind names somewhere for the value to go.
    private static func makeRows(from candidates: [ScanCandidate]) -> [ScanReviewRow] {
        candidates.map { candidate in
            ScanReviewRow(
                candidate: candidate,
                value: candidate.normalizedValue,
                targetKind: candidate.kind,
                isSelected: candidate.isSafeToPreselect
                    && ScanCandidateTarget.canApply(candidate.kind)
            )
        }
    }

    private static func isApplicable(_ row: ScanReviewRow) -> Bool {
        guard row.isSelected else { return false }
        guard ScanCandidateTarget.canApply(row.targetKind) else { return false }
        return row.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func makePreviewImage(from data: Data?) -> UIImage? {
        guard let data = data, data.isEmpty == false else { return nil }
        return ImageProcessor.thumbnail(from: data, maxDimension: previewHeight * 3)
    }
}

// MARK: - Row model

/// One candidate as the user is currently editing it.
private struct ScanReviewRow: Identifiable, Equatable {

    /// The proposal this row came from. Never mutated — it is the record of what was recognised.
    let candidate: ScanCandidate

    /// The text that will be applied. Starts as `candidate.normalizedValue`.
    var value: String

    /// Where the value is headed. Starts as the candidate's own kind and changes when the user
    /// retargets the row.
    var targetKind: ScanCandidateKind

    var isSelected: Bool

    var id: UUID { candidate.id }
}

// MARK: - Targets

/// Which kinds name a place a confirmed value can actually go.
///
/// `.date` and `.unknown` are missing on purpose: the received date comes from the app's own clock,
/// and unrecognised text has no home until the user says where it belongs. Both are still shown,
/// still editable, and still retargetable — they simply cannot be applied as they are.
enum ScanCandidateTarget {

    /// Offered in the field picker, in the order a counter would look for them.
    static let selectableKinds: [ScanCandidateKind] = [
        .partNumber, .coreAmount, .invoiceNumber, .repairOrder,
        .vendorName, .returnReference, .barcode
    ]

    /// Whether a value pointed at this kind has somewhere to land.
    static func canApply(_ kind: ScanCandidateKind) -> Bool {
        if kind == .barcode { return true }
        return kind.coreItemField != nil
    }

    /// What the user is told the value will fill.
    static func destinationName(for kind: ScanCandidateKind) -> String {
        switch kind {
        case .barcode:
            return "Kept as the scanned barcode"
        case .date, .unknown:
            return "Nowhere yet — pick a field"
        case .partNumber, .invoiceNumber, .repairOrder, .vendorName, .coreAmount, .returnReference:
            guard let field = kind.coreItemField else { return "Nowhere yet — pick a field" }
            return "Goes into " + field.displayName
        }
    }
}

// MARK: - Row

/// One suggestion: what it is, how sure the scan was, why, what was actually read, and an editable
/// value with somewhere to send it.
@MainActor
private struct ScanCandidateRowView: View {

    @Binding private var row: ScanReviewRow
    @FocusState.Binding private var focusedRow: UUID?

    /// Written out rather than synthesised so the focus binding is forwarded explicitly, the way
    /// the editor's own fields do it.
    init(row: Binding<ScanReviewRow>, focusedRow: FocusState<UUID?>.Binding) {
        self._row = row
        self._focusedRow = focusedRow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            selectionToggle
            valueField
            alternativesStrip
            rawValueLine
            fieldPicker
        }
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(A11y.ScanReview.row(row.candidate.id))
    }

    // MARK: Selection

    private var selectionToggle: some View {
        Toggle(isOn: $row.isSelected) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: row.candidate.kind.symbolName)
                        .imageScale(.medium)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)

                    Text(row.candidate.kind.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Spacing.xs) {
                    Image(systemName: bandSymbolName)
                        .imageScale(.small)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)

                    Text(row.candidate.band.displayName + " confidence")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(row.candidate.reason)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(ScanCandidateTarget.canApply(row.targetKind) == false)
        .frame(minHeight: Spacing.minimumTapTarget)
        .accessibilityLabel(Text(spokenToggleLabel))
        .accessibilityValue(Text(spokenToggleValue))
        .accessibilityHint(Text(spokenToggleHint))
    }

    /// Band as a shape as well as a word, so the three levels are distinguishable without colour.
    /// Deliberately not tinted: in this app amber means "act now", green means "money arrived", and
    /// red means "overdue" — none of which is what a confidence level is saying.
    private var bandSymbolName: String {
        switch row.candidate.band {
        case .high: return "checkmark.circle"
        case .medium: return "questionmark.circle"
        case .low: return "exclamationmark.circle"
        }
    }

    private var spokenToggleLabel: String {
        row.candidate.kind.displayName + ", " + spokenValue
    }

    private var spokenToggleValue: String {
        row.candidate.band.displayName + " confidence. " + row.candidate.reason
    }

    private var spokenToggleHint: String {
        guard ScanCandidateTarget.canApply(row.targetKind) else {
            return "This one has no field yet. Choose a field for it first."
        }
        return ScanCandidateTarget.destinationName(for: row.targetKind)
            + ". Nothing changes until you apply."
    }

    /// VoiceOver reads an empty field as "empty" rather than skipping it in silence.
    private var spokenValue: String {
        let trimmed = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "empty" : trimmed
    }

    // MARK: Value

    private var valueField: some View {
        TextField(row.candidate.kind.displayName, text: $row.value)
            .font(Typography.rowTitle)
            .foregroundStyle(Palette.textPrimary)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($focusedRow, equals: row.candidate.id)
            .onSubmit { focusedRow = nil }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Spacing.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? Palette.accent : Palette.hairline,
                                  lineWidth: isFocused ? 2 : 1)
            )
            .accessibilityLabel(Text(row.candidate.kind.displayName + " value"))
            .accessibilityHint(Text("Correct it here before you apply it."))
    }

    private var isFocused: Bool {
        focusedRow == row.candidate.id
    }

    /// The amount is digits; every identifier can carry letters, hyphens, and slashes, so it never
    /// gets a number pad that would hide them.
    private var keyboardType: UIKeyboardType {
        switch row.targetKind {
        case .coreAmount:
            return .decimalPad
        case .vendorName, .unknown, .date:
            return .default
        case .partNumber, .barcode, .invoiceNumber, .repairOrder, .returnReference:
            return .numbersAndPunctuation
        }
    }

    private var autocapitalization: TextInputAutocapitalization {
        switch row.targetKind {
        case .coreAmount:
            return .never
        case .vendorName:
            return .words
        case .date, .unknown:
            return .sentences
        case .partNumber, .barcode, .invoiceNumber, .repairOrder, .returnReference:
            return .characters
        }
    }

    // MARK: Alternatives

    /// Character-confusion variants, offered as chips. Tapping one fills the field so the user can
    /// look at it; nothing is swapped on their behalf.
    @ViewBuilder
    private var alternativesStrip: some View {
        if row.candidate.alternatives.isEmpty == false {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Could also be")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(Array(row.candidate.alternatives.enumerated()), id: \.offset) { pair in
                            alternativeChip(pair.element)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
            }
        }
    }

    private func alternativeChip(_ alternative: String) -> some View {
        Button {
            row.value = alternative
        } label: {
            Text(alternative)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Spacing.minimumTapTarget)
                .background(
                    Capsule(style: .continuous).fill(Palette.surfaceElevated)
                )
                .overlay(
                    Capsule(style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Use " + alternative + " instead"))
        .accessibilityHint(Text("Puts it in the value field. It is still not applied until you "
                                + "tap apply."))
    }

    // MARK: Raw value

    /// What was actually recognised, always shown. Months from now this is the only way to answer
    /// "did it misread it, or did someone change it?".
    private var rawValueLine: some View {
        Text("Read as " + row.candidate.rawValue)
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text("Read as " + row.candidate.rawValue))
    }

    // MARK: Field picker

    private var fieldPicker: some View {
        Menu {
            ForEach(ScanCandidateTarget.selectableKinds) { kind in
                Button {
                    row.targetKind = kind
                } label: {
                    Label(kind.displayName,
                          systemImage: kind == row.targetKind ? "checkmark" : kind.symbolName)
                }
            }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "arrow.turn.down.right")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                Text(ScanCandidateTarget.destinationName(for: row.targetKind))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: Spacing.s)

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Field for " + row.candidate.kind.displayName))
        .accessibilityValue(Text(ScanCandidateTarget.destinationName(for: row.targetKind)))
        .accessibilityHint(Text("Sends this value to a different field on the form."))
    }
}

// MARK: - Secondary action label

/// The label for a supporting action on the capture sheets — retake, resume, scan a document.
///
/// Outlined rather than filled: amber is reserved for the one primary action on a screen, which on
/// these sheets is applying the suggestions. Shared by the capture feature's sheets so the secondary
/// actions on all of them are the same shape.
@MainActor
struct ScanActionLabel: View {

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

#Preview("Scan review") {
    ScanReviewSheet(
        session: ScanReviewSession(
            source: .documentOCR,
            candidates: [
                ScanCandidate(kind: .coreAmount,
                              rawValue: "$86.50",
                              normalizedValue: "86.50",
                              confidence: 0.92,
                              source: .documentOCR,
                              reason: "Follows the label \"CORE CHARGE\".",
                              alternatives: ["86.5O"]),
                ScanCandidate(kind: .partNumber,
                              rawValue: "03-1887",
                              confidence: 0.64,
                              source: .documentOCR,
                              reason: "Looks like a part number on the same line as \"P/N\".",
                              alternatives: ["O3-1887", "03-l887"])
            ],
            rawLines: ["NAPA AUTO PARTS", "P/N 03-1887", "CORE CHARGE $86.50"]
        ),
        onApply: { _ in },
        onRetake: { }
    )
}
