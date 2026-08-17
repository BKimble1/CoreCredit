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

import SwiftUI
import Vision
import VisionKit

/// Live barcode/QR scanning over `DataScannerViewController`.
///
/// Scanning is a shortcut for typing, never a requirement: callers must keep manual entry
/// available, because this view cannot be presented at all in the simulator or on a device
/// without camera access.
@MainActor
struct BarcodeScannerView: UIViewControllerRepresentable {

    /// Called on the main queue for each newly recognised barcode, deduplicated by payload so a
    /// code sitting in the frame does not fire dozens of times.
    private let onScan: (ScanResult) -> Void

    /// Called on the main queue with a user-facing sentence when scanning cannot start or stops.
    private let onError: (String) -> Void

    init(onScan: @escaping (ScanResult) -> Void, onError: @escaping (String) -> Void) {
        self.onScan = onScan
        self.onError = onError
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
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
        context.coordinator.onError = onError
        context.coordinator.startScanningIfNeeded(uiViewController)
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
        var onError: (String) -> Void

        /// `true` once a session is running, so SwiftUI's repeated updates do not restart it.
        private var didStartScanning = false

        /// Failed start attempts. SwiftUI can call `updateUIViewController` before the view is in
        /// a window, where starting legitimately fails, so a couple of retries are allowed — but
        /// the count is hard-bounded, never an open-ended retry loop.
        private var failedStartAttempts = 0

        /// Retry ceiling for `startScanningIfNeeded`.
        private static let maximumStartAttempts = 3

        /// Payloads already handed to `onScan`. Only ever touched on the main queue.
        private var deliveredPayloads: Set<String> = []

        init(onScan: @escaping (ScanResult) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        /// Clears the session state when the view is torn down, so re-presenting the scanner
        /// starts cleanly.
        fileprivate func reset() {
            didStartScanning = false
            failedStartAttempts = 0
            deliveredPayloads.removeAll()
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
            } catch let unavailable as DataScannerViewController.ScanningUnavailable {
                // A permanent reason — no point retrying on the next update.
                failedStartAttempts = Coordinator.maximumStartAttempts
                report(Coordinator.message(for: unavailable))
            } catch {
                failedStartAttempts += 1
                report("Scanning couldn't start. Type the number in instead.")
            }
        }

        // MARK: DataScannerViewControllerDelegate

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
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

        /// Pulls the payload out of a recognised item and forwards it once.
        ///
        /// Text observations are ignored on purpose: this view scans codes. Free text is handled
        /// by the OCR path (`VisionTextRecognizer` + `OCRSuggestionExtractor`), which produces
        /// suggestions the user confirms rather than live values.
        private func deliver(_ item: RecognizedItem) {
            guard case .barcode(let barcode) = item else { return }
            guard let payload = barcode.payloadStringValue else { return }
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let symbology = barcode.observation.symbology.rawValue

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.deliveredPayloads.insert(trimmed).inserted else { return }
                self.onScan(ScanResult(payload: trimmed, symbology: symbology))
            }
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
