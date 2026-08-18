//
//  VisionImageAnalyzer.swift
//  CoreCredit
//
//  The real implementations of `ImageClassifying` and `ImageFingerprinting`, on Apple's Vision
//  framework. Nothing here reaches a network, downloads a model, or writes a file: `Vision` ships
//  with the operating system and runs on the device's own silicon.
//
//  Both run on a detached task for the same reason `VisionTextRecognizer` does — a classification
//  pass on a full-size photograph takes long enough to drop frames, and the main actor is holding a
//  camera preview and a form at the time.
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Apple's general image classifier.
final class VisionImageClassifier: ImageClassifying {

    /// Below this, a label is noise rather than a suggestion.
    ///
    /// Vision returns well over a thousand labels for every image, almost all of them at scores
    /// near zero. This is not a claim that `0.10` is *good* — a label at `0.12` still lands in the
    /// review sheet as Low confidence and starts unticked. It is only the point below which
    /// including a label would waste the reader's attention.
    static let minimumConfidence = 0.10

    /// How many labels are worth carrying forward.
    static let maximumLabels = 5

    init() {}

    func classify(imageData: Data) async throws -> [ClassifiedLabel] {
        let task = Task.detached(priority: .userInitiated) {
            try VisionImageClassifier.classifySynchronously(imageData)
        }
        return try await task.value
    }

    // MARK: - Off the main actor

    private static func classifySynchronously(_ imageData: Data) throws -> [ClassifiedLabel] {
        try validateImageData(imageData)

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(data: imageData, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.recognitionFailed(error.localizedDescription)
        }

        guard let observations = request.results else { return [] }

        var labels: [ClassifiedLabel] = []
        for observation in observations {
            let confidence = Double(observation.confidence)
            guard confidence >= minimumConfidence else { continue }
            labels.append(ClassifiedLabel(identifier: observation.identifier,
                                          confidence: confidence))
        }

        // Vision already returns these strongest-first, but the order is sorted explicitly so the
        // pipeline downstream of here does not depend on that staying true.
        labels.sort { left, right in
            left.confidence == right.confidence
                ? left.identifier < right.identifier
                : left.confidence > right.confidence
        }
        return Array(labels.prefix(maximumLabels))
    }

    private static func validateImageData(_ imageData: Data) throws {
        guard imageData.isEmpty == false else { throw RecognitionError.invalidImage }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw RecognitionError.invalidImage
        }
        guard CGImageSourceGetCount(source) > 0 else { throw RecognitionError.invalidImage }
    }
}

/// Vision feature prints, used to notice that two photographs show the same view.
final class VisionImageFingerprinter: ImageFingerprinting {

    init() {}

    func fingerprint(imageData: Data) async throws -> ImageFingerprint {
        let task = Task.detached(priority: .userInitiated) {
            try VisionImageFingerprinter.fingerprintSynchronously(imageData)
        }
        return try await task.value
    }

    /// Euclidean distance between two feature prints.
    ///
    /// Computed directly over the raw float vector rather than through
    /// `VNFeaturePrintObservation.computeDistance(_:to:)`, because that method needs two live
    /// observation objects and this app stores a fingerprint as a value it can hold, compare, and
    /// hand across an actor boundary. The arithmetic is the same arithmetic: a feature print is a
    /// vector of `Float`s, and the distance between two of them is the square root of the summed
    /// squared differences.
    ///
    /// Two prints of different lengths are not comparable — that means they came from different
    /// Vision revisions — and asking is a programming error rather than a user-facing one.
    func distance(_ left: ImageFingerprint, _ right: ImageFingerprint) throws -> Double {
        let leftValues = VisionImageFingerprinter.floats(from: left.data)
        let rightValues = VisionImageFingerprinter.floats(from: right.data)

        guard leftValues.isEmpty == false, leftValues.count == rightValues.count else {
            throw RecognitionError.recognitionFailed(
                "Two photos could not be compared for similarity."
            )
        }

        var total = 0.0
        for index in leftValues.indices {
            let difference = Double(leftValues[index]) - Double(rightValues[index])
            total += difference * difference
        }
        return total.squareRoot()
    }

    // MARK: - Off the main actor

    private static func fingerprintSynchronously(_ imageData: Data) throws -> ImageFingerprint {
        guard imageData.isEmpty == false else { throw RecognitionError.invalidImage }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(data: imageData, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.recognitionFailed(error.localizedDescription)
        }

        guard let observation = request.results?.first else {
            throw RecognitionError.invalidImage
        }
        return ImageFingerprint(data: observation.data)
    }

    /// Reinterprets the print's bytes as the `Float` vector they are.
    private static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(count))
        }
    }
}
