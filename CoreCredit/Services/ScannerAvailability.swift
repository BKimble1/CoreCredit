//
//  ScannerAvailability.swift
//  CoreCredit
//
//  Capture layer — availability probing for the hardware barcode scanner.
//
//  Nothing in this file assumes a camera exists. Every negative outcome is a *named state* the
//  UI can render, never a crash and never a silent no-op: the shop floor has iPads with the
//  camera restricted by MDM, phones where the tech tapped "Don't Allow" a year ago, and the
//  simulator, where there is no capture device at all. All four end up here as a value.
//

import AVFoundation
import Foundation
import UIKit
import VisionKit

/// Whether live barcode scanning can run right now, and if not, why not.
///
/// The UI is expected to always offer manual entry as an equal-status alternative; scanning is a
/// convenience, never a requirement. `explanation` is written for a technician, not a developer.
enum ScannerAvailability: Equatable, Sendable {

    /// A supported device with camera access granted. Live scanning may start.
    case available

    /// Running in the iOS simulator. There is no capture device, so the UI offers manual entry
    /// and the test-image path instead. This case exists so the whole app is demoable and
    /// testable without hardware.
    case simulator

    /// The device cannot do live data scanning (no Neural Engine / unsupported hardware).
    case unsupportedDevice

    /// The user explicitly denied camera access. Recoverable only in Settings.
    case cameraDenied

    /// Camera access is blocked by parental controls or an MDM profile. The user cannot change it.
    case cameraRestricted

    /// Camera access has never been requested. Recoverable in-app by asking.
    case cameraNotDetermined

    /// `true` only when a live scanning session can actually be started.
    var allowsScanning: Bool {
        switch self {
        case .available:
            return true
        case .simulator, .unsupportedDevice, .cameraDenied, .cameraRestricted, .cameraNotDetermined:
            return false
        }
    }

    /// One user-facing sentence explaining the state and what happens next.
    var explanation: String {
        switch self {
        case .available:
            return "Point the camera at the barcode on the part or the invoice."
        case .simulator:
            return "The camera isn't available in the simulator. Type the number in instead."
        case .unsupportedDevice:
            return "This device can't scan barcodes. Type the number in instead."
        case .cameraDenied:
            return "CoreCredit doesn't have camera access, so scanning is off. You can turn it on in Settings, or type the number in."
        case .cameraRestricted:
            return "Camera access is restricted on this device, so scanning is off. Type the number in instead."
        case .cameraNotDetermined:
            return "CoreCredit uses the camera to scan barcodes. Continue to the iOS permission request, or type the number below."
        }
    }

    /// Title for the single recovery action the UI should offer, or `nil` when there is nothing
    /// useful to tap.
    ///
    /// `.cameraNotDetermined` is the one state whose action sits on a custom screen shown *before*
    /// an Apple permission alert, so its title is deliberately the neutral "Continue". App Review
    /// guideline 5.1.1(iv) forbids such a screen from imitating the affirmative choice inside the
    /// system alert, and build 64 was rejected for the wording this used to carry. Nothing here may
    /// go back to Allow, Enable, Grant, or Yes.
    ///
    /// `.cameraDenied` is past the point of asking — iOS shows its alert once per install — so it
    /// can only be fixed in Settings, and "Open Settings" is the honest action there.
    var actionTitle: String? {
        switch self {
        case .available:
            return nil
        case .simulator, .unsupportedDevice, .cameraRestricted:
            return "Enter manually"
        case .cameraDenied:
            return "Open Settings"
        case .cameraNotDetermined:
            return "Continue"
        }
    }
}

/// One code read from a barcode/QR symbol, from live scanning or from a still image.
///
/// `id` is a fresh identity so SwiftUI can list several reads of different codes. Equality
/// deliberately ignores `id` and compares the *code itself* — two reads of the same barcode are
/// the same scan result, which is also what unit tests want to assert.
struct ScanResult: Equatable, Sendable, Identifiable {

    /// Per-instance identity for SwiftUI. Not part of equality.
    var id: UUID

    /// The decoded string, exactly as the symbol carried it. Never trimmed or "corrected" here.
    var payload: String

    /// Raw symbology identifier, e.g. `"VNBarcodeSymbologyQR"` or `"VNBarcodeSymbologyCode128"`.
    var symbology: String

    init(payload: String, symbology: String) {
        self.id = UUID()
        self.payload = payload
        self.symbology = symbology
    }

    static func == (lhs: ScanResult, rhs: ScanResult) -> Bool {
        lhs.payload == rhs.payload && lhs.symbology == rhs.symbology
    }
}

/// Answers "can we scan right now?" without ever touching the camera.
///
/// Kept separate from `BarcodeScannerView` so the editor screen can decide what to show *before*
/// a capture session is created, and so previews, unit tests, and the simulator get a truthful
/// answer instead of an exception.
enum BarcodeScannerAvailabilityChecker {

    /// Current availability.
    ///
    /// Order of checks matters:
    /// 1. Simulator first — there is no capture device, and `DataScannerViewController.isSupported`
    ///    reports `false` there anyway, which would read as "your device is too old".
    /// 2. Hardware support, because no permission prompt can fix an unsupported device.
    /// 3. Camera authorization, mapped one-to-one onto the named states.
    @MainActor static func current() -> ScannerAvailability {
        #if targetEnvironment(simulator)
        return .simulator
        #else
        guard DataScannerViewController.isSupported else { return .unsupportedDevice }
        return availability(for: AVCaptureDevice.authorizationStatus(for: .video))
        #endif
    }

    /// Prompts for camera access when it has never been asked for, then re-reports availability.
    ///
    /// Safe to call in any state: when the answer is already known (granted, denied, restricted,
    /// unsupported, simulator) no prompt is shown and the current value is returned unchanged.
    /// iOS only ever shows the system prompt once per install; after that the user must use
    /// Settings, which is why `.cameraDenied` offers `openSettingsURL` instead.
    @MainActor static func requestCameraAccess() async -> ScannerAvailability {
        let existing = current()
        guard existing == .cameraNotDetermined else { return existing }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return current()
    }

    /// Deep link to this app's page in Settings, where camera access can be re-enabled.
    /// `nil` only if the system string ever stops being a valid URL, in which case the UI hides
    /// the button rather than presenting a dead action.
    static var openSettingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    // MARK: - Private

    /// Maps AVFoundation's authorization status onto the app's named states.
    /// Unknown future statuses are treated as "not determined", which is the only value that
    /// still offers the user a way forward inside the app.
    private static func availability(for status: AVAuthorizationStatus) -> ScannerAvailability {
        switch status {
        case .authorized:
            return .available
        case .denied:
            return .cameraDenied
        case .restricted:
            return .cameraRestricted
        case .notDetermined:
            return .cameraNotDetermined
        @unknown default:
            return .cameraNotDetermined
        }
    }
}
