//
//  OCRReviewSheet.swift
//  CoreCredit
//
//  Capture feature — reading a photo, and asking before believing it.
//
//  ## Suggestions, never commits
//
//  Vision is a suggestion engine here and nothing else. Every value it produces lands in an editable
//  field with its own on/off switch, and **nothing reaches the draft until the user taps Apply
//  Selected Suggestions**. A misread 8 for a 3 in a core charge is a money error in a shop's ledger,
//  so the human stays in the loop by construction rather than by carefulness.
//
//  The rows themselves are `ScanCandidateReview`, shared with the live scanner: the rules about what
//  starts ticked, what the raw reading was, and where a value is allowed to go are written once.
//  Only `.high`-confidence candidates start selected — see `ScanCandidate.isSafeToPreselect`.
//
//  ## One photo, or the whole document
//
//  A single photograph is the quick path. An invoice that runs to several pages goes through
//  `DocumentScannerView` instead, whose pages are read by `TextRecognizing.recognizePages(_:)` and
//  ranked by exactly the same extractor.
//

import SwiftUI
import UIKit

/// Reviews and confirms the candidates read out of one photo.
@MainActor
struct OCRReviewSheet: View {

    /// The image to read. Already downsampled by `ImageProcessor` when it came from an attachment.
    private let imageData: Data

    /// Called with the candidates the user selected, carrying whatever edits they made.
    private let onApply: ([ScanCandidate]) -> Void

    init(imageData: Data, onApply: @escaping ([ScanCandidate]) -> Void) {
        self.imageData = imageData
        self.onApply = onApply
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .recognising
    @State private var isPresentingDocumentScan = false

    /// Where the read has got to.
    private enum Phase: Equatable {
        case recognising
        case ready(ScanReviewSession)
        case noText
        case failed(String)
    }

    private static let contentMaxWidth: CGFloat = 640
    private static let previewHeight: CGFloat = 160

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
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
            }
        }
        .tint(Palette.accent)
        .task {
            await recognise()
        }
        // The only presentation this screen owns. The document scanner is a separate capture, so it
        // gets its own sheet rather than being wedged into this one's phases.
        .sheet(isPresented: $isPresentingDocumentScan) {
            DocumentScanSheet { candidates in
                onApply(candidates)
                isPresentingDocumentScan = false
                dismiss()
            }
        }
    }

    // MARK: - Preview

    /// Shown while there is nothing else to look at. Once the candidates are ready the review
    /// content carries its own preview, so the photo is not drawn twice.
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
            photoPreview
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
            photoPreview
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
            documentScanButton
            enterManuallyButton

        case .failed(let message):
            photoPreview
            ErrorBanner(message: message,
                        retryTitle: "Try again",
                        onRetry: { Task { await recognise() } })
            documentScanButton
            enterManuallyButton

        case .ready(let session):
            ScanCandidateReview(
                session: session,
                onApply: { candidates in
                    onApply(candidates)
                    dismiss()
                },
                onRetake: { Task { await recognise() } },
                retakeTitle: "Read the photo again",
                onCancel: { dismiss() }
            )
            documentScanButton
        }
    }

    /// The multi-page path. Offered next to a poor result and under a good one, because an invoice
    /// photographed at an angle often reads far better through the document camera.
    private var documentScanButton: some View {
        Button {
            isPresentingDocumentScan = true
        } label: {
            ScanActionLabel(title: "Scan the whole document instead",
                            systemImage: "doc.viewfinder")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Scan the whole document instead"))
        .accessibilityHint(Text("Opens the document camera for a multi-page invoice or receipt. "
                                + "Nothing is filled in until you confirm it."))
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

    // MARK: - Work

    /// Runs recognition and ranks the lines into candidates.
    ///
    /// Re-entrant by design: the retry buttons call it again, and it resets its own state first.
    private func recognise() async {
        phase = .recognising

        let diagnostics = appEnvironment.scanDiagnostics
        diagnostics.begin(source: .photoOCR,
                          availability: BarcodeScannerAvailabilityChecker.current())
        diagnostics.note("Reading a photo that has already been taken. The camera is not used.")

        do {
            let lines = try await appEnvironment.textRecognizer.recognizeLines(in: imageData)
            diagnostics.recordLines(lines)

            let candidates = OCRSuggestionExtractor.candidates(from: lines, source: .photoOCR)
            diagnostics.recordCandidates(candidates)

            guard candidates.isEmpty == false else {
                phase = .noText
                return
            }
            phase = .ready(ScanReviewSession(source: .photoOCR,
                                             candidates: candidates,
                                             rawLines: lines.map { $0.text },
                                             previewImageData: imageData))
        } catch let error as RecognitionError {
            if error == .noTextFound {
                phase = .noText
                diagnostics.recordFailure(error.errorDescription ?? "No text was found.")
            } else {
                let message = error.errorDescription
                    ?? "Reading the photo didn't work. Type the details in instead."
                diagnostics.recordFailure(message)
                phase = .failed(message)
            }
        } catch {
            diagnostics.recordFailure(error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Document scanning

/// A multi-page invoice or receipt, read through the system document camera.
///
/// The scanner itself is the whole sheet while it is up — a document camera wants the screen — and
/// every other state is an ordinary explanation with a way forward. Cancelling the camera lands on
/// that explanation rather than on a blank sheet, which is the failure this screen is written to
/// avoid.
///
/// Like `ScanSheet`, it never dismisses itself on success: the host decides what happens next, so a
/// dismissal cannot race a presentation.
@MainActor
struct DocumentScanSheet: View {

    /// Called with the candidates the user confirmed.
    private let onApply: ([ScanCandidate]) -> Void

    init(onApply: @escaping ([ScanCandidate]) -> Void) {
        self.onApply = onApply
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .scanning

    private enum Phase: Equatable {
        /// The document camera is on screen.
        case scanning
        /// Pages captured, Vision reading them.
        case reading
        case ready(ScanReviewSession)
        /// The camera was closed without capturing anything.
        case cancelled
        case failed(String)
    }

    private static let contentMaxWidth: CGFloat = 640

    var body: some View {
        Group {
            if phase == .scanning {
                DocumentScannerView(
                    onScan: { (pages: [Data]) in
                        Task { await read(pages) }
                    },
                    onCancel: {
                        phase = .cancelled
                    },
                    onError: { (message: String) in
                        appEnvironment.scanDiagnostics.recordFailure(message)
                        phase = .failed(message)
                    }
                )
                .ignoresSafeArea()
            } else {
                resultScreen
            }
        }
        .tint(Palette.accent)
        .task {
            appEnvironment.scanDiagnostics.begin(
                source: .documentOCR,
                availability: BarcodeScannerAvailabilityChecker.current()
            )
        }
    }

    // MARK: - Everything that is not the camera

    private var resultScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    phaseContent
                }
                .padding(Spacing.l)
                .frame(maxWidth: DocumentScanSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Scan document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint(Text("Closes without changing anything."))
                }
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .scanning:
            // Unreachable: the camera owns the screen in this state. Rendered as the reading state
            // rather than as nothing, so a race can never show an empty sheet.
            readingCard

        case .reading:
            readingCard

        case .cancelled:
            SectionCard {
                EmptyStateView(
                    symbol: "doc.viewfinder",
                    title: "No pages scanned",
                    message: "The document camera was closed before anything was captured. Scan "
                        + "again, or close this and type the details in — the form works with no "
                        + "camera at all."
                )
            }
            scanAgainButton
            closeButton

        case .failed(let message):
            ErrorBanner(message: message,
                        retryTitle: "Try again",
                        onRetry: { phase = .scanning })
            closeButton

        case .ready(let session):
            ScanCandidateReview(
                session: session,
                onApply: { candidates in
                    onApply(candidates)
                },
                onRetake: { phase = .scanning },
                retakeTitle: "Scan the document again",
                onCancel: { dismiss() }
            )
        }
    }

    private var readingCard: some View {
        SectionCard {
            HStack(spacing: Spacing.m) {
                ProgressView()
                Text("Reading the pages…")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Reading the scanned pages"))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var scanAgainButton: some View {
        Button {
            phase = .scanning
        } label: {
            PrimaryButtonLabel("Scan again", systemImage: "doc.viewfinder")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Scan again"))
        .accessibilityHint(Text("Re-opens the document camera."))
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            ScanActionLabel(title: "Close and type it in", systemImage: "keyboard")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close and type it in"))
        .accessibilityHint(Text("Closes this sheet and returns to the form."))
    }

    // MARK: - Work

    /// Reads the captured pages and ranks them with the same extractor the photo path uses.
    private func read(_ pages: [Data]) async {
        let usable = pages.filter { $0.isEmpty == false }
        guard usable.isEmpty == false else {
            phase = .cancelled
            return
        }

        phase = .reading

        let diagnostics = appEnvironment.scanDiagnostics
        diagnostics.note(usable.count == 1
                         ? "1 page scanned."
                         : String(usable.count) + " pages scanned.")

        do {
            let lines = try await appEnvironment.textRecognizer.recognizePages(usable)
            diagnostics.recordLines(lines)

            let candidates = OCRSuggestionExtractor.candidates(from: lines, source: .documentOCR)
            diagnostics.recordCandidates(candidates)

            phase = .ready(ScanReviewSession(source: .documentOCR,
                                             candidates: candidates,
                                             rawLines: lines.map { $0.text },
                                             previewImageData: usable.first))
        } catch let error as RecognitionError {
            let message = error.errorDescription
                ?? "Reading those pages didn't work. Type the details in instead."
            diagnostics.recordFailure(message)
            phase = .failed(message)
        } catch {
            diagnostics.recordFailure(error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }
}
