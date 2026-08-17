//
//  ScanSheet.swift
//  CoreCredit
//
//  Capture feature — barcode entry, by camera or by hand.
//
//  ## A scan stops, it does not commit
//
//  The old version of this screen handed a payload straight back and dismissed itself. It now
//  **freezes** instead: the viewfinder pauses, one success haptic fires, and the code that was read
//  is shown with what the classifier made of it. Nothing leaves this sheet until the user taps
//  *Use these details*, and even then it only travels as far as the review sheet, which is where a
//  value is confirmed before it reaches the intake draft. Cancelling leaves the draft untouched.
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

/// Barcode capture with a manual fallback that is always available.
@MainActor
struct ScanSheet: View {

    /// Called with everything the capture produced, for the review step to confirm.
    ///
    /// The sheet deliberately does **not** dismiss itself here: the caller swaps its own route to
    /// the review sheet, and a `dismiss()` racing that swap would close both.
    private let onCandidates: (ScanReviewSession) -> Void

    init(onCandidates: @escaping (ScanReviewSession) -> Void) {
        self.onCandidates = onCandidates
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var availability: ScannerAvailability = .cameraNotDetermined
    @State private var manualEntry: String = ""
    @State private var scannerError: String?
    @State private var isRequestingAccess = false

    /// The accepted scan currently held on screen. Non-`nil` means the viewfinder is paused.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
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
                }
                .padding(Spacing.l)
                .frame(maxWidth: ScanSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11y.Scan.root)
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
        // when a scan clears duplicate suppression and the cooldown, which is the only
        // place that knows a scan was actually *accepted*. Adding a second trigger on
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
        SectionCard(title: frozen == nil ? "Point at the barcode" : "Paused on a code",
                    systemImage: "barcode.viewfinder") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                BarcodeScannerView(
                    isPaused: frozen != nil,
                    dateProvider: appEnvironment.dateProvider,
                    onScan: { result in
                        accept(result)
                    },
                    onSuppressed: { result, reason in
                        recordSuppressedScan(result, reason: reason)
                    },
                    onError: { message in
                        scannerError = message
                        appEnvironment.scanDiagnostics.recordFailure(message)
                    }
                )
                .frame(height: ScanSheet.viewfinderHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Camera viewfinder"))
                .accessibilityValue(Text(frozen == nil ? "Scanning" : "Paused on a scanned code"))
                .accessibilityHint(Text("Hold the barcode in front of the camera. "
                                        + "You can also type the number in below."))

                Text(frozen == nil
                     ? ScannerAvailability.available.explanation
                     : "Scanning is paused so the code below stays put. Resume when you are done "
                        + "with it.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The frozen scan

    /// What was read, held still, with the three things the user can do about it.
    private func frozenCard(_ scan: FrozenScan) -> some View {
        SectionCard(title: "Scanned code", systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(scan.payload)
                    .font(Typography.money)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Scanned code"))
                    .accessibilityValue(Text(scan.payload))

                Text(scan.symbologyDescription)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if scan.session.candidates.isEmpty {
                    Text("Nothing could be made of that code. Resume scanning, or type the number "
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
                .accessibilityHint(Text("Throws this code away and starts the camera again."))

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
                            .strokeBorder(isManualEntryFocused ? Palette.accent : Palette.hairline,
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
            session: ScanReviewSession(source: .liveBarcode,
                                       candidates: candidates,
                                       rawLines: [payload])
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
                + "same code twice."
        }
        if reason == BarcodeScannerView.cooldownSuppressionReason {
            return "Read inside the repeat-scan cooldown, so it counted as the same read as the "
                + "one before it."
        }
        return "Dropped by the scanner: " + reason + "."
    }

    /// Hands the frozen scan to the caller. The caller presents the review sheet; this sheet stays
    /// put rather than dismissing itself, so the two presentations cannot race.
    private func useFrozenScan(_ scan: FrozenScan) {
        guard scan.session.candidates.isEmpty == false else { return }
        isManualEntryFocused = false
        onCandidates(scan.session)
    }

    /// Drops the frozen code and starts the camera again.
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

    // MARK: - Frozen scan

    /// One accepted read, held on screen while the user decides what to do with it.
    private struct FrozenScan: Equatable {

        var payload: String

        /// `VNBarcodeSymbology.rawValue`, kept verbatim.
        var symbology: String

        /// What the classifier made of the payload, ready for the review sheet.
        var session: ScanReviewSession

        /// A sentence naming the kind of symbol, so a numeric UPC is visibly not a part number.
        var symbologyDescription: String {
            let family = BarcodeSymbologyClass.classify(symbology).displayName
            return "Symbol type: " + family + "."
        }
    }
}
