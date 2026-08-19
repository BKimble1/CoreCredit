//
//  PhotoAssistSession.swift
//  CoreCredit
//
//  The state of one AI Photo Assist session: the photographs somebody has gathered, what the
//  on-device recognisers made of them, and nothing else. It ends when the sheet closes.
//
//  ## What this deliberately does not do
//
//  It does not touch SwiftData. It does not save an attachment. It does not create a core. The
//  entire output of a session is a `ScanReviewSession` — the same value a live scan or a document
//  scan produces — which the user then reviews, ticks, and applies to a draft that is still sitting
//  unsaved in the editor. The only thing in this app that writes a core is `CoreItemService`, and
//  it is not called from anywhere in this file.
//
//  ## Staleness
//
//  Analysis is slow and the user is not obliged to wait for it. They can delete a photo, add a
//  seventh attempt at the label, or close the sheet while three Vision passes are still running.
//  Every mutation bumps `generation`; every analysis captures the generation it started under and
//  throws its own results away if the number has moved. Without that, deleting a blurry photo
//  mid-analysis lets its candidates arrive afterwards and repopulate the review sheet with values
//  the user has already rejected — the kind of bug that looks like the app ignoring somebody.
//

import Foundation
import Observation

@MainActor
@Observable
final class PhotoAssistSession {

    // MARK: - Types

    /// One photograph, held in memory for as long as the sheet is open.
    struct Photo: Identifiable, Equatable, Sendable {

        var id: UUID

        /// JPEG or HEIC bytes as captured or imported, already downsampled by the caller.
        var data: Data

        /// What the user said this was a picture of, when they said anything.
        var shot: PhotoAssistShot?

        /// Vision feature print, used only to reject a near-identical second photograph.
        var fingerprint: ImageFingerprint?

        init(id: UUID = UUID(),
             data: Data,
             shot: PhotoAssistShot? = nil,
             fingerprint: ImageFingerprint? = nil) {
            self.id = id
            self.data = data
            self.shot = shot
            self.fingerprint = fingerprint
        }
    }

    /// Why a photograph was not accepted. Every case is something the user is told.
    enum AddOutcome: Equatable, Sendable {
        case added
        case rejectedLimit(limit: Int)
        case rejectedDuplicate
        case rejectedUnreadable

        var message: String? {
            switch self {
            case .added:
                return nil
            case .rejectedLimit(let limit):
                return "That's the limit of \(limit) photos. Remove one to add another."
            case .rejectedDuplicate:
                return "That looks like a photo you already added. Try a different angle, or the "
                    + "label instead."
            case .rejectedUnreadable:
                return "That image couldn't be read. Try another one."
            }
        }
    }

    enum Phase: Equatable, Sendable {

        /// Nothing has been analysed yet.
        case idle

        /// Running, with a count so the screen can say "2 of 4".
        case analyzing(completed: Int, total: Int)

        /// Finished. The result may still hold nothing — see `hasConfidentIdentification`.
        case finished(PhotoAssistFusionResult)

        /// Analysis could not run at all. Manual entry is unaffected, and the copy says so.
        case failed(String)

        var result: PhotoAssistFusionResult? {
            if case .finished(let result) = self { return result }
            return nil
        }
    }

    // MARK: - State

    private(set) var photos: [Photo] = []
    private(set) var phase: Phase = .idle

    /// The most recent depth reading, when this device has a scanner and the capture screen is
    /// running one. Never shown as a measurement — see `DepthSummary`.
    private(set) var depthSummary: DepthSummary?

    /// Whether this hardware reports scene depth at all. Drives one subtle line of status text and
    /// nothing else: the feature is identical without it.
    var isDepthSupported: Bool { depth.isSceneDepthSupported }

    var canAddMorePhotos: Bool { photos.count < PhotoAssistFusion.maximumImages }

    var remainingPhotoSlots: Int { max(0, PhotoAssistFusion.maximumImages - photos.count) }

    /// Which guided shots are still missing, so the screen can ask for the useful one next.
    var missingShots: [PhotoAssistShot] {
        let taken = Set(photos.compactMap(\.shot))
        return PhotoAssistShot.allCases.filter { taken.contains($0) == false }
    }

    // MARK: - Dependencies

    private let recognizer: any TextRecognizing
    private let classifier: any ImageClassifying
    private let fingerprinter: any ImageFingerprinting
    private let depth: any DepthCaptureProviding

    /// Bumped by every mutation. An analysis whose generation is stale discards its own results.
    private var generation = 0

    private var analysisTask: Task<Void, Never>?

    /// Feature-print distance below which two photographs are treated as the same view.
    ///
    /// Vision's feature-print distances are not normalised to any fixed range, so this is a
    /// calibrated guess rather than a derived constant, and it is deliberately tight: wrongly
    /// rejecting a genuinely new photograph is worse than accepting a near-duplicate, because one
    /// costs somebody a shot they wanted and the other costs a slot they have five more of.
    static let duplicateDistanceThreshold = 0.30

    init(recognizer: any TextRecognizing,
         classifier: any ImageClassifying,
         fingerprinter: any ImageFingerprinting,
         depth: any DepthCaptureProviding = UnsupportedDepthProvider()) {
        self.recognizer = recognizer
        self.classifier = classifier
        self.fingerprinter = fingerprinter
        self.depth = depth
    }

    // MARK: - Photographs

    /// Adds one photograph, rejecting it when the session is full or it repeats a view.
    @discardableResult
    func add(_ data: Data, shot: PhotoAssistShot? = nil) async -> AddOutcome {
        guard data.isEmpty == false else { return .rejectedUnreadable }
        guard canAddMorePhotos else {
            return .rejectedLimit(limit: PhotoAssistFusion.maximumImages)
        }

        // A fingerprint that cannot be produced is not a reason to refuse the photograph. Vision
        // failing here says something about this image's encoding, not about whether the user
        // wanted it, and the analysis pass will reach its own conclusion.
        var print: ImageFingerprint?
        if let candidate = try? await fingerprinter.fingerprint(imageData: data) {
            print = candidate
            for existing in photos {
                guard let other = existing.fingerprint else { continue }
                if let distance = try? fingerprinter.distance(candidate, other),
                   distance < PhotoAssistSession.duplicateDistanceThreshold {
                    return .rejectedDuplicate
                }
            }
        }

        photos.append(Photo(data: data, shot: shot, fingerprint: print))
        invalidate()
        return .added
    }

    func remove(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos.remove(at: index)
        invalidate()
    }

    /// Moves one photograph to a new position.
    ///
    /// Written out rather than using `move(fromOffsets:toOffset:)`, for two reasons. That method is
    /// vended by **SwiftUI**, and no view model in this app imports SwiftUI — whether it would
    /// resolve here without the import depends on a Swift 5 member-lookup rule that Swift 6 turns
    /// off, which is a strange thing for a photo reorder to depend on. And its `toOffset` is an
    /// insertion point in the *pre-move* indexing, so moving an item one place later reads as
    /// `toOffset: index + 2`, which is the kind of arithmetic that is wrong in one direction and
    /// nobody notices.
    ///
    /// Here `destination` is simply where the photograph ends up. Out-of-range values clamp instead
    /// of trapping: this is driven by a menu whose bounds and the array's can disagree for one
    /// frame after a removal.
    func movePhoto(from index: Int, to destination: Int) {
        guard photos.indices.contains(index) else { return }
        let target = min(max(destination, 0), photos.count - 1)
        guard target != index else { return }

        let moved = photos.remove(at: index)
        photos.insert(moved, at: target)
        invalidate()
    }

    func setShot(_ shot: PhotoAssistShot?, for id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].shot = shot
        invalidate()
    }

    func recordDepth(_ summary: DepthSummary?) {
        depthSummary = summary
    }

    // MARK: - Analysis

    /// Analyses every photograph, one at a time, off the main actor.
    ///
    /// Sequential on purpose. Each pass is a full-size Vision decode, and running six of them
    /// concurrently on a phone that is also holding six photographs in memory is how a capture
    /// screen gets killed for memory rather than finishing slightly sooner.
    func analyze() async {
        analysisTask?.cancel()
        guard photos.isEmpty == false else {
            phase = .idle
            return
        }

        let startedAt = generation
        let work = photos
        phase = .analyzing(completed: 0, total: work.count)

        let task = Task { [weak self] in
            guard let self else { return }
            var observations: [PhotoAssistObservation] = []

            for (index, photo) in work.enumerated() {
                if Task.isCancelled { return }

                let produced = await self.observations(for: photo, at: index)

                if Task.isCancelled { return }
                guard await self.isCurrent(startedAt) else { return }

                observations.append(contentsOf: produced)
                await self.reportProgress(completed: index + 1, total: work.count, since: startedAt)
            }

            guard await self.isCurrent(startedAt) else { return }
            await self.finish(PhotoAssistFusion.fuse(observations), since: startedAt)
        }

        analysisTask = task
        await task.value
    }

    /// Stops any running analysis. Called when the sheet closes.
    func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
    }

    /// The value handed to the existing review sheet, or `nil` when there is nothing to review.
    func reviewSession() -> ScanReviewSession? {
        guard let result = phase.result, result.candidates.isEmpty == false else { return nil }
        return ScanReviewSession(
            source: .photoOCR,
            candidates: result.candidates,
            rawLines: recognizedLines,
            previewImageData: photos.first?.data
        )
    }

    /// Everything that was read, for the review sheet's "what did it actually see?" disclosure.
    private(set) var recognizedLines: [String] = []

    // MARK: - Private

    private func invalidate() {
        generation += 1
        analysisTask?.cancel()
        analysisTask = nil
        recognizedLines = []
        phase = .idle
    }

    private func isCurrent(_ startedAt: Int) -> Bool { generation == startedAt }

    private func reportProgress(completed: Int, total: Int, since startedAt: Int) {
        guard isCurrent(startedAt) else { return }
        phase = .analyzing(completed: completed, total: total)
    }

    private func finish(_ result: PhotoAssistFusionResult, since startedAt: Int) {
        guard isCurrent(startedAt) else { return }
        phase = .finished(result)
    }

    private func appendRecognized(_ lines: [String], since startedAt: Int) {
        guard isCurrent(startedAt) else { return }
        for line in lines where recognizedLines.contains(line) == false {
            recognizedLines.append(line)
        }
    }

    /// Everything one photograph has to say.
    ///
    /// A failure in any one recogniser is recorded as silence from that recogniser, not as a failed
    /// session: a photo of a bare casting genuinely has no text in it, and a photo of an invoice
    /// genuinely has no barcode, and neither is an error worth interrupting somebody over.
    private func observations(for photo: Photo, at index: Int) async -> [PhotoAssistObservation] {
        var results: [PhotoAssistObservation] = []
        let startedAt = generation

        // 1. Symbols. The strongest evidence a photograph can carry, and the only source allowed to
        //    propose a part number without a human having typed one.
        if let scans = try? await recognizer.recognizeBarcodes(in: photo.data) {
            for scan in scans {
                let input = BarcodeScanInput(payload: scan.payload,
                                             symbology: scan.symbology,
                                             source: .photoBarcode)
                for candidate in BarcodePayloadClassifier.candidates(for: input) {
                    var stamped = candidate
                    stamped.source = .photoBarcode
                    stamped.page = index
                    results.append(PhotoAssistObservation(imageIndex: index,
                                                          shot: photo.shot,
                                                          candidate: stamped))
                }
            }
        }

        // 2. Text, through the same extractor the document scanner uses. Every rule about totals,
        //    tax, freight, labour and negative keywords lives in there and is not repeated here.
        if let lines = try? await recognizer.recognizeLines(in: photo.data), lines.isEmpty == false {
            let stampedLines = lines.map { line -> RecognizedLine in
                var copy = line
                copy.page = index
                return copy
            }
            appendRecognized(stampedLines.map(\.text), since: startedAt)

            for candidate in OCRSuggestionExtractor.candidates(from: stampedLines,
                                                               source: .photoOCR) {
                var stamped = candidate
                stamped.page = index
                results.append(PhotoAssistObservation(imageIndex: index,
                                                      shot: photo.shot,
                                                      candidate: stamped))
            }
        }

        // 3. What the thing looks like. The weakest source, and the most tightly leashed.
        if let labels = try? await classifier.classify(imageData: photo.data),
           let best = labels.first {
            results.append(PhotoAssistObservation(
                imageIndex: index,
                shot: photo.shot,
                candidate: classificationCandidate(from: best, at: index)
            ))
        }

        return results
    }

    /// Turns a classifier label into the one kind of candidate it is permitted to become.
    ///
    /// The score is capped below the pre-selection threshold unconditionally. Apple's classifier
    /// can be very sure it is looking at an alternator, and being sure about *that* is still not
    /// grounds for filling a shop's form without somebody glancing at it.
    private func classificationCandidate(from label: ClassifiedLabel,
                                         at index: Int) -> ScanCandidate {
        var reason = "Recognised in the photo as " + label.displayName.lowercased() + "."

        // Depth's entire contribution: confirming something was actually held up to the camera
        // rather than photographed across a workshop. It adjusts a sentence, not a number.
        if depth.isSceneDepthSupported, let summary = depthSummary {
            reason += summary.looksLikeHeldObject
                ? " Depth confirms an object held close to the camera."
                : " Depth suggests the camera was not close to an object, so this may be the"
                    + " background."
        }

        let score = min(label.confidence, PhotoAssistFusion.reviewRequiredCeiling)

        return ScanCandidate(
            kind: .partName,
            rawValue: label.identifier,
            normalizedValue: label.displayName,
            confidence: score,
            source: .imageClassification,
            reason: reason,
            page: index
        )
    }
}
