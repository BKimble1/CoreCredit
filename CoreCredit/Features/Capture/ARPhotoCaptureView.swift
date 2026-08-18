//
//  ARPhotoCaptureView.swift
//  CoreCredit
//
//  The optional "Auto" half of AI Photo Assist: hold the phone still on a part and it collects a
//  frame, instead of making somebody tap a shutter with one greasy hand.
//
//  ## Why ARKit rather than motion or a timer
//
//  Steadiness has to be measured against the *world*, not against the phone. Core Motion would
//  answer "is the device still?", which a phone lying on a bench answers yes to forever, and asking
//  for motion authorisation to find that out would be a permission prompt bought for nothing.
//  ARKit already tracks where the camera is in the room and hands over `camera.transform` with
//  every frame; the difference between two consecutive transforms is exactly the question being
//  asked, and it costs no additional permission beyond the camera the user already tapped for.
//
//  ## Bounded to this screen, always
//
//  The session starts in `makeUIView` and is paused in `dismantleUIView`. There is no path that
//  leaves it running: closing the sheet tears down the view, and the view tearing down pauses the
//  session. Nothing is captured while the app is backgrounded, because a paused ARSession delivers
//  no frames at all.
//
//  ## Why the whole file is conditional
//
//  ARKit does not exist on the Simulator, and CI builds and tests this app exclusively there. On a
//  simulator — and on any device where world tracking is unavailable — `ARPhotoCaptureView.isSupported`
//  is `false`, the Auto control is never offered, and the feature is exactly what it is on every
//  other phone: take the photographs yourself.
//

import SwiftUI

#if canImport(ARKit) && !targetEnvironment(simulator)
import ARKit
import CoreImage
import SceneKit
#endif

/// Whether automatic capture can run on this hardware, and the screen that does it.
enum ARPhotoCapture {

    /// World tracking, asked of the framework rather than inferred from a device name.
    static var isSupported: Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        return ARWorldTrackingConfiguration.isSupported
        #else
        return false
        #endif
    }

    /// How still is still enough, in metres of camera movement between consecutive frames.
    static let stillnessMetres = 0.004

    /// How many consecutive still frames before a capture. At 60 fps this is a touch under a
    /// quarter-second of genuinely holding it — long enough not to fire mid-swing, short enough
    /// that it does not feel broken.
    static let framesToSettle = 14

    /// Minimum seconds between two automatic captures, so one steady hand does not fill all six
    /// slots with the same view before the user can move.
    static let cooldownSeconds = 1.5
}

#if canImport(ARKit) && !targetEnvironment(simulator)

/// A live AR camera that collects a frame once the view holds still.
@MainActor
struct ARPhotoCaptureView: UIViewRepresentable {

    /// A captured frame, already JPEG-encoded and oriented upright.
    let onCapture: (Data) -> Void

    /// "Hold steady", "Captured", and so on — shown above the preview and announced by VoiceOver.
    let onStatus: (String) -> Void

    /// Whether the session should still be collecting. Set false at the image limit.
    let isCollecting: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onStatus: onStatus)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.isUserInteractionEnabled = false

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        }
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.isCollecting = isCollecting
    }

    /// Pauses the session when the view goes away. This is the only lifetime the session has.
    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        coordinator.isCollecting = false
        view.session.pause()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSessionDelegate {

        private let onCapture: (Data) -> Void
        private let onStatus: (String) -> Void

        var isCollecting = true

        private var lastPosition: simd_float3?
        private var stillFrames = 0
        private var lastCaptureAt: Date?
        private let context = CIContext()

        init(onCapture: @escaping (Data) -> Void, onStatus: @escaping (String) -> Void) {
            self.onCapture = onCapture
            self.onStatus = onStatus
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard isCollecting else { return }

            let column = frame.camera.transform.columns.3
            let position = simd_float3(column.x, column.y, column.z)
            defer { lastPosition = position }

            guard let previous = lastPosition else { return }

            let travelled = Double(simd_distance(previous, position))
            guard travelled < ARPhotoCapture.stillnessMetres else {
                if stillFrames > 0 {
                    stillFrames = 0
                    report("Hold steady")
                }
                return
            }

            stillFrames += 1
            guard stillFrames >= ARPhotoCapture.framesToSettle else { return }

            // Cooldown. Without it a steady hand fills every slot with one viewpoint before
            // anybody can move to the label.
            let now = Date()
            if let last = lastCaptureAt,
               now.timeIntervalSince(last) < ARPhotoCapture.cooldownSeconds {
                return
            }

            guard let data = jpeg(from: frame) else { return }

            stillFrames = 0
            lastCaptureAt = now
            report("Captured")
            let deliver = onCapture
            Task { @MainActor in deliver(data) }
        }

        private func report(_ status: String) {
            let deliver = onStatus
            Task { @MainActor in deliver(status) }
        }

        /// The frame as upright JPEG bytes.
        ///
        /// `capturedImage` arrives in the sensor's landscape orientation regardless of how the
        /// phone is held, so it is rotated before encoding — an invoice photographed in portrait
        /// and delivered sideways would be read sideways, and Vision's text recogniser would find
        /// nothing at all.
        private func jpeg(from frame: ARFrame) -> Data? {
            let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
                return nil
            }
            return context.jpegRepresentation(of: image,
                                              colorSpace: colorSpace,
                                              options: [:])
        }
    }
}

#endif
