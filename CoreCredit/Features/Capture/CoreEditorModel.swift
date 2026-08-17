//
//  CoreEditorModel.swift
//  CoreCredit
//
//  Capture feature — all of the editor's state, in one observable object.
//
//  ## The rule this screen is built around
//
//  A technician is standing at a parts counter with a customer waiting. **Typing a core in by hand
//  must always work.** Scanning, OCR, and the camera are accelerators layered on top; none of them
//  can gate a save, and none of them writes to a record without a confirming tap. Every convenience
//  in this file is therefore optional and reversible: a scanned code lands in an editable field, an
//  OCR suggestion lands in an editable field, and a missing camera changes nothing about the form.
//
//  The model holds a `CoreItemDraft` rather than a `CoreItem`, so an abandoned edit leaves the store
//  untouched and money stays as the user's raw text until `Money.parse` reads it.
//

import Foundation
import Observation
import SwiftData

/// State for `CoreEditorView`: the draft, its validation issues, which sheet is open, and any
/// message that needs to reach the user.
///
/// Deliberately free of SwiftData handles. Every mutation that has to touch the store takes a
/// `CoreItemService` as a parameter, so this object can be reasoned about (and its save path read)
/// without chasing a context through the view hierarchy.
@MainActor
@Observable
final class CoreEditorModel {

    // MARK: - Routing

    /// The modal the editor currently has open. `nil` means the form itself is in front.
    ///
    /// `id` is **unique per associated value**, deliberately. One `.sheet(item:)` drives this
    /// screen, and SwiftUI only re-presents when the identifier changes: an `id` that ignored the
    /// payload — as `.readPhoto` used to — meant reading a *second* photo, or reviewing a *second*
    /// scan, silently did nothing.
    enum Route: Identifiable {

        /// Barcode capture, with its own manual-entry fallback.
        case scan

        /// Photo capture for one kind of evidence.
        case attachment(AttachmentKind)

        /// OCR review for an already-captured photo. Carries the image bytes so the sheet does not
        /// have to reach back into SwiftData for them.
        case readPhoto(Data)

        /// Confirmation of everything a capture produced. Carries the session so the sheet is a
        /// pure function of the route.
        case scanReview(ScanReviewSession)

        /// Multi-page invoice or receipt capture through the document camera.
        case documentScan

        var id: String {
            switch self {
            case .scan:
                return "scan"
            case .attachment(let kind):
                return "attachment." + kind.rawValue
            case .readPhoto(let data):
                return "readPhoto." + CoreEditorModel.identityKey(for: data)
            case .scanReview(let session):
                return "scanReview." + session.id.uuidString
            case .documentScan:
                return "documentScan"
            }
        }
    }

    // MARK: - Identity

    /// Whether this editor is creating a record or changing one that already exists.
    let mode: CoreEditorMode

    // MARK: - Editable state

    /// The values being edited. Bound directly by the form's controls.
    var draft: CoreItemDraft

    /// Which sheet is presented, if any.
    var route: Route?

    /// Set when the free-tier limit blocks a *new* record. Bound to a `.sheet(item:)` presenting
    /// `PaywallView`. Editing an existing record never sets this.
    var paywallTrigger: PaywallTrigger?

    /// A failure the user needs to see, already phrased for a shop floor.
    var errorMessage: String?

    /// A neutral confirmation, e.g. "Part number filled in from the scan."
    var noticeMessage: String?

    /// True while a save is in flight, so the button cannot be double-tapped.
    var isSaving = false

    // MARK: - Vendor quick-create

    /// True while the inline "add a vendor" form is showing.
    var isAddingVendor = false
    var newVendorName = ""

    /// Starting point for a brand-new vendor's return window. This is the app's configured default,
    /// **not** any particular vendor's policy — the user changes it before adding.
    var newVendorWindowDays = AppConfiguration.defaultVendorReturnWindowDays

    // MARK: - Bin quick-create

    /// True while the inline "add a bin" form is showing.
    var isAddingBin = false
    var newBinLabel = ""
    var newBinLocationNote = ""

    // MARK: - Injected environment

    /// Calendar used for due-date maths and validation. Replaced with the app's injected calendar
    /// as soon as the view has access to `AppEnvironment`, so tests stay deterministic.
    var calendar: Calendar = .autoupdatingCurrent

    // MARK: - Derived state

    /// Current validation issues. Empty until the first save attempt.
    private(set) var issues: [ValidationIssue] = []

    /// Photos captured before the record exists. Flushed onto the item once it has been created.
    private(set) var pendingPhotos: [Attachment] = []

    /// The field the editor should move focus to and scroll to after a failed save.
    private(set) var firstInvalidField: CoreItemField?

    /// The item produced by a successful `createItem`, kept so that a *retry* after a later failure
    /// (for example a photo that would not attach) updates that record instead of creating a second
    /// one. This is the whole reason saving is idempotent.
    private(set) var createdItem: CoreItem?

    /// Errors stay hidden until the user has actually tried to save; after that they re-evaluate on
    /// every keystroke so a corrected field clears itself.
    private var hasAttemptedSave = false

    // MARK: - Init

    init(mode: CoreEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            self.draft = CoreItemDraft()
        case .edit(let item):
            self.draft = CoreEditorModel.makeDraft(for: item)
        }
    }

    // MARK: - Mode

    /// True when this editor will create a new record.
    var isCreatingNewRecord: Bool {
        if case .create = mode { return true }
        return false
    }

    /// Screen title.
    var title: String {
        isCreatingNewRecord ? "Add core" : "Edit core"
    }

    /// The stored record being edited, or the one this editor just created. `nil` while a brand-new
    /// core has not been saved yet.
    var editingItem: CoreItem? {
        switch mode {
        case .create:
            return createdItem
        case .edit(let item):
            return item
        }
    }

    // MARK: - Photos

    /// Photos to show in the strip: everything already attached to the record, plus anything
    /// captured while a new record is still unsaved.
    var photos: [Attachment] {
        (editingItem?.photos ?? []) + pendingPhotos
    }

    /// Image bytes of the most recently captured photo, for the "read details from a photo" path.
    /// `nil` when there is nothing to read.
    var latestPhotoData: Data? {
        guard let data = photos.last?.imageData, !data.isEmpty else { return nil }
        return data
    }

    /// Attaches a photo. Existing records get it immediately (evidence is not draft data); a record
    /// that does not exist yet holds it until the first successful save.
    func addPhoto(_ attachment: Attachment, using service: CoreItemService) {
        guard let item = editingItem else {
            pendingPhotos.append(attachment)
            return
        }
        do {
            try service.addAttachment(attachment, to: item)
        } catch {
            errorMessage = CoreEditorModel.presentable(error)
        }
    }

    /// Removes a photo from wherever it currently lives.
    func removePhoto(_ attachment: Attachment, using service: CoreItemService) {
        if let index = pendingPhotos.firstIndex(where: { $0.id == attachment.id }) {
            pendingPhotos.remove(at: index)
            return
        }
        guard let item = editingItem else { return }
        do {
            try service.removeAttachment(attachment, from: item)
        } catch {
            errorMessage = CoreEditorModel.presentable(error)
        }
    }

    // MARK: - Validation

    /// The message to show under `field`, or `nil` when there is nothing to say.
    ///
    /// Silent until the first save attempt: a form should not turn red while it is still being
    /// filled in for the first time.
    func message(for field: CoreItemField) -> String? {
        guard hasAttemptedSave else { return nil }
        return CoreItemValidator.firstIssue(issues, for: field)?.message
    }

    /// Re-runs validation, but only once the user has seen an error — that is what makes a
    /// corrected field clear itself as they type.
    func revalidateIfNeeded() {
        guard hasAttemptedSave else { return }
        issues = CoreItemValidator.validate(draft, calendar: calendar)
    }

    // MARK: - Due dates

    /// The deadline this draft currently implies.
    ///
    /// The window always comes from the selected vendor (or the app's configured fallback while no
    /// vendor is chosen). No policy is hard-coded here.
    func resolvedDueDate(vendorWindowDays: Int) -> Date {
        draft.resolvedDueDate(vendorWindowDays: vendorWindowDays, calendar: calendar)
    }

    /// Seeds the hand-picked due date with the computed one the first time the override is turned
    /// on, so the date picker opens on a sensible day instead of "today".
    func seedCustomDueDateIfNeeded(vendorWindowDays: Int) {
        guard draft.usesCustomDueDate, draft.customDueDate == nil else { return }
        draft.customDueDate = resolvedDueDate(vendorWindowDays: vendorWindowDays)
    }

    // MARK: - Scanning

    /// Applies a scanned code to the draft.
    ///
    /// A barcode on a part or its box is, overwhelmingly, the part number — so that is where it
    /// goes. It lands in an ordinary editable field and the user is told what happened, because a
    /// vendor's internal SKU is sometimes not the number the shop wants recorded.
    ///
    /// Kept for the direct "I already know this is the part number" path. The scanner itself no
    /// longer calls it: a live read now travels as `[ScanCandidate]` through the review sheet, so
    /// the user sees what was read and where it is going before anything is filled in.
    func applyScannedPayload(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft.partNumber = trimmed
        noticeMessage = "Part number filled in from the scan. Change it if that code isn't the part number."
        revalidateIfNeeded()
    }

    /// Opens the confirmation step for a capture. Nothing is written by presenting it.
    func beginReview(of session: ScanReviewSession) {
        route = .scanReview(session)
    }

    /// Writes confirmed scan candidates into the draft.
    ///
    /// Called only from the review sheet's *Apply Selected Suggestions* action. Three things this
    /// deliberately does **not** do: it does not touch the store (the draft is in memory until the
    /// editor's own Save runs), it does not apply anything the user did not tick, and it never lets
    /// a raw barcode payload overwrite the confirmed part number — the payload has its own field on
    /// the draft so both survive.
    ///
    /// A suggested vendor is matched against the shop's existing vendors by name; when there is no
    /// match the inline "add a vendor" form is opened pre-filled, rather than silently dropping it.
    func apply(_ candidates: [ScanCandidate], vendors: [Vendor]) {
        var applied: [String] = []
        var unmatchedVendorName: String?

        for candidate in candidates {
            let value = candidate.normalizedValue.trimmingCharacters(in: .whitespacesAndNewlines)

            switch candidate.kind {
            case .partNumber:
                guard value.isEmpty == false else { continue }
                draft.partNumber = value
                applied.append("part number")

            case .barcode:
                // The value as the user confirmed it — the review sheet carries their edit in
                // `normalizedValue`, and a technician who corrected a misread digit must not have
                // that correction thrown away. `candidate.rawValue` is untouched either way: it is
                // the record of what was recognised, kept so "did it misread it, or did someone
                // change it?" is still answerable. Never into `partNumber`, whichever it is.
                guard value.isEmpty == false else { continue }
                draft.scannedBarcodeValue = value
                draft.scannedBarcodeSymbology = candidate.barcodeSymbology
                applied.append("scanned barcode")

            case .invoiceNumber:
                guard value.isEmpty == false else { continue }
                draft.invoiceReference = value
                applied.append("invoice")

            case .repairOrder:
                guard value.isEmpty == false else { continue }
                draft.repairOrderReference = value
                applied.append("repair order")

            case .coreAmount:
                guard value.isEmpty == false else { continue }
                // Exact cents when it parses, so the field holds a figure the validator agrees
                // with; the user's own text otherwise, so nothing they typed is thrown away.
                if let money = candidate.money {
                    draft.expectedCreditText = money.plainDecimalString
                } else {
                    draft.expectedCreditText = value
                }
                applied.append("core charge")

            case .vendorName:
                guard value.isEmpty == false else { continue }
                if let match = vendors.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame
                }) {
                    draft.vendorIdentifier = match.id
                    applied.append("vendor")
                } else {
                    unmatchedVendorName = value
                }

            case .returnReference:
                guard value.isEmpty == false else { continue }
                // Appended, never substituted: CoreCredit has no RMA field, and whatever the user
                // already wrote in the notes is theirs.
                let line = "Return reference " + value
                if draft.notes.contains(line) == false {
                    draft.notes = draft.notes.isEmpty ? line : draft.notes + "\n" + line
                }
                applied.append("return reference")

            case .date, .unknown:
                // Informational. The received date comes from the app's own clock, and text that
                // matched nothing has no field until the user retargets it in the review sheet.
                continue
            }
        }

        if let unmatchedVendorName = unmatchedVendorName {
            newVendorName = unmatchedVendorName
            isAddingVendor = true
        }

        if applied.isEmpty {
            noticeMessage = unmatchedVendorName == nil
                ? "Nothing was applied from that scan. Type the details in instead."
                : "That vendor isn't in your list yet. Check the name and add it, or pick a different vendor."
        } else {
            noticeMessage = "Filled in from the scan: " + applied.joined(separator: ", ")
                + ". Check each one before you save."
        }

        revalidateIfNeeded()
    }

    // MARK: - OCR

    /// Writes confirmed OCR suggestions into the draft.
    ///
    /// The older, flatter shape, kept because `OCRSuggestionExtractor.suggestions(from:)` is still
    /// part of the extractor's contract. The review sheets now hand over `[ScanCandidate]` instead,
    /// which carries the raw reading and the reasoning as well as the value. Nothing here runs on
    /// its own either way.
    ///
    /// A suggested vendor is matched against the shop's existing vendors by name; when there is no
    /// match the inline "add a vendor" form is opened pre-filled, rather than silently dropping it.
    func apply(_ suggestions: [OCRFieldSuggestion], vendors: [Vendor]) {
        var applied: [String] = []
        var unmatchedVendorName: String?

        for suggestion in suggestions {
            let value = suggestion.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch suggestion.field {
            case .partNumber:
                draft.partNumber = value
                applied.append(suggestion.field.displayName)
            case .invoiceReference:
                draft.invoiceReference = value
                applied.append(suggestion.field.displayName)
            case .repairOrderReference:
                draft.repairOrderReference = value
                applied.append(suggestion.field.displayName)
            case .amount:
                draft.expectedCreditText = value
                applied.append(suggestion.field.displayName)
            case .vendorName:
                if let match = vendors.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame
                }) {
                    draft.vendorIdentifier = match.id
                    applied.append(suggestion.field.displayName)
                } else {
                    unmatchedVendorName = value
                }
            }
        }

        if let unmatchedVendorName = unmatchedVendorName {
            newVendorName = unmatchedVendorName
            isAddingVendor = true
        }

        if applied.isEmpty {
            noticeMessage = unmatchedVendorName == nil
                ? "Nothing was applied from that photo. Type the details in instead."
                : "That vendor isn't in your list yet. Check the name and add it, or pick a different vendor."
        } else {
            noticeMessage = "Filled in from the photo: " + applied.joined(separator: ", ")
                + ". Check each one before you save."
        }

        revalidateIfNeeded()
    }

    // MARK: - Vendors and bins

    /// Creates a vendor from the inline form and selects it, without leaving the editor.
    func createVendor(using service: CoreItemService) {
        let name = newVendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let vendor = try service.createVendor(name: name, returnWindowDays: newVendorWindowDays)
            draft.vendorIdentifier = vendor.id
            isAddingVendor = false
            newVendorName = ""
            newVendorWindowDays = AppConfiguration.defaultVendorReturnWindowDays
            noticeMessage = "Added " + vendor.displayName + "."
            revalidateIfNeeded()
        } catch {
            errorMessage = CoreEditorModel.presentable(error)
        }
    }

    /// Abandons the inline vendor form.
    func cancelVendorCreation() {
        isAddingVendor = false
        newVendorName = ""
        newVendorWindowDays = AppConfiguration.defaultVendorReturnWindowDays
    }

    /// Creates a storage bin from the inline form and selects it, without leaving the editor.
    func createBin(using service: CoreItemService) {
        let label = newBinLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        do {
            let bin = try service.createBin(label: label, locationNote: newBinLocationNote)
            draft.binIdentifier = bin.id
            isAddingBin = false
            newBinLabel = ""
            newBinLocationNote = ""
            noticeMessage = "Added bin " + bin.displayName + "."
            revalidateIfNeeded()
        } catch {
            errorMessage = CoreEditorModel.presentable(error)
        }
    }

    /// Abandons the inline bin form.
    func cancelBinCreation() {
        isAddingBin = false
        newBinLabel = ""
        newBinLocationNote = ""
    }

    // MARK: - Saving

    /// Validates and writes the draft.
    ///
    /// - Returns: `true` when the record is saved and the editor may close. `false` covers three
    ///   distinct outcomes, each of which leaves the editor open with something visible: validation
    ///   issues (see `firstInvalidField`), a free-limit block (see `paywallTrigger`), or a store
    ///   failure (see `errorMessage`). Input is never discarded.
    ///
    /// The free-tier gate applies to **creating** a record only, and only before the record exists.
    /// Editing — including editing a record this editor just created — is never gated.
    func save(using service: CoreItemService,
              vendor: Vendor?,
              bin: StorageBin?,
              tier: SubscriptionTier) -> Bool {
        hasAttemptedSave = true
        errorMessage = nil
        firstInvalidField = nil

        issues = CoreItemValidator.validate(draft, calendar: calendar)
        guard issues.isEmpty else {
            firstInvalidField = issues.first?.field
            return false
        }

        isSaving = true
        defer { isSaving = false }

        do {
            switch mode {
            case .create:
                if let existing = createdItem {
                    // A previous attempt already created the record; this is a retry.
                    try service.update(existing, from: draft, vendor: vendor, bin: bin)
                    try flushPendingPhotos(to: existing, using: service)
                } else {
                    let unresolved = try service.unresolvedCount()
                    if let trigger = EntitlementPolicy.blockingTrigger(unresolvedCount: unresolved,
                                                                      tier: tier) {
                        paywallTrigger = trigger
                        return false
                    }
                    let item = try service.createItem(from: draft, vendor: vendor, bin: bin)
                    createdItem = item
                    try flushPendingPhotos(to: item, using: service)
                }
            case .edit(let item):
                try service.update(item, from: draft, vendor: vendor, bin: bin)
            }
            return true
        } catch let error as DomainError {
            if case .validationFailed(let reported) = error {
                issues = reported
                firstInvalidField = reported.first?.field
            }
            errorMessage = CoreEditorModel.presentable(error)
            return false
        } catch {
            errorMessage = CoreEditorModel.presentable(error)
            return false
        }
    }

    // MARK: - Private

    /// Moves staged photos onto the saved record.
    ///
    /// Each attachment is removed from the queue only once it has actually been written, so a
    /// failure part-way through leaves exactly the un-attached ones behind and a retry finishes the
    /// job instead of duplicating it. The loop is bounded by the queue: every iteration either
    /// removes an element or throws.
    private func flushPendingPhotos(to item: CoreItem, using service: CoreItemService) throws {
        while let attachment = pendingPhotos.first {
            try service.addAttachment(attachment, to: item)
            pendingPhotos.removeFirst()
        }
    }

    /// Builds the editable draft for an existing record.
    ///
    /// Mirrors `CoreItemService.draft(for:)` deliberately: the editor needs the record's values on
    /// its very first frame, before a `ModelContext` has been read out of the environment, so the
    /// user never sees a blank form flash over their data.
    private static func makeDraft(for item: CoreItem) -> CoreItemDraft {
        CoreItemDraft(existingID: item.id,
                      partName: item.partName,
                      partNumber: item.partNumber,
                      vendorIdentifier: item.vendor?.id,
                      binIdentifier: item.bin?.id,
                      expectedCreditText: item.expectedCredit.plainDecimalString,
                      invoiceReference: item.invoiceReference,
                      repairOrderReference: item.repairOrderReference,
                      receivedDate: item.receivedDate,
                      usesCustomDueDate: item.usesCustomDueDate,
                      customDueDate: item.dueDate,
                      notes: item.notes,
                      // Carried so a payload recorded earlier is visible while editing — and can
                      // therefore be corrected. Left out, it would be invisible and unreachable.
                      scannedBarcodeValue: item.scannedBarcodeValue,
                      scannedBarcodeSymbology: item.scannedBarcodeSymbology)
    }

    /// A per-value key for image bytes, so `Route.readPhoto` re-presents when the photo changes.
    ///
    /// Byte count *and* a hash of the edges, because either alone is weaker than the pair. The
    /// edges rather than the whole image on purpose: `Route.id` is read on every body evaluation of
    /// the editor — that is once per keystroke while a photo route exists — and hashing half a
    /// megabyte of JPEG on each of those is work nobody asked for. Two different photos differ in
    /// length or in their first bytes essentially always, and the identifier only has to
    /// distinguish two routes inside one run: it is never stored, and never compared across
    /// launches.
    private static func identityKey(for data: Data) -> String {
        var hasher = Hasher()
        hasher.combine(data.count)
        for byte in data.prefix(identitySampleLength) {
            hasher.combine(byte)
        }
        if data.count > identitySampleLength {
            for byte in data.suffix(identitySampleLength) {
                hasher.combine(byte)
            }
        }
        return String(data.count) + "-" + String(UInt(bitPattern: hasher.finalize()))
    }

    /// How many bytes are sampled from each end of an image for `identityKey(for:)`.
    private static let identitySampleLength = 64

    /// Prefers an error's own sentence — and its recovery suggestion — over a Cocoa domain and code.
    private static func presentable(_ error: any Error) -> String {
        guard let localized = error as? any LocalizedError else {
            return error.localizedDescription
        }
        let description = localized.errorDescription ?? localized.localizedDescription
        guard let suggestion = localized.recoverySuggestion, !suggestion.isEmpty else {
            return description
        }
        return description + " " + suggestion
    }
}
