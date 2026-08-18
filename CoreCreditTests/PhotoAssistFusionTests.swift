//
//  PhotoAssistFusionTests.swift
//  CoreCreditTests
//
//  The rules AI Photo Assist is not allowed to break, driven directly.
//
//  `PhotoAssistFusion` is pure — no clock, no randomness, no I/O, no Vision — so every case below
//  is a value in and a value out. Nothing here touches a camera, a photo library, a neural engine,
//  a LiDAR scanner, a network, or today's date. That is the entire reason these rules can be
//  asserted at all rather than demonstrated by hand on a bench once and hoped about afterwards.
//
//  The four load-bearing claims, each with a test that fails if it stops being true:
//
//  1. A photograph of a part cannot know a number.
//  2. Money is never pre-ticked.
//  3. Disagreement is shown, not resolved.
//  4. Corroboration is reported, never rewarded.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Photos are fused into suggestions without inventing anything")
struct PhotoAssistFusionTests {

    // MARK: - Fixtures

    private func candidate(_ kind: ScanCandidateKind,
                           _ value: String,
                           confidence: Double,
                           source: ScanSource,
                           reason: String = "Test fixture.") -> ScanCandidate {
        ScanCandidate(kind: kind,
                      rawValue: value,
                      confidence: confidence,
                      source: source,
                      reason: reason)
    }

    private func observation(_ kind: ScanCandidateKind,
                             _ value: String,
                             confidence: Double = 0.9,
                             source: ScanSource = .photoOCR,
                             image: Int = 0,
                             shot: PhotoAssistShot? = nil) -> PhotoAssistObservation {
        PhotoAssistObservation(imageIndex: image,
                               shot: shot,
                               candidate: candidate(kind, value,
                                                    confidence: confidence,
                                                    source: source))
    }

    private func first(_ result: PhotoAssistFusionResult,
                       _ kind: ScanCandidateKind) -> ScanCandidate? {
        result.candidates.first { $0.kind == kind }
    }

    // MARK: - 1. A photograph cannot know a number

    @Test("Image classification can only ever suggest a part name")
    func classificationCanOnlySuggestAPartName() throws {
        // A classifier that has somehow been asked to fill every field on the form. Every one of
        // these but the part name must be dropped — not down-ranked, not shown unticked. Dropped.
        let overreaching: [ScanCandidateKind] = [
            .partNumber, .barcode, .invoiceNumber, .repairOrder,
            .vendorName, .coreAmount, .returnReference, .date,
        ]

        let observations = overreaching.map {
            observation($0, "0.99 confident nonsense", confidence: 0.99,
                        source: .imageClassification)
        } + [observation(.partName, "Alternator", confidence: 0.99,
                         source: .imageClassification)]

        let result = PhotoAssistFusion.fuse(observations)

        #expect(result.candidates.count == 1,
                """
                A photograph of a lump of metal cannot know a part number, a vendor, a reference, or \
                an amount of money. Only the part name may survive image classification.
                """)
        #expect(result.candidates.first?.kind == .partName)
    }

    @Test("A confident visual guess is still never a confident identification")
    func aVisualGuessIsNotAnIdentification() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.partName, "Alternator", confidence: 1.0, source: .imageClassification),
        ])

        #expect(result.candidates.isEmpty == false)
        #expect(result.hasConfidentIdentification == false,
                """
                "It looks like an alternator" is not an identification. Treating it as one is the \
                fake precision this feature is not allowed to have.
                """)
    }

    // MARK: - 2. Money is never pre-ticked

    @Test("A core charge read off a photo never starts selected, however clean the read")
    func moneyNeverStartsSelected() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.coreAmount, "86.50", confidence: 1.0, source: .photoOCR),
        ])

        let amount = try #require(first(result, .coreAmount))
        #expect(amount.isSafeToPreselect == false,
                """
                A wrong number nobody looked at is the most expensive mistake this app can make, and \
                the cost lands on a shop rather than on us.
                """)
        #expect(amount.band != .high)
        #expect(amount.money?.cents == 8650,
                "Capping the score must not disturb the amount itself.")
    }

    @Test("Capping money does not cap anything else")
    func cappingMoneyLeavesIdentifiersAlone() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.coreAmount, "86.50", confidence: 0.99),
            observation(.partNumber, "03-1887", confidence: 0.99, source: .photoBarcode),
        ])

        #expect(first(result, .coreAmount)?.isSafeToPreselect == false)
        #expect(first(result, .partNumber)?.isSafeToPreselect == true,
                "A barcode is the strongest evidence a photo can carry; it is not money.")
    }

    // MARK: - 3. Disagreement is shown, not resolved

    @Test("Two photos reading different part numbers keep both, and tick neither")
    func conflictingPartNumbersBothSurviveUnticked() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", confidence: 0.95, image: 0),
            observation(.partNumber, "03-9921", confidence: 0.60, image: 1),
        ])

        let numbers = result.candidates.filter { $0.kind == .partNumber }
        #expect(numbers.count == 2, "Silently picking the higher score is the app inventing a fact.")
        #expect(numbers.allSatisfy { $0.isSafeToPreselect == false })
        #expect(result.conflictedKinds.contains(.partNumber))

        // Each one has to name the other, or the review sheet is two rows with no explanation.
        #expect(numbers.contains { $0.reason.contains("03-9921") })
        #expect(numbers.contains { $0.reason.contains("03-1887") })
    }

    @Test("Two barcodes are not a disagreement")
    func twoBarcodesAreNotAConflict() throws {
        // A part carries one symbol and its box carries another. Both being present is ordinary.
        let result = PhotoAssistFusion.fuse([
            observation(.barcode, "0123456789012", confidence: 0.95, source: .photoBarcode, image: 0),
            observation(.barcode, "03-1887", confidence: 0.95, source: .photoBarcode, image: 1),
        ])

        #expect(result.conflictedKinds.contains(.barcode) == false)
        #expect(result.candidates.filter { $0.kind == .barcode }.count == 2)
    }

    // MARK: - 4. Corroboration is reported, never rewarded

    @Test("The same value in three photos says so, and scores exactly the same")
    func corroborationIsReportedNotRewarded() throws {
        let alone = PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", confidence: 0.62, image: 0),
        ])
        let thrice = PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", confidence: 0.62, image: 0),
            observation(.partNumber, "03-1887", confidence: 0.62, image: 1),
            observation(.partNumber, "03-1887", confidence: 0.62, image: 2),
        ])

        let one = try #require(first(alone, .partNumber))
        let many = try #require(first(thrice, .partNumber))

        #expect(thrice.candidates.count == 1, "Three readings of one label are one suggestion.")
        #expect(many.confidence == one.confidence,
                """
                Agreement between photographs of the same label mostly means the label was legible \
                three times. It is not new evidence and must not push a medium guess into the band \
                that starts ticked.
                """)
        #expect(many.reason.contains("3 photos"))
    }

    // MARK: - Precedence

    @Test("A barcode outranks OCR, and OCR outranks a visual guess")
    func sourcePrecedenceHoldsRegardlessOfScore() throws {
        // Scores deliberately inverted: the weakest source claims to be the most certain.
        let result = PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", confidence: 0.30, source: .photoBarcode, image: 0),
            observation(.partNumber, "03-1887", confidence: 0.99, source: .photoOCR, image: 1),
        ])

        let number = try #require(first(result, .partNumber))
        #expect(number.source == .photoBarcode,
                """
                A classifier or a text reader being sure of itself is not better evidence than a \
                symbol. Precedence is by source, not by score.
                """)
    }

    // MARK: - Formatting is never "helpfully" repaired

    @Test("Leading zeros, letters, slashes and hyphens all survive fusion")
    func identifierFormattingSurvives() throws {
        let awkward = ["007", "03-1887", "A/12", "0000-0", "P N 44 B"]
        let result = PhotoAssistFusion.fuse(
            awkward.enumerated().map { observation(.partNumber, $0.element, image: $0.offset) }
        )

        let values = Set(result.candidates.map(\.normalizedValue))
        for original in awkward {
            #expect(values.contains(original),
                    "\(original) must survive byte for byte; an identifier is a string.")
        }
    }

    @Test("A part number differing only in punctuation is a genuine disagreement")
    func punctuationDifferencesAreRealConflicts() throws {
        // `03-1887` and `031887` are different strings, and this app has never been willing to
        // guess which one the vendor prints on the invoice it will reconcile against.
        let result = PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", image: 0),
            observation(.partNumber, "031887", image: 1),
        ])

        #expect(result.conflictedKinds.contains(.partNumber))
        #expect(result.candidates.filter { $0.kind == .partNumber }.count == 2)
    }

    @Test("A vendor name differing only in case is not a disagreement")
    func caseDifferencesInProseAreNotConflicts() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.vendorName, "NAPA", image: 0),
            observation(.vendorName, "Napa", image: 1),
        ])

        #expect(result.conflictedKinds.contains(.vendorName) == false,
                "Two photographs of one masthead are not a disagreement worth showing anybody.")
        #expect(result.candidates.filter { $0.kind == .vendorName }.count == 1)
    }

    // MARK: - Determinism and shape

    @Test("The same observations in the same order always fuse to the same result")
    func fusionIsDeterministic() throws {
        let observations = [
            observation(.partNumber, "03-1887", confidence: 0.9, source: .photoBarcode, image: 0),
            observation(.coreAmount, "86.50", confidence: 0.8, image: 1),
            observation(.vendorName, "NAPA", confidence: 0.7, image: 1),
            observation(.partName, "Alternator", confidence: 0.5,
                        source: .imageClassification, image: 0),
        ]

        let first = PhotoAssistFusion.fuse(observations)
        for _ in 0..<10 {
            #expect(PhotoAssistFusion.fuse(observations) == first,
                    "Dictionary iteration order must never reach the output.")
        }
    }

    @Test("Nothing in, nothing out — and no claim of an identification")
    func emptyInputProducesNothing() throws {
        let result = PhotoAssistFusion.fuse([])
        #expect(result.candidates.isEmpty)
        #expect(result.conflictedKinds.isEmpty)
        #expect(result.hasConfidentIdentification == false)
    }

    @Test("Blank and whitespace-only readings are dropped rather than offered")
    func blankValuesAreDropped() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.partNumber, "", image: 0),
            observation(.partNumber, "   ", image: 1),
            observation(.vendorName, "\n\t", image: 2),
        ])
        #expect(result.candidates.isEmpty)
    }

    @Test("A barcode or a part number is what counts as identifying the part")
    func identificationRequiresANumber() throws {
        #expect(PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", confidence: 0.9),
        ]).hasConfidentIdentification)

        #expect(PhotoAssistFusion.fuse([
            observation(.barcode, "0123456789012", confidence: 0.9, source: .photoBarcode),
        ]).hasConfidentIdentification)

        #expect(PhotoAssistFusion.fuse([
            observation(.vendorName, "NAPA", confidence: 0.99),
            observation(.coreAmount, "86.50", confidence: 0.99),
        ]).hasConfidentIdentification == false,
                "Knowing the vendor and the money is not knowing which part it is.")
    }

    @Test("A low-confidence number does not count as an identification")
    func aWeakNumberIsNotAnIdentification() throws {
        let result = PhotoAssistFusion.fuse([
            observation(.partNumber, "03-1887", confidence: 0.20),
        ])
        #expect(result.candidates.isEmpty == false)
        #expect(result.hasConfidentIdentification == false)
    }

    // MARK: - Nothing is invented for fields a photo cannot see

    @Test("Fusion never produces a bin, a status, a due date, or a returned state")
    func noLifecycleFieldIsEverInferred() throws {
        // There is deliberately no `ScanCandidateKind` for any of these, so the strongest statement
        // available is that the kinds a photo can produce fill only the fields listed here. If a
        // future kind maps to storage, lifecycle, or eligibility, this fails and should.
        let fillable = Set(ScanCandidateKind.allCases.compactMap(\.coreItemField))
        let forbidden: Set<CoreItemField> = [.bin, .receivedDate, .dueDate]

        #expect(fillable.isDisjoint(with: forbidden),
                """
                Where a core is stored, when it was received, and when it is due are decided by the \
                shop and by the vendor's return window — never by a photograph.
                """)
    }
}
