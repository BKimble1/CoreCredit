//
//  ScanSheet.swift
//  CoreCredit
//
//  Capture feature — barcode entry, by camera or by hand.
//
//  ## Every branch reaches a usable outcome
//
//  `BarcodeScannerAvailabilityChecker.current()` has six answers and this sheet has six screens,
//  but they all end the same way: a number goes back to the editor. Manual entry is present in
//  *every* state, including the one where the camera is working — a code that will not read under
//  bad light is the normal case on a shop floor, not an edge case.
//
//  The simulator branch is a first-class path, not a dead end: it is how the whole capture flow is
//  demoed and UI-tested, so it pre-fills from `-uiTestScannerPayload` and offers a sample code.
//

import SwiftUI

/// Barcode capture with a manual fallback that is always available.
@MainActor
struct ScanSheet: View {

    /// Called with the code the user captured or typed. The sheet dismisses itself afterwards.
    private let onScan: (String) -> Void

    init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var availability: ScannerAvailability = .cameraNotDetermined
    @State private var manualEntry: String = ""
    @State private var scannerError: String?
    @State private var isRequestingAccess = false
    @FocusState private var isManualEntryFocused: Bool

    /// The code offered by "Use sample barcode" when no launch argument supplied one. Shaped like a
    /// parts-catalogue number so the rest of the flow behaves as it would on a real part.
    private static let sampleBarcode = "03-1887"

    /// Height of the live viewfinder. Big enough to aim with, small enough to leave the manual
    /// field on screen at the same time.
    private static let viewfinderHeight: CGFloat = 260

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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint(Text("Closes the scanner without entering a number."))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isManualEntryFocused = false }
                }
            }
        }
        .tint(Palette.accent)
        .task {
            availability = BarcodeScannerAvailabilityChecker.current()
            if manualEntry.isEmpty, let stub = appEnvironment.launchOptions.stubScannerPayload {
                manualEntry = stub
            }
        }
    }

    private static let contentMaxWidth: CGFloat = 560

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
        SectionCard(title: "Point at the barcode", systemImage: "barcode.viewfinder") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                BarcodeScannerView(
                    onScan: { result in
                        deliver(result.payload)
                    },
                    onError: { message in
                        scannerError = message
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
                .accessibilityHint(Text("Hold the barcode in front of the camera. "
                                        + "You can also type the number in below."))

                Text(ScannerAvailability.available.explanation)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityLabel(Text("Barcode number"))
                    .accessibilityHint(Text("Type the number, then use it."))

                Button {
                    useManualEntry()
                } label: {
                    PrimaryButtonLabel("Use this number", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                .disabled(trimmedManualEntry.isEmpty)
                .accessibilityLabel(Text("Use this number"))
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

    private func useManualEntry() {
        let value = trimmedManualEntry
        guard !value.isEmpty else { return }
        deliver(value)
    }

    /// Hands a code back to the editor and closes.
    private func deliver(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onScan(trimmed)
        dismiss()
    }

    /// Asks iOS for camera access, then re-reads availability so the sheet re-renders into whatever
    /// state the answer produced — including "still denied", which keeps manual entry in place.
    private func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        scannerError = nil
        availability = await BarcodeScannerAvailabilityChecker.requestCameraAccess()
    }

    /// Re-probes after a capture interruption — a phone call, another app taking the camera, an
    /// MDM profile landing — so the viewfinder can come back without closing the sheet.
    private func retryScanning() {
        scannerError = nil
        availability = BarcodeScannerAvailabilityChecker.current()
    }
}
