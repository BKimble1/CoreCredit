//
//  ScanDraftApplicationTests.swift
//  CoreCreditTests
//
//  The load-bearing promise of the whole scan layer: **a scan never writes a record.**
//
//  Candidates travel into the in-memory `CoreItemDraft` and no further. The only path to the store
//  remains the editor's own Save action, so these tests hold a real `ModelContext` open while a
//  full set of candidates is applied and then assert the `CoreItem` table is still empty.
//
//  Three more guarantees are pinned here:
//
//  - cancelling a scan leaves an in-progress draft exactly as the user left it;
//  - nothing below `.high` may start ticked in the review sheet;
//  - a raw barcode payload is stored beside the confirmed part number, never over it.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("Applying a scan fills the draft and nothing else")
struct ScanDraftApplicationTests {

    private let documentSource = ScanSource.documentOCR

    /// One candidate of every kind the editor knows how to apply, in the order the review sheet
    /// would hand them over. The barcode comes last on purpose: it must not disturb the part
    /// number that was applied before it.
    private func fullCandidateSet() -> [ScanCandidate] {
        [
            ScanCandidate(kind: .partNumber,
                          rawValue: "03-1887",
                          confidence: 0.9,
                          source: documentSource,
                          reason: "Alphanumeric with a hyphen, typical of a part number"),
            ScanCandidate(kind: .invoiceNumber,
                          rawValue: "INV-100200",
                          confidence: 0.85,
                          source: documentSource,
                          reason: "Follows the label \"INVOICE\""),
            ScanCandidate(kind: .repairOrder,
                          rawValue: "4242",
                          confidence: 0.75,
                          source: documentSource,
                          reason: "Follows the label \"RO\""),
            ScanCandidate(kind: .coreAmount,
                          rawValue: "$86.50",
                          normalizedValue: "86.50",
                          confidence: 0.9,
                          source: documentSource,
                          reason: "Follows the label \"CORE CHARGE\""),
            ScanCandidate(kind: .vendorName,
                          rawValue: "ACME PARTS SUPPLY",
                          confidence: 0.55,
                          source: documentSource,
                          reason: "The first line of the page, printed like a vendor masthead"),
            ScanCandidate(kind: .returnReference,
                          rawValue: "88-77",
                          confidence: 0.75,
                          source: documentSource,
                          reason: "Follows the label \"RMA\""),
            ScanCandidate(kind: .barcode,
                          rawValue: "0123456789012",
                          confidence: 0.95,
                          source: .liveBarcode,
                          reason: "Read from a numeric product code (UPC/EAN/ITF).",
                          barcodeSymbology: "VNBarcodeSymbologyEAN13")
        ]
    }

    // MARK: - Applying candidates writes nothing

    @MainActor
    @Test("Applying candidates fills the draft and leaves the store empty")
    func applyingCandidatesFillsTheDraftAndLeavesTheStoreEmpty() throws {
        let context = try makeInMemoryContext()
        let vendor = makeVendor(context: context, name: "ACME PARTS SUPPLY")

        let model = CoreEditorModel(mode: .create)
        model.calendar = TestClock.calendar

        model.apply(fullCandidateSet(), vendors: [vendor])

        #expect(model.draft.partNumber == "03-1887")
        #expect(model.draft.invoiceReference == "INV-100200")
        #expect(model.draft.repairOrderReference == "4242")
        #expect(model.draft.expectedCreditText == "86.50")
        #expect(model.draft.expectedCredit == Money(cents: 8_650))
        #expect(model.draft.vendorIdentifier == vendor.id)
        #expect(model.draft.notes == "Return reference 88-77")
        #expect(model.draft.scannedBarcodeValue == "0123456789012")
        #expect(model.draft.scannedBarcodeSymbology == "VNBarcodeSymbologyEAN13")
        #expect(model.noticeMessage?.contains("Filled in from the scan") == true)

        // The whole point: everything above happened in memory. Nothing reached the store.
        let storedItems = try context.fetch(FetchDescriptor<CoreItem>())
        #expect(storedItems.count == 0)
        #expect(storedItems.isEmpty)
        #expect(model.createdItem == nil)
        #expect(model.editingItem == nil)
    }

    @MainActor
    @Test("A vendor that is not in the list opens the add-vendor form instead of being dropped")
    func anUnknownVendorOpensTheAddVendorForm() throws {
        let context = try makeInMemoryContext()
        let vendor = makeVendor(context: context, name: "NAPA")

        let model = CoreEditorModel(mode: .create)
        model.calendar = TestClock.calendar

        let suggestion = ScanCandidate(kind: .vendorName,
                                       rawValue: "ACME PARTS SUPPLY",
                                       confidence: 0.55,
                                       source: documentSource,
                                       reason: "The first line of the page, printed like a vendor masthead")
        model.apply([suggestion], vendors: [vendor])

        #expect(model.draft.vendorIdentifier == nil)
        #expect(model.isAddingVendor)
        #expect(model.newVendorName == "ACME PARTS SUPPLY")

        let storedItems = try context.fetch(FetchDescriptor<CoreItem>())
        #expect(storedItems.isEmpty)
    }

    // MARK: - Cancelling

    @MainActor
    @Test("Cancelling a scan leaves the in-progress draft exactly as it was")
    func cancellingAScanLeavesTheDraftUntouched() {
        let model = CoreEditorModel(mode: .create)
        model.calendar = TestClock.calendar

        model.draft.partName = "Alternator"
        model.draft.partNumber = "03-1887"
        model.draft.expectedCreditText = "86.50"
        model.draft.invoiceReference = "INV-100200"
        model.draft.repairOrderReference = "4242"
        model.draft.notes = "Left on the core shelf."
        model.draft.receivedDate = TestClock.referenceNow

        let untouched = model.draft

        let session = ScanReviewSession(source: .liveBarcode,
                                        candidates: fullCandidateSet(),
                                        rawLines: ["0123456789012"])
        model.beginReview(of: session)
        #expect(model.route != nil)

        // The user taps Cancel: the sheet is dismissed and nothing is applied.
        model.route = nil

        #expect(model.route == nil)
        #expect(model.draft == untouched)
        #expect(model.draft.partName == "Alternator")
        #expect(model.draft.partNumber == "03-1887")
        #expect(model.draft.expectedCreditText == "86.50")
        #expect(model.draft.invoiceReference == "INV-100200")
        #expect(model.draft.repairOrderReference == "4242")
        #expect(model.draft.notes == "Left on the core shelf.")
        #expect(model.draft.receivedDate == TestClock.referenceNow)
        #expect(model.draft.vendorIdentifier == nil)
        #expect(model.draft.scannedBarcodeValue == nil)
        #expect(model.draft.scannedBarcodeSymbology == nil)
    }

    // MARK: - Preselection

    @Test("Only a high-confidence candidate is safe to preselect")
    func onlyAHighConfidenceCandidateIsSafeToPreselect() {
        #expect(ScanConfidenceBand.band(for: 0.0) == .low)
        #expect(ScanConfidenceBand.band(for: 0.49) == .low)
        #expect(ScanConfidenceBand.band(for: 0.50) == .medium)
        #expect(ScanConfidenceBand.band(for: 0.79) == .medium)
        #expect(ScanConfidenceBand.band(for: 0.80) == .high)
        #expect(ScanConfidenceBand.band(for: 1.0) == .high)
        // A NaN score collapses to `.low` rather than banding as `.high` by accident.
        #expect(ScanConfidenceBand.band(for: Double.nan) == .low)
        #expect(ScanConfidenceBand.low < ScanConfidenceBand.medium)
        #expect(ScanConfidenceBand.medium < ScanConfidenceBand.high)

        func proposal(_ confidence: Double) -> ScanCandidate {
            ScanCandidate(kind: .partNumber,
                          rawValue: "03-1887",
                          confidence: confidence,
                          source: .liveText,
                          reason: "Alphanumeric with a hyphen, typical of a part number")
        }

        #expect(proposal(0.20).band == .low)
        #expect(proposal(0.20).isSafeToPreselect == false)
        #expect(proposal(0.65).band == .medium)
        #expect(proposal(0.65).isSafeToPreselect == false)
        #expect(proposal(0.79).isSafeToPreselect == false)
        #expect(proposal(0.80).band == .high)
        #expect(proposal(0.80).isSafeToPreselect)
        #expect(proposal(0.95).isSafeToPreselect)

        // The clamp is part of the type, so no heuristic can leak a score that bands wrongly.
        #expect(proposal(4.2).confidence == 1)
        #expect(proposal(-1).confidence == 0)
        #expect(proposal(Double.nan).confidence == 0)
        #expect(proposal(Double.nan).isSafeToPreselect == false)
    }

    // MARK: - The raw payload stays apart from the part number

    @MainActor
    @Test("A raw barcode never overwrites the confirmed part number")
    func aRawBarcodeNeverOverwritesThePartNumber() throws {
        let context = try makeInMemoryContext()

        let model = CoreEditorModel(mode: .create)
        model.calendar = TestClock.calendar
        model.draft.partName = "Alternator"
        model.draft.partNumber = "03-1887"

        // The exact payload, control character and all — this is what the scanner reported.
        let payload = "0123456789012\u{001D}"
        let barcode = ScanCandidate(kind: .barcode,
                                    rawValue: payload,
                                    normalizedValue: "0123456789012",
                                    confidence: 0.95,
                                    source: .liveBarcode,
                                    reason: "Read from a numeric product code (UPC/EAN/ITF).",
                                    barcodeSymbology: "VNBarcodeSymbologyEAN13")

        model.apply([barcode], vendors: [])

        #expect(model.draft.partNumber == "03-1887")

        // Two different jobs, two different values.
        //
        // The draft receives the *confirmed* value — control characters stripped, and carrying
        // any correction the user typed in the review sheet. Persisting a bare GS byte into a
        // record would be a defect, and silently discarding a user's edit would be worse.
        #expect(model.draft.scannedBarcodeValue == "0123456789012")

        // `rawValue` stays sacred on the candidate itself: the payload exactly as the scanner
        // reported it, control character and all, for diagnostics and audit.
        #expect(barcode.rawValue == payload)

        #expect(model.draft.scannedBarcodeSymbology == "VNBarcodeSymbologyEAN13")
        #expect(ScanCandidateKind.barcode.coreItemField == nil)

        let storedItems = try context.fetch(FetchDescriptor<CoreItem>())
        #expect(storedItems.isEmpty)
    }

    // MARK: - Availability

    @Test("No scanner availability state is a dead end")
    func noScannerAvailabilityStateIsADeadEnd() {
        let blocked: [ScannerAvailability] = [
            .cameraDenied, .unsupportedDevice, .simulator, .cameraRestricted, .cameraNotDetermined
        ]

        for state in blocked {
            // Live scanning cannot start in any of these states — including the simulator, where
            // there is no capture device at all.
            #expect(state.allowsScanning == false)
            // …and every one of them still says what to do instead.
            #expect(state.explanation.isEmpty == false)
        }

        #expect(ScannerAvailability.available.allowsScanning)
        #expect(ScannerAvailability.available.explanation.isEmpty == false)

        // The single recovery action each state offers. `.available` has nothing to recover from.
        #expect(ScannerAvailability.simulator.actionTitle == "Enter manually")
        #expect(ScannerAvailability.unsupportedDevice.actionTitle == "Enter manually")
        #expect(ScannerAvailability.cameraRestricted.actionTitle == "Enter manually")
        #expect(ScannerAvailability.cameraDenied.actionTitle == "Open Settings")
        #expect(ScannerAvailability.available.actionTitle == nil)

        // `.cameraNotDetermined` is the only state whose action sits on a custom screen shown
        // *before* an Apple permission alert, so its title is neutral by requirement rather than
        // by taste: App Review rejected build 64 under guideline 5.1.1(iv) for labelling that
        // action "Allow camera access". A pre-permission screen may explain why access is useful,
        // but it may not imitate the affirmative choice inside the system dialog.
        #expect(ScannerAvailability.cameraNotDetermined.actionTitle == "Continue")

        // Manual entry is the alternative in every blocked state, so the sentence has to say so.
        #expect(ScannerAvailability.cameraDenied.explanation.contains("type the number in"))
        #expect(ScannerAvailability.unsupportedDevice.explanation.contains("Type the number in"))
        #expect(ScannerAvailability.simulator.explanation.contains("Type the number in"))
    }

    /// The copy on the one screen App Review actually rejected.
    ///
    /// Guideline 5.1.1(iv), version 1.0, build 64, reviewed on an iPad Air 11-inch (M3) on
    /// 25 August 2026. Apple's instruction was to use neutral wording such as Continue or Next.
    /// This pins the wording from the model side; `scripts/verify_repository.py` pins the button
    /// that renders it, and neither can see the other.
    @Test("The camera primer's copy is neutral and keeps manual entry in view")
    func cameraPrimerCopyIsNeutral() {
        let primer = ScannerAvailability.cameraNotDetermined

        // Neutral: nothing that imitates or pressures the affirmative choice in Apple's alert.
        for pressuring in ["Allow", "allow", "Enable", "Grant", "Yes"] {
            #expect(primer.actionTitle?.contains(pressuring) == false)
            #expect(primer.explanation.contains(pressuring) == false)
        }

        // Factual: it says what the camera is for, and what pressing the action will do.
        #expect(primer.explanation.contains("scan barcodes"))
        #expect(primer.explanation.contains("Continue to the iOS permission request"))

        // And the alternative that needs no camera at all is never dropped from the sentence.
        #expect(primer.explanation.contains("type the number below"))

        // Scanning still cannot start from this state — the primer is an offer, not a grant.
        #expect(primer.allowsScanning == false)
    }
}
