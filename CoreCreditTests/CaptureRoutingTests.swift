//
//  CaptureRoutingTests.swift
//  CoreCreditTests
//
//  The unified "Scan core" surface, in the parts that can be proved without a camera.
//
//  Three claims are load-bearing after the capture entry points were combined:
//
//  1. **Every external door leads to the same room.** The Quick Scan widget, `ScanCoreIntent`, and
//     a `corecredit://scan` URL are one route — `DeepLink.scan` — which the shell answers with
//     `DashboardModel.beginQuickScan()`, which is `CoreEditorModel.Route.scan`, which is the Live
//     half of the capture sheet. Nothing here is allowed to grow a second scanner.
//  2. **Choosing a capture mode is not a mutation.** Live and Document are two engines behind one
//     entry, and swapping between them is a route change and nothing else — no context, no service,
//     no write.
//  3. **A capture still cannot save.** Candidates reach the in-memory `CoreItemDraft` and stop
//     there. Only `CoreEditorModel.save(using:vendor:bin:tier:)` writes, and it still asks
//     `EntitlementPolicy` first.
//
//  Nothing in this file touches a camera, StoreKit, or the wall clock.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("One capture surface, two engines, and no way to save without saving")
struct CaptureRoutingTests {

    // MARK: - One entry point

    @Test("Every external Scan core entry resolves to the one scan link")
    func everyExternalEntryResolvesToTheScanLink() throws {
        // The App Shortcut / Action Button path. `ScanCoreIntent.perform()` delivers exactly this.
        let intentLink = DeepLink.scan

        // The widget path. `QuickScanLinks.scanURLString` lives in the widget target, which this
        // bundle cannot import, so the string is asserted through the app-side spelling of the same
        // URL — the one the widget is documented to mirror.
        let widgetURL = try #require(URL(string: ReminderRoute.scan))
        #expect(DeepLink.parse(widgetURL) == intentLink)

        // And the raw URL a bin tag, a Shortcut, or a person could hand the app.
        let typedURL = try #require(URL(string: "corecredit://scan"))
        #expect(DeepLink.parse(typedURL) == intentLink)

        #expect(ReminderRoute.scan == "corecredit://scan")
        #expect(DeepLink.scanHost == "scan")
    }

    @Test("The shell answers that link with the create editor's Live capture route")
    @MainActor
    func theShellAnswersTheScanLinkWithTheCaptureRoute() {
        let model = DashboardModel()
        #expect(model.route == nil)

        // What `MainTabView.consumePendingDeepLink()` calls for `.scan`.
        model.beginQuickScan()

        // `Route` is `Identifiable`, not `Equatable`, so identity is compared through the stable
        // `id` the single `.sheet(item:)` presents on. A fixed id is also what makes a second quick
        // scan idempotent while the editor is already open.
        #expect(model.route?.id == "scanCore")

        // A second delivery — a double tap on the widget, a Shortcut fired twice — must leave the
        // unsaved draft exactly as it was rather than presenting a fresh one over it.
        model.beginQuickScan()
        #expect(model.route?.id == "scanCore")
    }

    @Test("The in-app Scan core action opens the same route as the external one")
    @MainActor
    func theInAppScanActionOpensTheSameRoute() {
        let model = DashboardModel()

        // Under the free limit, so nothing is blocked.
        model.requestScanCore(items: [], tier: .free)
        #expect(model.route?.id == "scanCore")

        let external = DashboardModel()
        external.beginQuickScan()
        #expect(external.route?.id == model.route?.id,
                "The Dashboard button and the widget must open the same surface.")
    }

    @Test("Both halves of the capture surface carry the same user-facing name")
    func bothHalvesShareOneTitle() {
        #expect(ScanCaptureCopy.title == "Scan core")
        #expect(ScanCaptureMode.allCases.count == 2)
        #expect(ScanCaptureMode.live.displayName == "Live")
        #expect(ScanCaptureMode.document.displayName == "Document")

        // Each mode says what it is for; neither explanation is empty, because the selector shows
        // one of them at all times.
        for mode in ScanCaptureMode.allCases {
            #expect(mode.explanation.isEmpty == false)
            #expect(mode.symbolName.isEmpty == false)
        }
    }

    // MARK: - Switching modes mutates nothing

    @Test("Swapping between Live and Document changes a route and nothing else")
    @MainActor
    func swappingCaptureModesWritesNothing() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let model = CoreEditorModel(mode: .create)
        let draftBefore = model.draft

        // Exactly what `CoreEditorView.sheetContent(for:)` does when a segment is chosen.
        model.route = .scan
        #expect(model.route?.id == "scan")

        model.route = .documentScan
        #expect(model.route?.id == "documentScan")

        model.route = .scan
        #expect(model.route?.id == "scan")

        model.route = nil

        let unresolved = try service.unresolvedCount()
        let stored = try context.fetch(FetchDescriptor<CoreItem>())

        #expect(model.draft == draftBefore, "Choosing a capture mode must not touch the draft.")
        #expect(model.createdItem == nil)
        #expect(unresolved == 0, "Choosing a capture mode must not write a record.")
        #expect(stored.isEmpty)
    }

    @Test("The two capture routes stay distinct, so one can replace the other on screen")
    @MainActor
    func theTwoCaptureRoutesAreDistinct() {
        // `.sheet(item:)` re-presents only when the identifier changes. Live and Document sharing
        // an id would make the swap a no-op and strand the user on whichever opened first.
        #expect(CoreEditorModel.Route.scan.id != CoreEditorModel.Route.documentScan.id)
    }

    // MARK: - A capture cannot save

    @Test("Applied candidates reach the draft and stop there")
    @MainActor
    func appliedCandidatesReachTheDraftAndStopThere() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        let model = CoreEditorModel(mode: .create)
        model.calendar = TestClock.referenceProvider.calendar

        // The shape the review sheet hands over after the user ticks a row and taps Apply.
        let candidates = [
            ScanCandidate(kind: .partNumber,
                          rawValue: "03-1887",
                          confidence: 1,
                          source: .liveBarcode,
                          reason: "Typed in by hand on the scan screen."),
            ScanCandidate(kind: .coreAmount,
                          rawValue: "$86.50",
                          normalizedValue: "86.50",
                          confidence: 0.9,
                          source: .documentOCR,
                          reason: "Follows the label \"CORE CHARGE\".")
        ]

        model.apply(candidates, vendors: [vendor])

        let stored = try context.fetch(FetchDescriptor<CoreItem>())
        let unresolved = try service.unresolvedCount()

        // The draft has them…
        #expect(model.draft.partNumber == "03-1887")
        #expect(model.draft.expectedCreditText.isEmpty == false)

        // …and the store does not.
        #expect(stored.isEmpty, "Applying a suggestion must never write a record.")
        #expect(model.createdItem == nil)
        #expect(unresolved == 0)
    }

    @Test("Only the editor's Save writes, and it still asks the entitlement policy first")
    @MainActor
    func onlySaveWritesAndItStillAsksThePolicy() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        // Fill the free tier's allowance with unresolved cores.
        for index in 0..<EntitlementPolicy.freeUnresolvedLimit {
            _ = try makeItem(context: context,
                             service: service,
                             partName: "Core \(index)",
                             vendor: vendor)
        }
        let seeded = try service.unresolvedCount()
        #expect(seeded == EntitlementPolicy.freeUnresolvedLimit)

        let model = CoreEditorModel(mode: .create)
        model.calendar = TestClock.referenceProvider.calendar
        model.draft.partName = "Alternator"
        model.draft.expectedCreditText = "86.50"
        model.draft.vendorIdentifier = vendor.id

        // A scan filling the draft changes nothing about the limit.
        model.apply([ScanCandidate(kind: .partNumber,
                                   rawValue: "03-1887",
                                   confidence: 1,
                                   source: .liveBarcode,
                                   reason: "Scanned.")],
                    vendors: [vendor])

        let blocked = model.save(using: service, vendor: vendor, bin: nil, tier: .free)
        let afterBlock = try service.unresolvedCount()
        #expect(blocked == false, "The sixth open core must not be written on the free tier.")
        #expect(model.paywallTrigger != nil, "The block has to be visible as the paywall.")
        #expect(afterBlock == EntitlementPolicy.freeUnresolvedLimit)

        // Nothing about the limit gates the draft itself: the same input saves on Pro.
        model.paywallTrigger = nil
        let saved = model.save(using: service, vendor: vendor, bin: nil, tier: .pro)
        let afterSave = try service.unresolvedCount()
        #expect(saved, "Pro saves the identical draft.")
        #expect(afterSave == EntitlementPolicy.freeUnresolvedLimit + 1)
        #expect(model.createdItem?.partNumber == "03-1887",
                "The confirmed scan value is what was written.")
    }

    @Test("Editing an existing core is never gated, at any number of open cores")
    @MainActor
    func editingIsNeverGated() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        for index in 0..<(EntitlementPolicy.freeUnresolvedLimit + 2) {
            _ = try makeItem(context: context,
                             service: service,
                             partName: "Core \(index)",
                             vendor: vendor)
        }

        let stored = try context.fetch(FetchDescriptor<CoreItem>())
        let existing = try #require(stored.first)
        let model = CoreEditorModel(mode: .edit(existing))
        model.calendar = TestClock.referenceProvider.calendar
        model.draft.partName = "Alternator, rebuilt"

        let saved = model.save(using: service, vendor: vendor, bin: nil, tier: .free)
        #expect(saved, "An edit is never blocked, whatever the tier or the count.")
        #expect(model.paywallTrigger == nil)
        #expect(existing.partName == "Alternator, rebuilt")
    }

    // MARK: - The fallback that never fails

    @Test("Manual entry is the answer in every state where the camera is not")
    func manualEntryCoversEveryUnavailableState() {
        let unavailable: [ScannerAvailability] = [
            .simulator, .unsupportedDevice, .cameraDenied, .cameraRestricted, .cameraNotDetermined
        ]

        for state in unavailable {
            #expect(state.allowsScanning == false)
            // Every one of them has to be explainable, because the sheet renders the sentence
            // beside the manual field rather than showing a dead viewfinder.
            #expect(state.explanation.isEmpty == false)
        }

        #expect(ScannerAvailability.available.allowsScanning)
    }

    /// `@MainActor` because `BarcodeScannerView` is, and its `static let` inherits that isolation.
    @Test("A tapped line of live text is ranked, not trusted")
    @MainActor
    func liveTextIsRankedNotTrusted() {
        // What `ScanSheet.acceptText(_:)` builds: one recognised line at mid confidence, ranked by
        // the same extractor the document path uses. The important half is what it is *not* — a
        // barcode payload — so it can never be classified as one.
        let line = RecognizedLine(text: "CORE CHARGE 86.50", confidence: 0.5)
        let candidates = OCRSuggestionExtractor.candidates(from: [line], source: .liveText)

        #expect(candidates.isEmpty == false)
        for candidate in candidates {
            #expect(candidate.source == .liveText)
            // `rawValue` is the line as printed; nothing may mutate it on the way through.
            #expect(candidate.rawValue.isEmpty == false)
        }

        // Text is a different symbology namespace from any barcode, so a tapped line and a scanned
        // code can never collide in the deduplicator or in diagnostics.
        #expect(BarcodeScannerView.liveTextSymbology == "liveText")
        #expect(BarcodeSymbologyClass.classify(BarcodeScannerView.liveTextSymbology) == .unknown)
    }

    // MARK: - Identifier stability

    @Test("The accessibility identifiers the UI tests mirror have not moved")
    func accessibilityIdentifiersAreStable() {
        // Renaming one of these does not fail to compile — it fails as a UI-test query that never
        // resolves — so the values are pinned here as literals, exactly as the subscription
        // identifiers are.
        #expect(A11y.Dashboard.addCore == "dashboard.addCore")
        #expect(A11y.Dashboard.scanCore == "dashboard.scanCore")
        #expect(A11y.Cores.addButton == "cores.add")
        #expect(A11y.Editor.save == "editor.save")
        #expect(A11y.Editor.cancel == "editor.cancel")
        #expect(A11y.Editor.scan == "editor.scan")
        #expect(A11y.Editor.invoice == "editor.invoice")
        #expect(A11y.Editor.repairOrder == "editor.repairOrder")
        #expect(A11y.Scan.root == "scan.root")
        #expect(A11y.Scan.manualEntry == "scan.manualEntry")
        #expect(A11y.Scan.useManual == "scan.useManual")
        #expect(A11y.Scan.cancel == "scan.cancel")
        #expect(A11y.ScanReview.root == "scanReview.root")
        #expect(A11y.ScanReview.apply == "scanReview.apply")
        #expect(A11y.Settings.subscriptionScreen == "settings.subscriptionScreen")

        // Added by this change, and mirrored in `CoreCreditUITests/UITestSupport.swift`.
        #expect(A11y.Scan.documentRoot == "scan.documentRoot")
        #expect(A11y.Scan.modePicker == "scan.modePicker")
        #expect(A11y.Scan.openDocumentCamera == "scan.openDocumentCamera")
        #expect(A11y.Editor.referencesSection == "editor.referencesSection")
    }

    @Test("The subscription surface this change did not touch is still exactly as it was")
    func subscriptionIdentifiersAreUnchanged() {
        #expect(AppConfiguration.monthlyProductID == "com.blakekimble.corecredit.pro.monthly")
        #expect(AppConfiguration.annualProductID == "com.blakekimble.corecredit.pro.annual")
        #expect(AppConfiguration.bundleIdentifier == "com.blakekimble.corecredit")
        #expect(AppConfiguration.urlScheme == "corecredit")
        #expect(EntitlementPolicy.freeUnresolvedLimit == AppConfiguration.freeUnresolvedItemLimit)
    }
}
