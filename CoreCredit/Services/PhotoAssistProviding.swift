//
//  PhotoAssistProviding.swift
//  CoreCredit
//
//  The seams between AI Photo Assist and the frameworks it borrows from.
//
//  Text and barcodes are *not* here: `TextRecognizing` already reads both out of still image data,
//  it already has a Vision implementation and a deterministic stub, and it is already injected
//  through `AppEnvironment`. Photo Assist uses it unchanged. Adding a second way to read text out
//  of an image would mean two sets of rules about what a part number looks like, which is precisely
//  the failure this app's scan layer was built to avoid.
//
//  What is genuinely new is three things a photograph can offer that a document scan cannot:
//
//  * **What the object is.** Apple's general image classifier, behind `ImageClassifying`.
//  * **Whether two photographs show the same thing.** Vision feature prints, behind
//    `ImageFingerprinting`, so a session does not spend its six slots on six pictures of one angle.
//  * **How far away it is.** ARKit scene depth on the handful of devices that have a LiDAR
//    scanner, behind `DepthCaptureProviding`.
//
//  Every one of them is optional. The feature works with all three missing — on an iPhone with no
//  LiDAR, in the Simulator, and in a unit test — and each protocol has a stub that returns fixed
//  values so the tests never touch a camera, a photo library, or a neural engine.
//

import Foundation

// MARK: - Classification

/// One thing Apple's classifier thinks it can see, with its own score.
struct ClassifiedLabel: Equatable, Sendable, Identifiable {

    /// Vision's identifier, e.g. `"alternator"`. Lowercased, sometimes underscored or hyphenated.
    var identifier: String

    /// Vision's confidence, 0…1.
    var confidence: Double

    var id: String { identifier }

    init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }

    /// The identifier rewritten as something a person would write on a shelf tag.
    ///
    /// `"disc_brake"` becomes `"Disc brake"`. Nothing is translated or expanded — a label this app
    /// does not recognise passes through with its punctuation tidied and its first letter raised,
    /// because inventing a friendlier name for a thing the classifier only half-saw is how a
    /// suggestion stops being traceable to what was actually observed.
    var displayName: String {
        let spaced = identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = spaced.first else { return spaced }
        return String(first).uppercased() + spaced.dropFirst()
    }
}

/// Apple's on-device general image classifier.
///
/// Deliberately narrow: it answers "what is this a picture of?" and nothing else. Everything this
/// app is allowed to do with the answer is decided in `PhotoAssistFusion`, which will only ever let
/// it become a `.partName`.
///
/// ## This protocol is the seam a better model would arrive through
///
/// A multimodal model that can read a photograph of a part would slot in here, as a second
/// conformance chosen at construction time in `AppEnvironment`, with no change to the fusion rules,
/// the review sheet, or the entitlement gate. That is the point of the protocol: the rules about
/// what a photograph is *allowed to claim* live in the domain layer and would still apply, however
/// clever the thing producing the labels became.
///
/// It is a seam and not an implementation for a plain reason: this code was written on a machine
/// with no macOS SDK to inspect, so whether Apple's multimodal Foundation Models image APIs are
/// available in the installed production SDK could not be established. The brief's own instruction
/// for that case is to build the seam and ship Vision, which is what this is. Adding an
/// availability-gated provider would mean guessing at an API surface that cannot be checked, and a
/// guess that fails to compile costs a release cycle to discover.
///
/// Nothing user-facing calls this "Apple Intelligence", and nothing should until such a provider
/// actually ships.
protocol ImageClassifying: Sendable {

    /// Labels for one image, strongest first. Never throws for an unrecognisable image — an empty
    /// array is the honest answer to "what is this?" when the answer is "no idea".
    func classify(imageData: Data) async throws -> [ClassifiedLabel]
}

// MARK: - Fingerprinting

/// Vision feature prints, used only to notice that two photographs show the same view.
protocol ImageFingerprinting: Sendable {

    /// An opaque fingerprint for one image.
    func fingerprint(imageData: Data) async throws -> ImageFingerprint

    /// Distance between two fingerprints. Smaller means more alike; `0` means identical.
    func distance(_ left: ImageFingerprint, _ right: ImageFingerprint) throws -> Double
}

/// An opaque feature print. The bytes are Vision's business.
struct ImageFingerprint: Equatable, Sendable {

    var data: Data

    init(data: Data) {
        self.data = data
    }
}

// MARK: - Depth

/// Whether this device can measure depth, and what it measured.
///
/// LiDAR is an enhancement and never the identification engine. It separates the object in the
/// middle of the frame from the bench behind it, which makes the classifier's job easier. It never
/// produces a number this app shows anybody, and it never writes a measurement into a note: an
/// approximate size presented as a fact is the kind of thing that ends up in a dispute.
protocol DepthCaptureProviding: Sendable {

    /// Whether scene depth is available on this hardware, asked of the framework rather than
    /// inferred from a device name.
    var isSceneDepthSupported: Bool { get }

    /// The most recent depth reading, if this provider is running and has one.
    func currentDepthSummary() async -> DepthSummary?
}

/// What depth contributed, in the only terms this app is willing to state.
struct DepthSummary: Equatable, Sendable {

    /// Roughly how far the centre of the frame is, in metres. Used to sanity-check that something
    /// is actually being photographed rather than a wall three metres away — never displayed.
    var subjectDistanceMetres: Double

    /// Vision's own confidence in that reading, 0…1, from ARKit's depth confidence map.
    var confidence: Double

    /// Whether the reading looks like a hand-held object at arm's length rather than a room.
    ///
    /// The single question this app actually asks depth. Anything outside roughly 15 cm to 1.5 m is
    /// far more likely to be a bench, a floor, or a wall than a core.
    var looksLikeHeldObject: Bool {
        subjectDistanceMetres >= 0.15 && subjectDistanceMetres <= 1.5
    }

    init(subjectDistanceMetres: Double, confidence: Double) {
        self.subjectDistanceMetres = subjectDistanceMetres
        self.confidence = confidence
    }
}

// MARK: - Stubs

/// Fixed classifications, for tests and for UI-test launches.
struct StubImageClassifier: ImageClassifying {

    var labels: [ClassifiedLabel]

    /// Constrained to `Sendable` because `ImageClassifying` is: a `Sendable`-conforming struct
    /// storing a bare `any Error` is a warning today and an error under Swift 6 language mode.
    var error: (any Error & Sendable)?

    init(labels: [ClassifiedLabel] = [], error: (any Error & Sendable)? = nil) {
        self.labels = labels
        self.error = error
    }

    func classify(imageData: Data) async throws -> [ClassifiedLabel] {
        if let error { throw error }
        return labels
    }
}

/// Fingerprints an image by its own bytes.
///
/// Deterministic and dependency-free: two identical `Data` values are identical images, and two
/// different ones are maximally different. That is exactly the behaviour a duplicate-detection test
/// wants, and it is useless on real photographs — which is why the real implementation exists.
struct StubImageFingerprinter: ImageFingerprinting {

    init() {}

    func fingerprint(imageData: Data) async throws -> ImageFingerprint {
        ImageFingerprint(data: imageData)
    }

    func distance(_ left: ImageFingerprint, _ right: ImageFingerprint) throws -> Double {
        left == right ? 0 : 1
    }
}

/// A device with no depth sensor. The default everywhere except a LiDAR phone.
struct UnsupportedDepthProvider: DepthCaptureProviding {

    init() {}

    var isSceneDepthSupported: Bool { false }

    func currentDepthSummary() async -> DepthSummary? { nil }
}

/// A depth sensor that reports whatever a test tells it to.
struct StubDepthProvider: DepthCaptureProviding {

    var isSceneDepthSupported: Bool
    var summary: DepthSummary?

    init(isSceneDepthSupported: Bool = true, summary: DepthSummary? = nil) {
        self.isSceneDepthSupported = isSceneDepthSupported
        self.summary = summary
    }

    func currentDepthSummary() async -> DepthSummary? { summary }
}
