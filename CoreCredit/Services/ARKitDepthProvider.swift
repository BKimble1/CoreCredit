//
//  ARKitDepthProvider.swift
//  CoreCredit
//
//  Scene depth from a LiDAR scanner, on the devices that have one.
//
//  ## What depth is for here, and what it is emphatically not for
//
//  It is for one question: *is the thing in the middle of the frame being held up to the camera, or
//  is it the far wall?* That single bit makes the image classifier's answer worth more or worth
//  less, and it is the entire contribution. Depth never identifies a part, never produces a number
//  this app displays, and never writes an approximate dimension into a note — a measurement that
//  looks authoritative and is actually a guess is exactly the sort of thing that resurfaces in a
//  dispute months later, attached to money.
//
//  ## Why the whole file is conditional
//
//  ARKit is unavailable in the Simulator, and CI builds and tests this app exclusively in the
//  Simulator. Rather than rely on ARKit's simulator stubs behaving, the framework is not imported
//  there at all: on a simulator, and on any platform without ARKit, this type compiles down to one
//  that answers "no depth here" and the feature carries on with ordinary image analysis. That is
//  the same path an iPhone without a LiDAR scanner takes, which means the fallback is not a
//  special case — it is what most devices do.
//

import Foundation

#if canImport(ARKit) && !targetEnvironment(simulator)
import ARKit
import CoreVideo
#endif

/// Scene depth, when the hardware has it.
///
/// Safe to construct anywhere. On hardware without a scanner, in the Simulator, or on a platform
/// with no ARKit at all, `isSceneDepthSupported` is `false` and no session is ever started.
final class ARKitDepthProvider: NSObject, DepthCaptureProviding, @unchecked Sendable {

    /// Guards `latest` across the ARKit delegate queue and the main actor.
    private let lock = NSLock()
    private var latest: DepthSummary?

    #if canImport(ARKit) && !targetEnvironment(simulator)
    private var session: ARSession?
    #endif

    override init() {
        super.init()
    }

    var isSceneDepthSupported: Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        #else
        return false
        #endif
    }

    func currentDepthSummary() async -> DepthSummary? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Starts a depth-only session. Called when the capture screen appears, never before.
    ///
    /// A no-op on hardware that cannot do it, so callers do not have to ask first.
    func start() {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        guard isSceneDepthSupported, session == nil else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth

        let session = ARSession()
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        self.session = session
        #endif
    }

    /// Stops the session and forgets the last reading.
    ///
    /// Called when the capture sheet closes. A depth session holds the camera, and a camera held
    /// after the user has moved on is both a battery problem and, far more importantly, not
    /// something this app is willing to leave running.
    func stop() {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        session?.pause()
        session = nil
        #endif

        lock.lock()
        latest = nil
        lock.unlock()
    }
}

#if canImport(ARKit) && !targetEnvironment(simulator)

extension ARKitDepthProvider: ARSessionDelegate {

    /// Called on ARKit's own queue, many times a second.
    ///
    /// Does as little as possible: reads the centre depth value and its confidence, and stores a
    /// two-field summary. No image is retained, nothing is written to disk, and the pixel buffers
    /// are unlocked before returning.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let sceneDepth = frame.sceneDepth else { return }

        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let centreRow = height / 2
        let centreColumn = width / 2

        let rowPointer = base.advanced(by: centreRow * bytesPerRow)
        let distance = rowPointer
            .assumingMemoryBound(to: Float32.self)
            .advanced(by: centreColumn)
            .pointee

        guard distance.isFinite, distance > 0 else { return }

        let confidence = ARKitDepthProvider.centreConfidence(of: sceneDepth,
                                                             row: centreRow,
                                                             column: centreColumn)

        lock.lock()
        latest = DepthSummary(subjectDistanceMetres: Double(distance), confidence: confidence)
        lock.unlock()
    }

    /// ARKit's own confidence for the centre sample, mapped to 0…1.
    ///
    /// `.low`, `.medium`, `.high` become `0.25`, `0.6`, `0.9`. The exact numbers do not matter
    /// much: nothing multiplies by them, and the only consumer asks whether an object was held
    /// close to the camera.
    private static func centreConfidence(of sceneDepth: ARDepthData,
                                         row: Int,
                                         column: Int) -> Double {
        guard let map = sceneDepth.confidenceMap else { return 0.5 }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(map) else { return 0.5 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        let raw = base
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
            .advanced(by: column)
            .pointee

        switch ARConfidenceLevel(rawValue: Int(raw)) {
        case .high: return 0.9
        case .medium: return 0.6
        case .low: return 0.25
        default: return 0.5
        }
    }
}

#endif
