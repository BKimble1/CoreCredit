//
//  ScanSheet.swift
//  CoreCredit
//
//  Capture feature — "Scan core": one entry point, two capture modes, one confirmation step.
//
//  ## One surface, two engines
//
//  Everything outside the app that says "scan a core" — the Quick Scan widget, the App Shortcut and
//  the Action Button through `ScanCoreIntent`, the Dashboard's Scan core button, and the intake
//  form's own — lands here, on a sheet titled **Scan core**. Inside it there are two modes:
//
//  - **Live** (this file) is `DataScannerViewController`: barcodes and, alongside them, text. It is
//    the default because it is what a technician holding a part actually wants.
//  - **Document** (`DocumentScanSheet`, in `OCRReviewSheet.swift`) is
//    `VNDocumentCameraViewController`: page-edge detection, perspective correction, several pages.
//    It is what an invoice or a return receipt actually needs.
//
//  The *entry point* is unified; the engines are not, and deliberately so. One finds a symbol in a
//  moving frame, the other flattens a sheet of paper — they have different framing behaviour,
//  different failure modes, and different guidance overlays, and pretending otherwise would make
//  both worse. Switching modes swaps `CoreEditorModel.Route`, so exactly one capture sheet is ever
//  presented and a dismissal can never race a presentation.
//
//  ## A scan stops, it does not commit
//
//  Nothing leaves this sheet until the user taps *Use these details*, and even then it only travels
//  as far as the review sheet, which is where a value is confirmed before it reaches the intake
//  draft. Cancelling leaves the draft untouched. Switching modes writes nothing at all.
//
//  ## Every branch reaches a usable outcome
//
//  `BarcodeScannerAvailabilityChecker.current()` has six answers and this sheet has six screens, but
//  they all end the same way: a number goes back to the editor. Manual entry is present in *every*
//  state, including the one where the camera is working — a code that will not read under bad light
//  is the normal case on a shop floor, not an edge case.
//
//  The simulator branch is a first-class path, not a dead end: it is how the whole capture flow is
//  demoed and UI-tested, so it pre-fills from `-uiTestScannerPayload` and offers a sample code.
//

import SwiftUI

// MARK: - Modes

/// Which capture engine the unified "Scan core" surface currently has in front of the user.
///
/// A value type shared by both sheets so the segmented control reads identically on each, and so a
/// test can assert the vocabulary without launching a camera.
enum ScanCaptureMode: String, CaseIterable, Identifiable, Hashable, Sendable {

    /// `DataScannerViewController` — barcodes and tappable text.
    case live

    /// `VNDocumentCameraViewController` — a flattened, deskewed page.
    case document

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live:
            return "Live"
        case .document:
            return "Document"
        }
    }

    var symbolName: String {
        switch self {
        case .live:
            return "barcode.viewfinder"
        case .document:
            return "doc.viewfinder"
        }
    }

    /// One sentence saying what this mode is for, shown under the selector.
    var explanation: String {
        switch self {
        case .live:
            return "Point the camera at a barcode on the part, the box, or the shelf label. "
                + "Printed text is highlighted too — tap the line you want."
        case .document:
            return "For an invoice or a return receipt. The page is flattened and straightened "
                + "first, which is what makes small print readable."
        }
    }
}

/// The one user-facing name for the whole capture surface, in both modes.
enum ScanCaptureCopy {
    static let title = "Scan core"
}

// MARK: - Mode selector

/// The Live / Document control at the top of both capture sheets.
///
/// Selecting the mode that is already showing does nothing. Selecting the other one asks the host
/// to swap routes, which closes this sheet and opens the other — one sheet at a time, always.
@MainActor
struct ScanModeSelector: View {

    private let mode: ScanCaptureMode
    private let onSelect: (ScanCaptureMode) -> Void

    init(mode: ScanCaptureMode, onSelect: @escaping (ScanCaptureMode) -> Void) {
        self.mode = mode
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // No `.accessibilityLabel` / `.accessibilityValue` on the picker itself. A segmented
            // control already announces each segment and its selected state, and collapsing it into
            // one labelled element would take that away from VoiceOver — and take the individual
            // segments away from the UI tests at the same time. The identifier is applied to the
            // container, where it does not disturb the children.
            Picker("Capture mode", selection: selection) {
                ForEach(ScanCaptureMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityIdentifier(A11y.Scan.modePicker)

            Text(mode.explanation)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selection: Binding<ScanCaptureMode> {
        Binding(
            get: { mode },
            set: { newValue in
                guard newValue != mode else { return }
                onSelect(newValue)
            }
        )
    }
}

// MARK: - Live capture

/// Live capture with a manual fallback that is always available.
@MainActor
struct ScanSheet: View {

    /// Called with everything the capture produced, for the review step to confirm.
    ///
    /// The sheet deliberately does **not** dismiss itself here: the caller swaps its own route to
    /// the review sheet, and a `dismiss()` racing that swap would close both.
    private let onCandidates: (ScanReviewSession) -> Void

    /// Called when the user picks Document. The host swaps the route; this sheet does nothing else.
    /// `nil` hides the mode selector, for a host with only one engine to offer.
    private let onSwitchToDocument: (() -> Void)?

    init(onCandidates: @escaping (ScanReviewSession) -> Void,
         onSwitchToDocument: (() -> Void)? = nil) {
        self.onCandidates = onCandidates
        self.onSwitchToDocument = onSwitchToDocument
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var availability: ScannerAvailability = .cameraNotDetermined
    @State private var manualEntry: String = ""
    @State private var scannerError: String?
    @State private var isRequestingAccess = false
    @State private var isShowingPhotoAssist = false
    @State private var paywallTrigger: PaywallTrigger?

    /// The accepted read currently held on screen. Non-`nil` means the viewfinder is paused.
    @State private var frozen: FrozenScan?

    // There is deliberately no deduplicator here. Duplicate suppression and the cooldown live in
    // exactly one place — `BarcodeScannerView.Coordinator` — which is also the only object that
    // resets them when the scanner is torn down. A second copy on this sheet would survive that
    // reset, so a code scanned before an availability flip could never be scanned again, and the
    // suppressed reads would never reach diagnostics because this sheet would swallow them first.

    @FocusState private var isManualEntryFocused: Bool

    /// The code offered by "Use sample barcode" when no launch argument supplied one. Shaped like a
    /// parts-catalogue number so the rest of the flow behaves as it would on a real part.
    private static let sampleBarcode = "03-1887"

    /// Height of the live viewfinder. Big enough to aim with, small enough to leave the manual
    /// field on screen at the same time.
    private static let viewfinderHeight: CGFloat = 260

    private static let contentMaxWidth: CGFloat = 560

    /// Confidence stamped on a line the user tapped out of the live text highlights.
    ///
    /// Deliberately mid-band. A tapped line arrives with none of the context the ranking layer
    /// normally has — no label above it, no page position, no neighbours — so it must not be able
    /// to reach `.high` and start pre-selected on its own. The technician chose the line; they
    /// still confirm what it *is*.
    private static let liveTextConfidence = 0.5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let onSwitchToDocument = onSwitchToDocument {
                        ScanModeSelector(mode: .live) { newMode in
                            guard newMode == .document else { return }
                            isManualEntryFocused = false
                            onSwitchToDocument()
                        }
                    }

                    if let scannerError = scannerError {
                        ErrorBanner(message: scannerError,
                                    retryTitle: "Try the camera again",
                                    onRetry: { retryScanning() },
                                    onDismiss: { self.scannerError = nil })
                    }

                    stateSection

                    if let frozen = frozen {
                        frozenCard(frozen)
                    }

                    manualEntrySection

                    photoAssistSection
                }
                .padding(Spacing.l)
                .frame(maxWidth: ScanSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
            .background {
                Palette.background.ignoresSafeArea()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(ScanCaptureCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11y.Scan.root)
            .sheet(isPresented: $isShowingPhotoAssist) {
                PhotoAssistSheet { review in
                    isShowingPhotoAssist = false
                    onCandidates(review)
                }
            }
            .sheet(item: $paywallTrigger) { trigger in
                PaywallView(trigger: trigger)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11y.Scan.cancel)
                        .accessibilityHint(Text("Closes the scanner without entering a number."))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isManualEntryFocused = false }
                }
            }
        }
        .tint(Palette.accent)
        // No haptic here on purpose. `BarcodeScannerView` fires exactly one `.success`
        // when a read clears duplicate suppression and the cooldown, which is the only
        // place that knows a read was actually *accepted*. Adding a second trigger on
        // the frozen state would buzz twice for one read.
        .task {
            availability = BarcodeScannerAvailabilityChecker.current()
            appEnvironment.scanDiagnostics.begin(source: .liveBarcode, availability: availability)
            if availability.allowsScanning == false {
                appEnvironment.scanDiagnostics.note(availability.explanation)
            }
            if manualEntry.isEmpty, let stub = appEnvironment.launchOptions.stubScannerPayload {
                manualEntry = stub
            }
        }
    }

    // MARK: - Per-state section

    @ViewBuilder
    private var stateSection: some View {
        switch availability {
        case .available:
            viewfinderSection
        case .simulator:
            explanationSection(
                symbol: "desktopcomputer",
                title: "Simulator — no camera",
                message: ScannerAvailability.simulator.explanation
            ) {
                sampleBarcodeButton
            }
        case .cameraNotDetermined:
            explanationSection(
                symbol: "camera",
                title: "Camera access",
                message: ScannerAvailability.cameraNotDetermined.explanation
            ) {
                Button {
                    Task { await requestAccess() }
                } label: {
                    PrimaryButtonLabel("Allow camera access", systemImage: "camera")
                }
                .buttonStyle(.plain)
                .disabled(isRequestingAccess)
                .accessibilityHint(Text("Asks iOS for permission to use the camera."))
            }
        case .cameraDenied:
            explanationSection(
                symbol: "camera",
                title: "Camera is turned off",
                message: ScannerAvailability.cameraDenied.explanation
            ) {
                settingsButton
            }
        case .cameraRestricted:
            explanationSection(
                symbol: "lock",
                title: "Camera is restricted",
                message: ScannerAvailability.cameraRestricted.explanation
            ) {
                settingsButton
            }
        case .unsupportedDevice:
            explanationSection(
                symbol: "iphone.slash",
                title: "This device can't scan",
                message: ScannerAvailability.unsupportedDevice.explanation
            ) {
                EmptyView()
            }
        }
    }

    // MARK: - Live scanning

    private var viewfinderSection: some View {
        SectionCard(title: frozen == nil ? "Point at the barcode" : "Paused on a read",
                    systemImage: "barcode.viewfinder") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                BarcodeScannerView(
                    isPaused: frozen != nil,
                    recognizesText: true,
                    dateProvider: appEnvironment.dateProvider,
                    onScan: { result in
                        accept(result)
                    },
                    onSuppressed: { result, reason in
                        recordSuppressedScan(result, reason: reason)
                    },
                    onTextScan: { transcript in
                        acceptText(transcript)
                    },
                    onError: { message in
                        scannerError = message
                        appEnvironment.scanDiagnostics.recordFailure(message)
                    }
                )
                .frame(height: ScanSheet.viewfinderHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Camera viewfinder"))
                .accessibilityValue(Text(frozen == nil ? "Scanning" : "Paused on a scanned value"))
                .accessibilityHint(Text("Hold the barcode in front of the camera, or tap a line of "
                                        + "printed text to use it. You can also type the number in "
                                        + "below."))

                Text(frozen == nil
                     ? "A barcode is used as soon as it reads. Printed text is only highlighted — "
                        + "tap the line you want."
                     : "Scanning is paused so the value below stays put. Resume when you are done "
                        + "with it.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The frozen read

    /// What was read, held still, with the three things the user can do about it.
    private func frozenCard(_ scan: FrozenScan) -> some View {
        SectionCard(title: scan.isText ? "Tapped text" : "Scanned code",
                    systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(scan.payload)
                    .font(Typography.money)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(scan.isText ? "Tapped text" : "Scanned code"))
                    .accessibilityValue(Text(scan.payload))

                Text(scan.sourceDescription)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if scan.session.candidates.isEmpty {
                    Text(scan.isText
                         ? "Nothing could be made of that line. Tap a different one, or type the "
                            + "number in below."
                         : "Nothing could be made of that code. Resume scanning, or type the number "
                            + "in below.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(scan.session.candidates) { candidate in
                            LabeledValueRow(candidate.kind.displayName,
                                            value: candidate.normalizedValue,
                                            symbol: candidate.kind.symbolName,
                                            isMonospaced: true)
                        }
                    }

                    Text("Nothing is filled in until you check these on the next screen.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    useFrozenScan(scan)
                } label: {
                    PrimaryButtonLabel("Use these details", systemImage: "arrow.right")
                }
                .buttonStyle(.plain)
                .disabled(scan.session.candidates.isEmpty)
                .accessibilityLabel(Text("Use these details"))
                .accessibilityHint(Text("Opens the check screen, where you confirm each value "
                                        + "before anything is filled in."))

                Button {
                    resumeScanning()
                } label: {
                    ScanActionLabel(title: "Resume scanning", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.Scan.resume)
                .accessibilityLabel(Text("Resume scanning"))
                .accessibilityHint(Text("Throws this reading away and starts the camera again."))

                Button {
                    dismiss()
                } label: {
                    Text("Cancel and close")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel and close the scanner"))
                .accessibilityHint(Text("Closes without changing anything on the form."))
            }
        }
    }

    // MARK: - Explanations

    /// A titled explanation with an optional recovery action beneath it.
    private func explanationSection<Action: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        SectionCard(title: title, systemImage: symbol) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                action()
            }
        }
    }

    /// Deep link into Settings, shown only when the system gives us a usable URL.
    @ViewBuilder
    private var settingsButton: some View {
        if let url = BarcodeScannerAvailabilityChecker.openSettingsURL {
            Link(destination: url) {
                PrimaryButtonLabel("Open Settings", systemImage: "gearshape")
            }
            .accessibilityLabel(Text("Open Settings"))
            .accessibilityHint(Text("Opens this app's page in Settings, where camera access lives."))
        }
    }

    /// Fills the manual field with a known-good code so the flow can be exercised without hardware.
    private var sampleBarcodeButton: some View {
        Button {
            manualEntry = appEnvironment.launchOptions.stubScannerPayload ?? ScanSheet.sampleBarcode
            isManualEntryFocused = true
        } label: {
            PrimaryButtonLabel("Use sample barcode", systemImage: "wand.and.stars")
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Puts a test code into the field below so you can carry on."))
    }

    // MARK: - Manual entry

    /// Always present, in every state. This is the path that never fails.
    /// The one secondary action on this surface: read a set of photographs instead of aiming at a
    /// symbol.
    ///
    /// Deliberately compact, and deliberately below manual entry. The primary way to enter a core
    /// is still to point the camera at a barcode or type the number in, and both of those stay free
    /// for everybody. This is an assistant for the awkward cases — a rubbed-out label, a core
    /// charge buried in an invoice — and it is part of Pro.
    ///
    /// A free shop sees the row, with a lock and a plain sentence about what it does. Hiding a
    /// paid feature entirely means somebody never learns it exists; showing it as a dead control
    /// with no explanation is worse. Tapping opens the paywall, which says the same thing again.
    private var photoAssistSection: some View {
        SectionCard {
            Button {
                if let trigger = EntitlementPolicy.photoAssistTrigger(
                    tier: appEnvironment.subscriptions.entitlement.tier
                ) {
                    paywallTrigger = trigger
                } else {
                    isManualEntryFocused = false
                    isShowingPhotoAssist = true
                }
            } label: {
                photoAssistLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.PhotoAssist.open)
            .accessibilityHint(Text(isPhotoAssistUnlocked
                                    ? "Opens the photo assistant. Nothing is saved until you review it."
                                    : "Part of Pro. Opens the upgrade options."))
        }
    }

    private var isPhotoAssistUnlocked: Bool {
        EntitlementPolicy.canUsePhotoAssist(tier: appEnvironment.subscriptions.entitlement.tier)
    }

    private var photoAssistLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: "sparkles")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Text("AI Photo Assist")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    BetaBadge()
                    if isPhotoAssistUnlocked == false {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityIdentifier(A11y.PhotoAssist.locked)
                    }
                }
                Text(isPhotoAssistUnlocked
                     ? "Read a part, a label, and an invoice from photos on this device."
                     : "Part of Pro. Reads photos on this device; scanning and typing stay free.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: Spacing.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isPhotoAssistUnlocked
                                 ? "AI Photo Assist, beta"
                                 : "AI Photo Assist, beta, locked. Part of Pro."))
    }

    private var manualEntrySection: some View {
        SectionCard(title: manualEntryTitle, systemImage: "keyboard") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Type the number printed on the part, the box, or the invoice.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("03-1887", text: $manualEntry)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isManualEntryFocused)
                    .onSubmit { useManualEntry() }
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .background(
                        RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                            .fill(Palette.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                            .strokeBorder(isManualEntryFocused ? Palette.accent : Palette.fieldBorder,
                                          lineWidth: isManualEntryFocused ? 2 : 1)
                    )
                    .accessibilityIdentifier(A11y.Scan.manualEntry)
                    .accessibilityLabel(Text("Barcode number"))
                    .accessibilityHint(Text("Type the number, then use it."))

                Button {
                    useManualEntry()
                } label: {
                    PrimaryButtonLabel("Use this number", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                .disabled(trimmedManualEntry.isEmpty)
                .accessibilityIdentifier(A11y.Scan.useManual)
                .accessibilityLabel(Text("Use this number"))
                .accessibilityHint(Text("Opens the check screen with the number you typed."))
            }
        }
    }

    /// The manual section leads on the states with no camera, and supports the ones that have one.
    private var manualEntryTitle: String {
        availability == .available ? "Or type it in" : "Type it in"
    }

    // MARK: - Actions

    private var trimmedManualEntry: String {
        manualEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Freezes on a read the scanner has already accepted.
    ///
    /// Only accepted scans arrive here: the deduplicator and the cooldown are enforced inside
    /// `BarcodeScannerView`, which fires the single success haptic at the same moment. Refused
    /// reads arrive at `recordSuppressedScan(_:reason:)` instead, so both outcomes are visible in
    /// diagnostics and only one of them buzzes.
    private func accept(_ result: ScanResult) {
        let payload = result.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.isEmpty == false else { return }

        appEnvironment.scanDiagnostics.recordBarcode(
            payload: payload,
            symbology: result.symbology,
            accepted: true,
            reason: "First read of this code in this session."
        )

        let input = BarcodeScanInput(payload: payload,
                                     symbology: result.symbology,
                                     source: .liveBarcode)
        let candidates = BarcodePayloadClassifier.candidates(for: input)
        appEnvironment.scanDiagnostics.recordCandidates(candidates)

        scannerError = nil
        isManualEntryFocused = false
        frozen = FrozenScan(
            payload: payload,
            symbology: result.symbology,
            isText: false,
            session: ScanReviewSession(source: .liveBarcode,
                                       candidates: candidates,
                                       rawLines: [payload])
        )
    }

    /// Freezes on a line of printed text the user tapped in the viewfinder.
    ///
    /// Ranked by `OCRSuggestionExtractor`, exactly as a photographed or scanned page is, so a live
    /// tap and a document scan produce the same kind of candidate with the same reasoning attached.
    /// The raw line is preserved as `rawValue` by the extractor and shown again on the review sheet.
    private func acceptText(_ transcript: String) {
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return }

        appEnvironment.scanDiagnostics.recordBarcode(
            payload: value,
            symbology: BarcodeScannerView.liveTextSymbology,
            accepted: true,
            reason: "Line of printed text tapped in the viewfinder."
        )

        let line = RecognizedLine(text: value, confidence: ScanSheet.liveTextConfidence)
        appEnvironment.scanDiagnostics.recordLines([line])

        let candidates = OCRSuggestionExtractor.candidates(from: [line], source: .liveText)
        appEnvironment.scanDiagnostics.recordCandidates(candidates)

        scannerError = nil
        isManualEntryFocused = false
        frozen = FrozenScan(
            payload: value,
            symbology: BarcodeScannerView.liveTextSymbology,
            isText: true,
            session: ScanReviewSession(source: .liveText,
                                       candidates: candidates,
                                       rawLines: [value])
        )
    }

    /// Records a read the scanner refused, so the diagnostics screen can answer "why did my second
    /// scan do nothing?".
    ///
    /// Nothing else happens: no haptic, no freeze, no candidates. The user sees an unchanged
    /// screen, which is the point — the refusal exists so a code held in frame does not fire a
    /// dozen times.
    private func recordSuppressedScan(_ result: ScanResult, reason: String) {
        let payload = result.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.isEmpty == false else { return }

        appEnvironment.scanDiagnostics.recordBarcode(
            payload: payload,
            symbology: result.symbology,
            accepted: false,
            reason: ScanSheet.suppressionExplanation(for: reason)
        )
    }

    /// Turns the scanner's short reason into the sentence the diagnostics screen shows.
    private static func suppressionExplanation(for reason: String) -> String {
        if reason == BarcodeScannerView.duplicateSuppressionReason {
            return "Already read in this session. Close the scanner and open it again to read the "
                + "same value twice."
        }
        if reason == BarcodeScannerView.cooldownSuppressionReason {
            return "Read inside the repeat-scan cooldown, so it counted as the same read as the "
                + "one before it."
        }
        return "Dropped by the scanner: " + reason + "."
    }

    /// Hands the frozen read to the caller. The caller presents the review sheet; this sheet stays
    /// put rather than dismissing itself, so the two presentations cannot race.
    private func useFrozenScan(_ scan: FrozenScan) {
        guard scan.session.candidates.isEmpty == false else { return }
        isManualEntryFocused = false
        onCandidates(scan.session)
    }

    /// Drops the frozen read and starts the camera again.
    private func resumeScanning() {
        frozen = nil
        scannerError = nil
    }

    /// Turns a typed number into the same shape a scan produces, so both paths are confirmed the
    /// same way. It is preselected because the user typed it themselves — that is confirmation of
    /// the value, not a guess about it.
    private func useManualEntry() {
        let value = trimmedManualEntry
        guard value.isEmpty == false else { return }

        isManualEntryFocused = false

        let candidate = ScanCandidate(
            kind: .partNumber,
            rawValue: value,
            normalizedValue: ScanTextNormalizer.normalizedIdentifier(value),
            confidence: 1,
            source: .liveBarcode,
            reason: "Typed in by hand on the scan screen."
        )
        appEnvironment.scanDiagnostics.note("Number typed in by hand instead of scanned.")
        appEnvironment.scanDiagnostics.recordCandidates([candidate])

        onCandidates(ScanReviewSession(source: .liveBarcode,
                                       candidates: [candidate],
                                       rawLines: [value]))
    }

    /// Asks iOS for camera access, then re-reads availability so the sheet re-renders into whatever
    /// state the answer produced — including "still denied", which keeps manual entry in place.
    private func requestAccess() async {
        guard isRequestingAccess == false else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        scannerError = nil
        availability = await BarcodeScannerAvailabilityChecker.requestCameraAccess()
        appEnvironment.scanDiagnostics.begin(source: .liveBarcode, availability: availability)
        if availability.allowsScanning == false {
            appEnvironment.scanDiagnostics.note(availability.explanation)
        }
    }

    /// Re-probes after a capture interruption — a phone call, another app taking the camera, an
    /// MDM profile landing — so the viewfinder can come back without closing the sheet.
    private func retryScanning() {
        scannerError = nil
        frozen = nil
        availability = BarcodeScannerAvailabilityChecker.current()
        appEnvironment.scanDiagnostics.begin(source: .liveBarcode, availability: availability)
    }

    // MARK: - Frozen read

    /// One accepted read, held on screen while the user decides what to do with it.
    private struct FrozenScan: Equatable {

        var payload: String

        /// `VNBarcodeSymbology.rawValue` for a code, `BarcodeScannerView.liveTextSymbology` for a
        /// tapped line. Kept verbatim either way.
        var symbology: String

        /// Whether this came from the text highlights rather than from a symbol.
        var isText: Bool

        /// What the classifier or the extractor made of the value, ready for the review sheet.
        var session: ScanReviewSession

        /// A sentence naming where the value came from, so a numeric UPC is visibly not a part
        /// number and a tapped line is visibly not a scanned code.
        var sourceDescription: String {
            if isText {
                return "Read as printed text, not from a barcode."
            }
            let family = BarcodeSymbologyClass.classify(symbology).displayName
            return "Symbol type: " + family + "."
        }
    }
}
