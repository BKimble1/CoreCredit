//
//  BarcodeScannerView.swift
//  CoreCredit
//
//  Capture layer — the live barcode scanner, wrapped so SwiftUI can present it.
//
//  This view is only ever shown when `BarcodeScannerAvailabilityChecker.current()` says scanning
//  is possible. It still re-checks before starting a session, because availability can change
//  between the check and the presentation (a phone call, another app grabbing the camera, an MDM
//  profile applying). Everything that can go wrong is reported through `onError` as a sentence the
//  UI can show next to a manual-entry field — the scanner never becomes a dead black rectangle.
//
//  ## The three shop-floor failures this file is built around
//
//  1. **The wrong symbologies.** `.barcode()` with no argument asks VisionKit for everything it can
//     read, which sounds generous and behaves badly: the decoder spreads its budget across dozens
//     of symbologies, and a marginal Code 128 on a greasy bin label loses to that. The list is
//     therefore explicit and short — the twelve symbologies that actually appear on parts boxes,
//     parts bins, and vendor paperwork.
//  2. **Invisible control characters.** A GS1-128 label carries FNC1, which arrives as GS (U+001D),
//     and keyboard-wedge-style decoders like to append EOT (U+0004). They are invisible, so the
//     symptom is a part number that "looks right" and matches nothing. Every payload is passed
//     through `ScanTextNormalizer.stripControlCharacters` before anything else looks at it.
//  3. **The machine-gun callback.** A symbol held in frame fires the delegate many times a second.
//     Without suppression that is a dozen haptics, a dozen review sheets, and a UI re-rendering
//     under the user's thumb. `ScanSessionDeduplicator` gates every delivery.
//
//  ## Text is recognised, and only ever *tapped*
//
//  Live mode also asks `DataScannerViewController` for text, because a core charge is as often
//  printed on an invoice as encoded in a symbol. The two are not treated the same way. A barcode is
//  unambiguous once it decodes, so it is accepted the moment it is read; a line of text is one of
//  dozens on the page, so it is *highlighted* and does nothing until the technician taps the one
//  they mean. Text therefore arrives only through `didTapOn`, never through `didAdd`, and it still
//  passes the same deduplicator and the same cooldown as a barcode.
//

import SwiftUI
import UIKit
import Vision
import VisionKit

/// Live barcode/QR scanning over `DataScannerViewController`.
///
/// Scanning is a shortcut for typing, never a requirement: callers must keep manual entry
/// available, because this view cannot be presented at all in the simulator or on a device
/// without camera access.
@MainActor
struct BarcodeScannerView: UIViewControllerRepresentable {

    /// The symbologies this app asks the scanner to read, and nothing else.
    ///
    /// - `code128`, `code39`, `code39Checksum`, `code39FullASCII` — what a parts bin label, a core
    ///   tag, and a vendor's own part-number barcode are printed in.
    /// - `qr`, `dataMatrix`, `pdf417`, `aztec` — 2-D codes on modern boxes and paperwork.
    /// - `upce`, `ean8`, `ean13`, `itf14` — retail/product codes. Read so the payload can be stored
    ///   verbatim, never so it can be offered as a part number (`BarcodePayloadClassifier` refuses).
    ///
    /// **There is no UPC-A case in `VNBarcodeSymbology`.** Vision reports a UPC-A symbol as
    /// `.ean13` — a UPC-A is an EAN-13 with a leading zero — so listing `.ean13` is what makes the
    /// UPC on an American parts box readable. Nothing is missing here.
    static let symbologies: [VNBarcodeSymbology] = [
        .code128,
        .code39,
        .code39Checksum,
        .code39FullASCII,
        .qr,
        .dataMatrix,
        .upce,
        .ean8,
        .ean13,
        .itf14,
        .pdf417,
        .aztec
    ]

    /// The symbology recorded for a value the user tapped out of the live *text* highlights.
    ///
    /// Not a `VNBarcodeSymbology` — there is no symbol involved. It exists so the deduplicator, the
    /// suppression callback, and the diagnostics screen can all say where a value came from without
    /// pretending a line of print was a barcode.
    static let liveTextSymbology = "liveText"

    /// When `true` the capture session is stopped and no callback can fire.
    ///
    /// This is how the review step freezes the preview: the sheet flips this to `true` the moment a
    /// scan is accepted, so the camera is not still hunting for codes behind a sheet the user is
    /// reading.
    private let isPaused: Bool

    /// Whether the session also recognises text alongside barcodes.
    ///
    /// Off by default so a caller that only wants codes pays nothing for a text pass it will never
    /// read. The app's unified capture surface turns it on for Live mode.
    private let recognizesText: Bool

    /// The clock the cooldown is measured against. Injected so a session is reproducible and so
    /// nothing in the capture path reads the wall clock directly.
    private let dateProvider: any DateProvider

    /// Called on the main actor for each **accepted** scan — once per payload per session, at most
    /// one inside the cooldown window.
    private let onScan: (ScanResult) -> Void

    /// Called on the main actor for each scan the deduplicator **dropped**, with the reason.
    ///
    /// This exists so a suppressed read is still visible to the diagnostics screen. The scanner is
    /// the only place that knows a scan was refused — it owns the one deduplicator — so without
    /// this callback "why did my second scan do nothing?" has no answer anywhere in the app. No
    /// haptic fires for these, and nothing downstream treats them as a read.
    ///
    /// Defaulted to a no-op so a caller that does not record diagnostics is unaffected.
    private let onSuppressed: (ScanResult, String) -> Void

    /// Called on the main actor when the user **taps** a recognised text highlight.
    ///
    /// Never fires for text that merely came into frame: highlighting is not choosing. The string
    /// has been through `ScanTextNormalizer.stripControlCharacters` and nothing else, so it is the
    /// line as printed.
    private let onTextScan: (String) -> Void

    /// Called on the main actor with a user-facing sentence when scanning cannot start or stops.
    private let onError: (String) -> Void

    /// Reason handed to `onSuppressed` when the payload was already accepted in this session.
    static let duplicateSuppressionReason = "duplicate"

    /// Reason handed to `onSuppressed` when the scan landed inside the repeat-scan cooldown.
    static let cooldownSuppressionReason = "cooldown"

    /// - Parameters:
    ///   - isPaused: `false` starts (or resumes) the session, `true` stops it. Defaults to `false`
    ///     so a caller that has no review step to freeze does not have to say so.
    ///   - dateProvider: the cooldown clock. Callers inside the app pass
    ///     `AppEnvironment.dateProvider`; the default keeps previews and one-off uses working.
    ///   - recognizesText: also recognise text, for tapping. Barcodes are unaffected either way.
    ///   - onSuppressed: receives the scans the deduplicator refused, with
    ///     `duplicateSuppressionReason` or `cooldownSuppressionReason`. Defaults to doing nothing.
    ///   - onTextScan: receives a tapped text highlight. Defaults to doing nothing.
    init(isPaused: Bool = false,
         recognizesText: Bool = false,
         dateProvider: any DateProvider = SystemDateProvider(),
         onScan: @escaping (ScanResult) -> Void,
         onSuppressed: @escaping (ScanResult, String) -> Void = { _, _ in },
         onTextScan: @escaping (String) -> Void = { _ in },
         onError: @escaping (String) -> Void) {
        self.isPaused = isPaused
        self.recognizesText = recognizesText
        self.dateProvider = dateProvider
        self.onScan = onScan
        self.onSuppressed = onSuppressed
        self.onTextScan = onTextScan
        self.onError = onError
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dateProvider: dateProvider,
                    onScan: onScan,
                    onSuppressed: onSuppressed,
                    onTextScan: onTextScan,
                    onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        var dataTypes: [DataScannerViewController.RecognizedDataType] = [
            .barcode(symbologies: BarcodeScannerView.symbologies)
        ]
        if recognizesText {
            // No language list and no content type: a part number is not a phone number, a URL, or
            // English, and asking for a content type would filter out exactly the strings this app
            // is looking for.
            dataTypes.append(.text())
        }

        let controller = DataScannerViewController(
            recognizedDataTypes: Set(dataTypes),
            qualityLevel: .balanced,
            // Multiple items only when text is on, so a barcode and the line of print beside it can
            // both be highlighted at once. With codes alone, one at a time is the faster decode and
            // the clearer aim.
            recognizesMultipleItems: recognizesText,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // The closures are re-captured every update so they never point at a stale SwiftUI state.
        context.coordinator.onScan = onScan
        context.coordinator.onSuppressed = onSuppressed
        context.coordinator.onTextScan = onTextScan
        context.coordinator.onError = onError
        context.coordinator.apply(isPaused: isPaused, to: uiViewController)
    }

    /// Stops the capture session as soon as the view leaves the hierarchy. Without this the
    /// camera keeps running behind a dismissed sheet.
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController,
                                          coordinator: Coordinator) {
        uiViewController.stopScanning()
        coordinator.reset()
    }

    // MARK: - Coordinator

    /// Delegate bridge.
    ///
    /// The delegate callbacks are plain methods, and everything that reaches back into SwiftUI
    /// state is dispatched through `Task { @MainActor in … }` rather than called inline. That is
    /// what keeps a scan result or an error out of the middle of a view update, which would
    /// otherwise trigger "modifying state during view update" warnings.
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {

        var onScan: (ScanResult) -> Void
        var onSuppressed: (ScanResult, String) -> Void
        var onTextScan: (String) -> Void
        var onError: (String) -> Void

        /// The injected clock. Every `now` handed to the deduplicator comes from here.
        private let dateProvider: any DateProvider

        /// One acceptance per payload per session, with a cooldown between acceptances.
        /// Main-actor state: only ever touched inside the hop below.
        ///
        /// **This is the app's only live-scan deduplicator.** Nothing upstream keeps a second one:
        /// a duplicate that a caller filtered for itself would survive this coordinator's `reset()`
        /// on teardown, and the same code would then be unscannable in a fresh session.
        private var deduplicator = ScanSessionDeduplicator()

        /// `true` once a session is running, so SwiftUI's repeated updates do not restart it.
        private var didStartScanning = false

        /// Mirrors the view's `isPaused`, so a callback that is already in flight when the session
        /// stops cannot slip a result through behind the freeze.
        private var isPaused = false

        /// Failed start attempts. SwiftUI can call `updateUIViewController` before the view is in
        /// a window, where starting legitimately fails, so a couple of retries are allowed — but
        /// the count is hard-bounded, never an open-ended retry loop.
        private var failedStartAttempts = 0

        /// Retry ceiling for `startScanningIfNeeded`.
        private static let maximumStartAttempts = 3

        /// Kept for the life of the session so `prepare()` can warm the Taptic Engine before the
        /// first scan — an unprepared generator can take a moment to respond, which reads as "the
        /// scan didn't register" and makes the technician scan again.
        ///
        /// Created lazily inside the two `@MainActor` helpers below, never in `init`, because UIKit's
        /// feedback generators belong to the main actor and this coordinator's `init` does not run
        /// there. Nothing outside those helpers touches it.
        private var feedbackGenerator: UINotificationFeedbackGenerator?

        init(dateProvider: any DateProvider,
             onScan: @escaping (ScanResult) -> Void,
             onSuppressed: @escaping (ScanResult, String) -> Void,
             onTextScan: @escaping (String) -> Void,
             onError: @escaping (String) -> Void) {
            self.dateProvider = dateProvider
            self.onScan = onScan
            self.onSuppressed = onSuppressed
            self.onTextScan = onTextScan
            self.onError = onError
        }

        /// Clears the session state when the view is torn down, so re-presenting the scanner
        /// starts cleanly — including the deduplicator, which is what lets the same code be
        /// scanned again in a *new* session.
        fileprivate func reset() {
            didStartScanning = false
            failedStartAttempts = 0
            isPaused = false
            deduplicator.reset()
        }

        /// Starts or stops the session to match the view's `isPaused`.
        ///
        /// The deduplicator is deliberately **not** reset on resume. The part that was just scanned
        /// is usually still in front of the lens when the user taps "Resume scanning", and
        /// forgetting it there would re-accept it instantly and trap the user in a loop of freezes.
        /// A genuinely repeated scan of the same code is a new session — close and reopen.
        @MainActor
        func apply(isPaused paused: Bool, to controller: DataScannerViewController) {
            isPaused = paused
            if paused {
                stopScanningIfNeeded(controller)
            } else {
                startScanningIfNeeded(controller)
            }
        }

        /// Starts the capture session once, re-checking hardware support and current availability
        /// first so a failure is reported as a sentence rather than thrown away.
        @MainActor
        func startScanningIfNeeded(_ controller: DataScannerViewController) {
            guard !didStartScanning else { return }
            guard failedStartAttempts < Coordinator.maximumStartAttempts else { return }

            guard DataScannerViewController.isSupported else {
                failedStartAttempts = Coordinator.maximumStartAttempts
                report(ScannerAvailability.unsupportedDevice.explanation)
                return
            }
            guard DataScannerViewController.isAvailable else {
                failedStartAttempts = Coordinator.maximumStartAttempts
                report("The camera isn't available right now. Check camera access in Settings, or type the number in.")
                return
            }

            do {
                try controller.startScanning()
                didStartScanning = true
                failedStartAttempts = 0
                // Warm the Taptic Engine now, while the user is still lining the code up.
                prepareHaptics()
            } catch let unavailable as DataScannerViewController.ScanningUnavailable {
                // A permanent reason — no point retrying on the next update.
                failedStartAttempts = Coordinator.maximumStartAttempts
                report(Coordinator.message(for: unavailable))
            } catch {
                failedStartAttempts += 1
                report("Scanning couldn't start. Type the number in instead.")
            }
        }

        /// Stops a running session. Safe to call when nothing is running.
        @MainActor
        func stopScanningIfNeeded(_ controller: DataScannerViewController) {
            guard didStartScanning else { return }
            controller.stopScanning()
            didStartScanning = false
        }

        // MARK: DataScannerViewControllerDelegate

        /// A code that comes into frame is accepted. Text that comes into frame is only highlighted
        /// — a page of print is not a choice the camera gets to make.
        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode = item else { continue }
                deliver(item)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver(item)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            report(Coordinator.message(for: error))
        }

        // MARK: Private

        /// Pulls the value out of a recognised item and forwards it for acceptance.
        ///
        /// Both kinds end up as suggestions a person confirms — a barcode through
        /// `BarcodePayloadClassifier`, a tapped line through `OCRSuggestionExtractor` — and neither
        /// reaches a record without the review step.
        ///
        /// The payload is cleaned here and nowhere later: `stripControlCharacters` removes the GS /
        /// RS / US / EOT bytes a GS1 or wedge-style decoder emits and trims the edges, while leaving
        /// leading zeros, hyphens, slashes, inner spaces and letter case exactly as printed. This is
        /// **not** `normalizedIdentifier` — the payload that reaches `ScanResult` is still the raw
        /// code, not a tidied-up interpretation of it.
        ///
        /// One consequence worth knowing: a GS1 element string arrives here without its separators,
        /// so downstream GS1 parsing sees the fixed-length-AI form. That is the trade the invisible
        /// characters are worth — an unmatchable part number is a returned core nobody gets paid for.
        private func deliver(_ item: RecognizedItem) {
            switch item {
            case .barcode(let barcode):
                guard let payload = barcode.payloadStringValue else { return }

                let cleaned = ScanTextNormalizer.stripControlCharacters(payload)
                guard !cleaned.isEmpty else { return }
                let symbology = barcode.observation.symbology.rawValue

                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.accept(payload: cleaned, symbology: symbology)
                }

            case .text(let text):
                // Only ever reached from `didTapOn`. The transcript is cleaned exactly as a payload
                // is — control characters out, everything a person can see left alone — and is
                // handed on as the line that was printed, not as an interpretation of it.
                let cleaned = ScanTextNormalizer.stripControlCharacters(text.transcript)
                guard !cleaned.isEmpty else { return }

                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.acceptText(cleaned)
                }

            @unknown default:
                return
            }
        }

        /// The single gate every scan passes through, on the main actor.
        ///
        /// Exactly one `.success` haptic fires per accepted scan, and none at all for a duplicate or
        /// for a scan inside the cooldown — a buzz for a scan the app then ignores is worse than no
        /// buzz, because it tells the technician the code went in when it did not.
        ///
        /// A refused scan is not silent either: it goes to `onSuppressed` with the rule that
        /// stopped it, which is what lets the diagnostics screen explain a scan that "did nothing".
        @MainActor
        private func accept(payload: String, symbology: String) {
            guard admit(payload: payload, symbology: symbology) else { return }
            fireAcceptedHaptic()
            onScan(ScanResult(payload: payload, symbology: symbology))
        }

        /// A tapped text highlight, through exactly the same gate a code goes through.
        ///
        /// Deliberately shares the deduplicator: tapping the same line twice in one session is the
        /// same double-read a code held in frame produces, and it should behave the same way.
        @MainActor
        private func acceptText(_ transcript: String) {
            guard admit(payload: transcript,
                        symbology: BarcodeScannerView.liveTextSymbology) else { return }
            fireAcceptedHaptic()
            onTextScan(transcript)
        }

        /// The single gate every read passes through, code or text, on the main actor.
        ///
        /// - Returns: `true` when the read is new and outside the cooldown. A refusal is not silent
        ///   — it goes to `onSuppressed` with the rule that stopped it, which is what lets the
        ///   diagnostics screen explain a scan that "did nothing". No haptic fires for a refusal: a
        ///   buzz for a read the app then ignores tells the technician it went in when it did not.
        @MainActor
        private func admit(payload: String, symbology: String) -> Bool {
            guard !isPaused else { return false }

            // Read before `accept` mutates the deduplicator: afterwards a repeat and a cooldown
            // refusal are indistinguishable, because both leave the recorded state as it was.
            let isRepeatOfThisSession = deduplicator.acceptedPayloads.contains(payload)

            guard deduplicator.accept(payload: payload,
                                      symbology: symbology,
                                      now: dateProvider.now) else {
                let reason = isRepeatOfThisSession
                    ? BarcodeScannerView.duplicateSuppressionReason
                    : BarcodeScannerView.cooldownSuppressionReason
                onSuppressed(ScanResult(payload: payload, symbology: symbology), reason)
                return false
            }

            return true
        }

        /// Warms the feedback generator so the first buzz is not late.
        @MainActor
        private func prepareHaptics() {
            let generator = feedbackGenerator ?? UINotificationFeedbackGenerator()
            feedbackGenerator = generator
            generator.prepare()
        }

        /// One `.success` notification, then re-warms for the next code.
        @MainActor
        private func fireAcceptedHaptic() {
            let generator = feedbackGenerator ?? UINotificationFeedbackGenerator()
            feedbackGenerator = generator
            generator.notificationOccurred(.success)
            generator.prepare()
        }

        /// Reports a failure on the next main-actor turn, so it is never delivered in the middle
        /// of a SwiftUI view update.
        private func report(_ message: String) {
            Task { @MainActor [weak self] in
                self?.onError(message)
            }
        }

        /// Turns VisionKit's unavailability reason into a sentence a technician can act on.
        private static func message(for error: DataScannerViewController.ScanningUnavailable) -> String {
            switch error {
            case .cameraRestricted:
                return ScannerAvailability.cameraRestricted.explanation
            case .unsupported:
                return ScannerAvailability.unsupportedDevice.explanation
            default:
                return "Scanning stopped. Type the number in instead."
            }
        }
    }
}
