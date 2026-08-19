//
//  PhotoAssistSessionTests.swift
//  CoreCreditTests
//
//  The session's own promises: it holds at most six photographs, it refuses a repeat of a view it
//  already has, it throws away the results of an analysis the user has since invalidated, and it
//  never writes anything anywhere.
//
//  Every dependency is a stub. `StubTextRecognizer` answers with fixed lines, `StubImageClassifier`
//  with a fixed label, `StubImageFingerprinter` treats identical bytes as identical images, and
//  `StubDepthProvider` reports whatever the test says. No camera, no photo library, no LiDAR, no
//  Vision, no clock.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("A photo session gathers, analyses, and writes nothing")
@MainActor
struct PhotoAssistSessionTests {

    // MARK: - Fixtures

    /// Distinct bytes per index, so the byte-equality fingerprinter treats them as distinct views.
    private func photo(_ index: Int) -> Data { Data([UInt8(index + 1)]) }

    private func makeSession(
        lines: [String] = ["ALTERNATOR", "PART NO 03-1887", "CORE CHARGE 86.50"],
        barcodes: [String] = [],
        labels: [ClassifiedLabel] = [],
        depth: any DepthCaptureProviding = UnsupportedDepthProvider()
    ) -> PhotoAssistSession {
        PhotoAssistSession(
            recognizer: StubTextRecognizer(lines: lines, barcodes: barcodes),
            classifier: StubImageClassifier(labels: labels),
            fingerprinter: StubImageFingerprinter(),
            depth: depth
        )
    }

    // MARK: - Gathering

    @Test("The seventh photo is refused, by name, and the first six are kept")
    func theSeventhPhotoIsRefused() async throws {
        let session = makeSession()

        for index in 0..<PhotoAssistFusion.maximumImages {
            let outcome = await session.add(photo(index))
            #expect(outcome == .added)
        }

        #expect(session.photos.count == PhotoAssistFusion.maximumImages)
        #expect(session.canAddMorePhotos == false)

        let overflow = await session.add(photo(99))
        #expect(overflow == .rejectedLimit(limit: PhotoAssistFusion.maximumImages))
        #expect(session.photos.count == PhotoAssistFusion.maximumImages,
                "A refused photo must not displace one that was already accepted.")
        #expect(overflow.message?.isEmpty == false,
                "Every refusal is something the user is told, not a silent no-op.")
    }

    @Test("The same view twice is refused; a different one is not")
    func aRepeatedViewIsRefused() async throws {
        let session = makeSession()

        let firstAngle = await session.add(photo(0))
        #expect(firstAngle == .added)

        let sameAngleAgain = await session.add(photo(0))
        #expect(sameAngleAgain == .rejectedDuplicate,
                "Six slots are not spent on six pictures of one angle.")

        let differentAngle = await session.add(photo(1))
        #expect(differentAngle == .added)
        #expect(session.photos.count == 2)
    }

    @Test("Removing a photo frees its slot")
    func removingAPhotoFreesItsSlot() async throws {
        let session = makeSession()
        for index in 0..<PhotoAssistFusion.maximumImages {
            _ = await session.add(photo(index))
        }
        let doomed = try #require(session.photos.first)

        session.remove(doomed.id)

        #expect(session.photos.count == PhotoAssistFusion.maximumImages - 1)
        #expect(session.canAddMorePhotos)

        let refill = await session.add(photo(0))
        #expect(refill == .added)
    }

    @Test("Reordering puts a photo exactly where it was asked to go")
    func reorderingIsExact() async throws {
        let session = makeSession()
        for index in 0..<4 {
            _ = await session.add(photo(index), shot: nil)
        }
        let original = session.photos.map(\.id)

        // One place later. `destination` is where the photo ends up — not an insertion point in
        // the pre-move indexing, which is what makes SwiftUI's `move(fromOffsets:toOffset:)` read
        // as `index + 2` and go wrong in exactly one direction.
        session.movePhoto(from: 0, to: 1)
        #expect(session.photos.map(\.id) == [original[1], original[0], original[2], original[3]])

        // And back.
        session.movePhoto(from: 1, to: 0)
        #expect(session.photos.map(\.id) == original)

        // All the way to the end.
        session.movePhoto(from: 0, to: 3)
        #expect(session.photos.map(\.id) == [original[1], original[2], original[3], original[0]])
    }

    @Test("An out-of-range reorder clamps instead of trapping")
    func reorderingClamps() async throws {
        let session = makeSession()
        for index in 0..<3 {
            _ = await session.add(photo(index), shot: nil)
        }
        let original = session.photos.map(\.id)

        // A menu's idea of the bounds and the array's can disagree for a frame after a removal.
        // Neither of these may crash, and neither may scramble the order.
        session.movePhoto(from: 0, to: 99)
        #expect(session.photos.map(\.id) == [original[1], original[2], original[0]])

        session.movePhoto(from: 42, to: 0)
        #expect(session.photos.map(\.id) == [original[1], original[2], original[0]],
                "A move from an index that does not exist must change nothing.")

        session.movePhoto(from: 0, to: -5)
        #expect(session.photos.count == 3)
    }

    @Test("Reordering invalidates a result computed for the old order")
    func reorderingInvalidatesTheResult() async throws {
        let session = makeSession()
        _ = await session.add(photo(0))
        _ = await session.add(photo(1))
        await session.analyze()
        #expect(session.phase.result != nil)

        session.movePhoto(from: 0, to: 1)
        #expect(session.phase == .idle,
                "Image index is a tiebreak in fusion, so the order is part of the input.")
    }

    @Test("Empty data is refused rather than analysed")
    func emptyDataIsRefused() async throws {
        let session = makeSession()
        let empty = await session.add(Data())
        #expect(empty == .rejectedUnreadable)
        #expect(session.photos.isEmpty)
    }

    @Test("Guided shots report what is still missing")
    func missingShotsAreReported() async throws {
        let session = makeSession()
        #expect(session.missingShots.count == PhotoAssistShot.allCases.count)

        _ = await session.add(photo(0), shot: .label)
        #expect(session.missingShots.contains(.label) == false)
        #expect(session.missingShots.contains(.invoice))
    }

    // MARK: - Analysis

    @Test("Analysis turns the recognisers' readings into reviewable suggestions")
    func analysisProducesSuggestions() async throws {
        let session = makeSession(labels: [ClassifiedLabel(identifier: "alternator",
                                                           confidence: 0.7)])
        _ = await session.add(photo(0), shot: .label)

        await session.analyze()

        let result = try #require(session.phase.result)
        #expect(result.candidates.isEmpty == false)
        #expect(result.candidates.contains { $0.kind == .partNumber && $0.normalizedValue == "03-1887" })
        #expect(result.candidates.contains { $0.kind == .partName },
                "The classifier's label must arrive as a part name and nothing else.")
    }

    @Test("A visual guess never arrives ready to be applied")
    func aVisualGuessArrivesUnticked() async throws {
        let session = makeSession(lines: [],
                                  labels: [ClassifiedLabel(identifier: "alternator",
                                                           confidence: 1.0)])
        _ = await session.add(photo(0), shot: .part)

        await session.analyze()

        let result = try #require(session.phase.result)
        let name = try #require(result.candidates.first { $0.kind == .partName })
        #expect(name.isSafeToPreselect == false)
        #expect(name.source == .imageClassification)
    }

    @Test("A review session is only offered when there is something to review")
    func reviewSessionRequiresCandidates() async throws {
        let barren = makeSession(lines: [], labels: [])
        _ = await barren.add(photo(0))
        await barren.analyze()
        #expect(barren.reviewSession() == nil)

        let fruitful = makeSession()
        _ = await fruitful.add(photo(0))
        await fruitful.analyze()
        let review = try #require(fruitful.reviewSession())
        #expect(review.candidates.isEmpty == false)
        #expect(review.rawLines.isEmpty == false,
                "The review sheet's 'what did it actually see?' disclosure needs the lines.")
    }

    // MARK: - Staleness and cancellation

    @Test("Changing the photos throws away a result computed for the old set")
    func changingThePhotosInvalidatesTheResult() async throws {
        let session = makeSession()
        _ = await session.add(photo(0))
        await session.analyze()
        #expect(session.phase.result != nil)

        // The user deletes a blurry photo. Whatever was concluded about the old set is no longer
        // about anything, and must not sit on screen looking current.
        _ = await session.add(photo(1))
        #expect(session.phase == .idle,
                """
                A result that outlives the photographs it came from repopulates the review with \
                values the user has already moved past, which reads as the app ignoring them.
                """)
        #expect(session.reviewSession() == nil)
    }

    @Test("Removing a photo also invalidates the result")
    func removingAPhotoInvalidatesTheResult() async throws {
        let session = makeSession()
        _ = await session.add(photo(0))
        _ = await session.add(photo(1))
        await session.analyze()
        #expect(session.phase.result != nil)

        session.remove(try #require(session.photos.first).id)
        #expect(session.phase == .idle)
    }

    @Test("Cancelling leaves the session usable rather than wedged")
    func cancellingLeavesTheSessionUsable() async throws {
        let session = makeSession()
        _ = await session.add(photo(0))

        session.cancel()

        // Cancelling before anything ran must not prevent a later run.
        await session.analyze()
        #expect(session.phase.result != nil)
    }

    @Test("Re-analysing the same photos produces the same suggestions")
    func reanalysisIsStable() async throws {
        let session = makeSession()
        _ = await session.add(photo(0))

        await session.analyze()
        let first = try #require(session.phase.result)
        await session.analyze()
        let second = try #require(session.phase.result)

        #expect(first == second)
    }

    // MARK: - Depth

    @Test("Depth is optional: the same photos produce the same suggestions without a scanner")
    func depthIsNotRequired() async throws {
        let withoutDepth = makeSession(labels: [ClassifiedLabel(identifier: "alternator",
                                                                confidence: 0.7)])
        _ = await withoutDepth.add(photo(0))
        await withoutDepth.analyze()

        let withDepth = makeSession(
            labels: [ClassifiedLabel(identifier: "alternator", confidence: 0.7)],
            depth: StubDepthProvider(isSceneDepthSupported: true,
                                     summary: DepthSummary(subjectDistanceMetres: 0.4,
                                                           confidence: 0.9))
        )
        withDepth.recordDepth(DepthSummary(subjectDistanceMetres: 0.4, confidence: 0.9))
        _ = await withDepth.add(photo(0))
        await withDepth.analyze()

        let plain = try #require(withoutDepth.phase.result)
        let deep = try #require(withDepth.phase.result)

        #expect(plain.candidates.map(\.kind) == deep.candidates.map(\.kind),
                "A LiDAR scanner may change how a suggestion is explained, never which ones exist.")
        #expect(withoutDepth.isDepthSupported == false)
        #expect(withDepth.isDepthSupported)
    }

    @Test("Depth only ever changes the sentence, never the score")
    func depthChangesOnlyTheExplanation() async throws {
        func partName(distance: Double) async throws -> ScanCandidate {
            let session = makeSession(
                lines: [],
                labels: [ClassifiedLabel(identifier: "alternator", confidence: 0.5)],
                depth: StubDepthProvider(isSceneDepthSupported: true, summary: nil)
            )
            session.recordDepth(DepthSummary(subjectDistanceMetres: distance, confidence: 0.9))
            _ = await session.add(photo(0))
            await session.analyze()
            let result = try #require(session.phase.result)
            return try #require(result.candidates.first { $0.kind == .partName })
        }

        let held = try await partName(distance: 0.4)
        let acrossTheRoom = try await partName(distance: 4.0)

        #expect(held.confidence == acrossTheRoom.confidence,
                "Depth is not allowed to become a multiplier on somebody's part number.")
        #expect(held.reason != acrossTheRoom.reason)
        #expect(acrossTheRoom.reason.contains("background"))
    }

    @Test("A depth scanner that has not measured anything yet claims nothing")
    func depthIsNotClaimedBeforeItHasMeasured() async throws {
        // The device has a scanner, and no reading has arrived — which is the state for the whole
        // time somebody is importing photos from their library, because there is no AR session
        // running then. Saying depth is in use here would be claiming a sense that is switched off.
        let session = makeSession(
            lines: [],
            labels: [ClassifiedLabel(identifier: "alternator", confidence: 0.5)],
            depth: StubDepthProvider(isSceneDepthSupported: true, summary: nil)
        )
        _ = await session.add(photo(0))
        await session.analyze()

        #expect(session.isDepthSupported)
        #expect(session.depthSummary == nil)

        let result = try #require(session.phase.result)
        let name = try #require(result.candidates.first { $0.kind == .partName })
        #expect(name.reason.localizedLowercase.contains("depth") == false,
                """
                The reason may only mention depth once depth has actually said something. A                 sentence about a sensor that has not been asked anything is the same unearned                 confidence this feature refuses everywhere else.
                """)
    }

    // MARK: - The persistence boundary

    @Test("A whole session, start to finish, writes nothing to the store")
    func nothingIsEverPersisted() async throws {
        let context = try makeInMemoryContext()
        makeVendor(context: context)

        let session = makeSession(labels: [ClassifiedLabel(identifier: "alternator",
                                                           confidence: 0.9)])
        for index in 0..<3 {
            _ = await session.add(photo(index), shot: PhotoAssistShot.allCases[index])
        }
        await session.analyze()
        _ = session.reviewSession()

        // The session is not given a context and cannot reach one. This asserts the consequence:
        // gathering photographs, reading them, and producing suggestions creates no core, no
        // attachment, and no event. Only `CoreItemService`, called from the editor's own Save,
        // writes anything — and nothing here goes near it.
        #expect(try context.fetch(FetchDescriptor<CoreItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CoreCredit.Attachment>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CoreEvent>()).isEmpty)
    }
}
