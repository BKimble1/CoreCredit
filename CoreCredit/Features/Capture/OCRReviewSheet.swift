//
//  OCRReviewSheet.swift
//  CoreCredit
//
//  Capture feature — reading a photo, and asking before believing it.
//
//  ## Suggestions, never commits
//
//  Vision is a suggestion engine here and nothing else. Every value it produces lands in an
//  editable field with its own on/off switch, and **nothing reaches the draft until the user taps
//  "Apply selected"**. A misread 8 for a 3 in a core charge is a money error in a shop's ledger, so
//  the human stays in the loop by construction rather than by carefulness.
//
//  Confidence is spoken in words — "Likely", "Possible" — never as a number. A percentage invites
//  a user to trust arithmetic they cannot check; a word invites them to look at the photo.
//

import SwiftUI
import UIKit

/// Reviews and confirms OCR suggestions taken from one photo.
@MainActor
struct OCRReviewSheet: View {

    /// The image to read. Already downsampled by `ImageProcessor` when it came from an attachment.
    private let imageData: Data

    /// Called with the suggestions the user selected, carrying whatever edits they made.
    private let onApply: ([OCRFieldSuggestion]) -> Void

    init(imageData: Data, onApply: @escaping ([OCRFieldSuggestion]) -> Void) {
        self.imageData = imageData
        self.onApply = onApply
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .recognising
    @State private var edits: [UUID: String] = [:]
    @State private var selections: [UUID: Bool] = [:]
    @FocusState private var focusedSuggestion: UUID?

    /// Where the read has got to.
    private enum Phase: Equatable {
        case recognising
        case ready([OCRFieldSuggestion])
        case noText
        case failed(String)
    }

    /// Above this the extractor's evidence was strong enough to call "Likely".
    private static let likelyThreshold: Double = 0.7

    private static let contentMaxWidth: CGFloat = 640
    private static let previewHeight: CGFloat = 160

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    photoPreview
                    phaseContent
                }
                .padding(Spacing.l)
                .frame(maxWidth: OCRReviewSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Read photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint(Text("Closes without changing anything."))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedSuggestion = nil }
                }
            }
        }
        .tint(Palette.accent)
        .task {
            await recognise()
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var photoPreview: some View {
        if let image = ImageProcessor.thumbnail(from: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: OCRReviewSheet.previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("The photo being read"))
                .accessibilityAddTraits(.isImage)
        }
    }

    // MARK: - Phases

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .recognising:
            SectionCard {
                HStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("Reading the photo…")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Reading the photo"))
                .accessibilityAddTraits(.updatesFrequently)
            }

        case .noText:
            SectionCard {
                EmptyStateView(
                    symbol: "text.viewfinder",
                    title: "Nothing readable found",
                    message: RecognitionError.noTextFound.errorDescription
                        ?? "No text was found in that photo.",
                    actionTitle: "Try reading it again",
                    action: { Task { await recognise() } }
                )
            }
            enterManuallyButton

        case .failed(let message):
            ErrorBanner(message: message,
                        retryTitle: "Try again",
                        onRetry: { Task { await recognise() } })
            enterManuallyButton

        case .ready(let suggestions):
            suggestionList(suggestions)
        }
    }

    /// Always offered next to a failure: the form behind this sheet is fully typeable.
    private var enterManuallyButton: some View {
        Button {
            dismiss()
        } label: {
            PrimaryButtonLabel("Enter the details by hand", systemImage: "keyboard")
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Closes this sheet and returns to the form."))
    }

    // MARK: - Suggestions

    private func suggestionList(_ suggestions: [OCRFieldSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SectionCard(title: "Suggestions", systemImage: "text.viewfinder") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("Nothing is changed until you tap Apply selected. "
                         + "Check every value against the photo — a misread digit is a wrong amount.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }

            Button {
                applySelected(from: suggestions)
            } label: {
                PrimaryButtonLabel("Apply selected", systemImage: "checkmark")
            }
            .buttonStyle(.plain)
            .disabled(selectedCount(in: suggestions) == 0)
            .accessibilityLabel(Text("Apply selected"))
            .accessibilityValue(Text(String(selectedCount(in: suggestions)) + " selected"))

            Button {
                dismiss()
            } label: {
                Text("Don't apply anything")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func suggestionRow(_ suggestion: OCRFieldSuggestion) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(isOn: selectionBinding(for: suggestion.id)) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(suggestion.field.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(confidenceWord(suggestion.confidence) + " match — goes into "
                         + suggestion.field.coreItemField.displayName)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Apply " + suggestion.field.displayName))
            .accessibilityValue(Text(confidenceWord(suggestion.confidence) + " match"))

            TextField(suggestion.field.displayName, text: textBinding(for: suggestion.id))
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .keyboardType(keyboardType(for: suggestion.field))
                .textInputAutocapitalization(autocapitalization(for: suggestion.field))
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedSuggestion, equals: suggestion.id)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Spacing.minimumTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .accessibilityLabel(Text(suggestion.field.displayName + " value"))
                .accessibilityHint(Text("Correct it here before applying."))
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Bindings

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selections[id] ?? false },
            set: { selections[id] = $0 }
        )
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { edits[id] ?? "" },
            set: { edits[id] = $0 }
        )
    }

    // MARK: - Work

    /// Runs recognition and turns the lines into suggestions.
    ///
    /// Re-entrant by design: the retry buttons call it again, and it resets its own state first.
    private func recognise() async {
        phase = .recognising
        edits = [:]
        selections = [:]

        do {
            let lines = try await appEnvironment.textRecognizer.recognizeLines(in: imageData)
            let suggestions = OCRSuggestionExtractor.suggestions(from: lines.map { $0.text })
            guard !suggestions.isEmpty else {
                phase = .noText
                return
            }
            for suggestion in suggestions {
                edits[suggestion.id] = suggestion.value
                selections[suggestion.id] = true
            }
            phase = .ready(suggestions)
        } catch let error as RecognitionError {
            if error == .noTextFound {
                phase = .noText
            } else {
                phase = .failed(error.errorDescription
                    ?? "Reading the photo didn't work. Type the details in instead.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Hands the confirmed values back, then closes.
    ///
    /// A suggestion the user emptied out is dropped rather than applied as a blank, and each
    /// applied value carries the text as edited, not the text as recognised.
    private func applySelected(from suggestions: [OCRFieldSuggestion]) {
        var confirmed: [OCRFieldSuggestion] = []
        for suggestion in suggestions {
            guard selections[suggestion.id] == true else { continue }
            let value = (edits[suggestion.id] ?? suggestion.value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            confirmed.append(OCRFieldSuggestion(field: suggestion.field,
                                                value: value,
                                                confidence: suggestion.confidence))
        }
        onApply(confirmed)
        dismiss()
    }

    private func selectedCount(in suggestions: [OCRFieldSuggestion]) -> Int {
        suggestions.reduce(into: 0) { total, suggestion in
            if selections[suggestion.id] == true { total += 1 }
        }
    }

    // MARK: - Presentation helpers

    /// Confidence in words. Never a percentage — see the note at the top of this file.
    private func confidenceWord(_ confidence: Double) -> String {
        confidence >= OCRReviewSheet.likelyThreshold ? "Likely" : "Possible"
    }

    /// The amount is digits; everything else is a reference that can carry letters and hyphens.
    private func keyboardType(for field: OCRField) -> UIKeyboardType {
        switch field {
        case .amount:
            return .decimalPad
        case .partNumber, .invoiceReference, .repairOrderReference:
            return .numbersAndPunctuation
        case .vendorName:
            return .default
        }
    }

    /// Part numbers and references are shouted on invoices; a vendor name is a proper noun.
    private func autocapitalization(for field: OCRField) -> TextInputAutocapitalization {
        switch field {
        case .partNumber, .invoiceReference, .repairOrderReference:
            return .characters
        case .vendorName:
            return .words
        case .amount:
            return .never
        }
    }
}
