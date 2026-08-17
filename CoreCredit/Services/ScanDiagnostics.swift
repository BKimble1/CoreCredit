//
//  ScanDiagnostics.swift
//  CoreCredit
//
//  Capture layer — a local record of what the last scan actually saw.
//
//  ## Why a shop tool needs this
//
//  "It won't scan the labels at the Ford dealer" is not a bug report anybody can act on. What makes
//  it actionable is the payload the decoder produced, the symbology it came in under, whether the
//  app accepted or suppressed it, and the lines Vision read off the page. That is what this file
//  collects, on the device, for the owner to read on the Scanner Diagnostics screen and copy into
//  an email if they choose to.
//
//  ## The rules this file is bound by — all five are non-negotiable
//
//  1. **Local only. Nothing here is ever uploaded, anywhere.** There is no network call, no URL, no
//     analytics client, and no API key in this file, and none may be added. Diagnostics leave the
//     device only when the owner deliberately copies or shares the text themselves.
//  2. **Image bytes are never stored.** Not the frame, not a thumbnail, not a crop. Only text that
//     was already recognised. A photograph of a customer's invoice is not diagnostics data.
//  3. **Credentials and secrets are never recorded.** Nothing in this layer reads a keychain item, a
//     token, a receipt, or a subscription identifier, and no caller may hand one in.
//  4. **Only the most recent session is retained.** `begin(...)` replaces whatever was there. There
//     is no history, no log file, and nothing is written to disk by this type.
//  5. **`clear()` empties it.** One tap, and the record is gone.
//
//  Nothing is recorded before `begin(...)` is called, either: a recorder that has never begun a
//  session silently ignores every `record…` call. Collection is something a scanning session opts
//  into, not something that happens to be on.
//

import Foundation
import Observation

/// One symbol the scanner reported, and what the app decided to do with it.
struct ScanDiagnosticsBarcode: Codable, Equatable, Sendable, Identifiable {

    var id: UUID

    /// The payload as it was delivered to the scan gate, after control characters were stripped.
    var payload: String

    /// `VNBarcodeSymbology.rawValue`.
    var symbology: String

    /// `true` when the scan was acted on, `false` when it was suppressed as a duplicate or as a
    /// repeat inside the cooldown. The suppressed ones are the interesting half of the record.
    var accepted: Bool

    /// Why, in a sentence.
    var reason: String

    init(payload: String,
         symbology: String,
         accepted: Bool,
         reason: String,
         id: UUID = UUID()) {
        self.id = id
        self.payload = payload
        self.symbology = symbology
        self.accepted = accepted
        self.reason = reason
    }
}

/// One line of recognised text, as the recogniser reported it.
///
/// Deliberately carries no geometry: a bounding box is of no use to the owner reading the screen,
/// and the point of this record is what was *read*, not where it sat.
struct ScanDiagnosticsLine: Codable, Equatable, Sendable, Identifiable {

    var id: UUID
    var text: String

    /// The recogniser's own 0…1 confidence for the winning reading.
    var confidence: Double

    /// Zero-based page index for a multi-page document scan.
    var page: Int

    init(text: String, confidence: Double, page: Int, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.page = page
    }
}

/// One proposal the ranking layer produced, flattened for the report.
///
/// The band is recorded rather than the raw score, matching what the review sheet shows the user —
/// a diagnostics report that disagrees with the screen it describes is worse than no report.
struct ScanDiagnosticsCandidate: Codable, Equatable, Sendable, Identifiable {

    var id: UUID

    /// `ScanCandidateKind.rawValue`.
    var kind: String

    /// Exactly what was recognised.
    var rawValue: String

    /// The cleaned form the review sheet would have offered.
    var normalizedValue: String

    /// `ScanConfidenceBand.rawValue` — `low`, `medium`, or `high`.
    var band: String

    /// The justification the ranking layer wrote at the time.
    var reason: String

    /// `VNBarcodeSymbology.rawValue` when the candidate came from a symbol.
    var symbology: String?

    init(kind: String,
         rawValue: String,
         normalizedValue: String,
         band: String,
         reason: String,
         symbology: String? = nil,
         id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.rawValue = rawValue
        self.normalizedValue = normalizedValue
        self.band = band
        self.reason = reason
        self.symbology = symbology
    }
}

/// Everything collected during one scanning session.
struct ScanDiagnosticsSession: Codable, Equatable, Sendable {

    /// When the session began, from the injected clock.
    var startedAt: Date

    /// `ScanSource.rawValue`.
    var source: String

    /// The scanner availability at the moment the session began, as a stable token.
    var availability: String

    var barcodes: [ScanDiagnosticsBarcode]
    var lines: [ScanDiagnosticsLine]
    var candidates: [ScanDiagnosticsCandidate]

    /// Failure sentences reported by the capture path, in order.
    var failures: [String]

    /// Free-text notes the capture path added, in order.
    var notes: [String]

    init(startedAt: Date,
         source: String,
         availability: String,
         barcodes: [ScanDiagnosticsBarcode] = [],
         lines: [ScanDiagnosticsLine] = [],
         candidates: [ScanDiagnosticsCandidate] = [],
         failures: [String] = [],
         notes: [String] = []) {
        self.startedAt = startedAt
        self.source = source
        self.availability = availability
        self.barcodes = barcodes
        self.lines = lines
        self.candidates = candidates
        self.failures = failures
        self.notes = notes
    }

    /// `true` when the session began but nothing was ever recorded into it — which is itself the
    /// most useful diagnosis there is: the camera was open and the decoder produced nothing.
    var isEmpty: Bool {
        barcodes.isEmpty && lines.isEmpty && candidates.isEmpty && failures.isEmpty && notes.isEmpty
    }
}

/// Collects one scanning session's evidence, in memory, for the owner to read.
///
/// Main-actor isolated and `@Observable` so the diagnostics screen re-renders as a session runs.
/// Every rule in this file's header applies to every member below.
@MainActor
@Observable
final class ScanDiagnosticsRecorder {

    /// The clock. Injected, so the recorded timestamp is the same clock the rest of the app uses
    /// and a test can freeze it.
    private let dateProvider: any DateProvider

    /// The most recent session, or `nil` before the first `begin(...)` and after `clear()`.
    /// **Only one is ever retained** — starting a session discards the one before it.
    private(set) var session: ScanDiagnosticsSession?

    /// Ceiling on each collection inside a session.
    ///
    /// A scanner left running in a pocket can report thousands of decodes, and this record lives in
    /// memory. Past the ceiling the oldest entry is dropped, so the report stays bounded and always
    /// describes the most recent behaviour — which is the part anybody debugging is looking at.
    private static let maximumEntriesPerSection = 200

    /// Longest message kept. A truncated sentence is still diagnosable; an unbounded one handed in
    /// by a future caller is a memory leak with good intentions.
    private static let maximumMessageLength = 500

    init(dateProvider: any DateProvider) {
        self.dateProvider = dateProvider
    }

    // MARK: - Session lifetime

    /// Starts a fresh session, discarding the previous one.
    func begin(source: ScanSource, availability: ScannerAvailability) {
        session = ScanDiagnosticsSession(
            startedAt: dateProvider.now,
            source: source.rawValue,
            availability: ScanDiagnosticsRecorder.token(for: availability)
        )
    }

    /// Empties the record completely. Nothing survives this.
    func clear() {
        session = nil
    }

    // MARK: - Recording

    /// Records one reported symbol and the decision made about it.
    ///
    /// Suppressed scans matter as much as accepted ones: "the same code was reported 40 times and
    /// accepted once" is the difference between a scanner that is broken and one that is working
    /// exactly as designed.
    func recordBarcode(payload: String, symbology: String, accepted: Bool, reason: String) {
        guard var current = session else { return }
        let entry = ScanDiagnosticsBarcode(payload: ScanDiagnosticsRecorder.bounded(payload),
                                           symbology: ScanDiagnosticsRecorder.bounded(symbology),
                                           accepted: accepted,
                                           reason: ScanDiagnosticsRecorder.bounded(reason))
        current.barcodes = ScanDiagnosticsRecorder.appending(entry, to: current.barcodes)
        session = current
    }

    /// Records the recognised text of a page or a frame. Image bytes are not accepted here and
    /// never will be — this takes lines that have *already* been recognised.
    func recordLines(_ lines: [RecognizedLine]) {
        guard !lines.isEmpty else { return }
        guard var current = session else { return }

        var updated = current.lines
        for line in lines {
            let entry = ScanDiagnosticsLine(text: ScanDiagnosticsRecorder.bounded(line.text),
                                            confidence: line.confidence,
                                            page: line.page,
                                            id: line.id)
            updated = ScanDiagnosticsRecorder.appending(entry, to: updated)
        }
        current.lines = updated
        session = current
    }

    /// Records the ranked proposals shown to the user.
    func recordCandidates(_ candidates: [ScanCandidate]) {
        guard !candidates.isEmpty else { return }
        guard var current = session else { return }

        var updated = current.candidates
        for candidate in candidates {
            let entry = ScanDiagnosticsCandidate(
                kind: candidate.kind.rawValue,
                rawValue: ScanDiagnosticsRecorder.bounded(candidate.rawValue),
                normalizedValue: ScanDiagnosticsRecorder.bounded(candidate.normalizedValue),
                band: candidate.band.rawValue,
                reason: ScanDiagnosticsRecorder.bounded(candidate.reason),
                symbology: candidate.barcodeSymbology,
                id: candidate.id
            )
            updated = ScanDiagnosticsRecorder.appending(entry, to: updated)
        }
        current.candidates = updated
        session = current
    }

    /// Records a failure sentence — the same text the user was shown.
    func recordFailure(_ message: String) {
        let text = ScanDiagnosticsRecorder.bounded(message)
        guard !text.isEmpty else { return }
        guard var current = session else { return }
        current.failures = ScanDiagnosticsRecorder.appending(text, to: current.failures)
        session = current
    }

    /// Records an ordinary observation: "paused for review", "resumed", "fell back to manual entry".
    func note(_ message: String) {
        let text = ScanDiagnosticsRecorder.bounded(message)
        guard !text.isEmpty else { return }
        guard var current = session else { return }
        current.notes = ScanDiagnosticsRecorder.appending(text, to: current.notes)
        session = current
    }

    // MARK: - Report

    /// The session as pretty-printed JSON with ISO-8601 dates and sorted keys, or `nil` when there
    /// is no session.
    ///
    /// Sorted keys and a fixed date format are what make two reports comparable: an owner sending a
    /// before and an after should be able to diff them. Encoding cannot meaningfully fail for these
    /// types, but a failure returns `nil` rather than trapping — a diagnostics screen is the last
    /// place that should be able to take the app down.
    func jsonReport() -> String? {
        guard let session = session else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(session) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    /// A stable token for each availability state.
    ///
    /// Written out rather than derived, because it goes into a report an owner may quote back
    /// months later: it must not change when a case is renamed or a user-facing sentence is
    /// reworded. `ScannerAvailability.explanation` is prose for a technician; this is an identifier.
    private static func token(for availability: ScannerAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .simulator: return "simulator"
        case .unsupportedDevice: return "unsupportedDevice"
        case .cameraDenied: return "cameraDenied"
        case .cameraRestricted: return "cameraRestricted"
        case .cameraNotDetermined: return "cameraNotDetermined"
        }
    }

    /// Appends within the ceiling, dropping the oldest entry when full.
    private static func appending<Element>(_ element: Element, to collection: [Element]) -> [Element] {
        var updated = collection
        updated.append(element)
        if updated.count > maximumEntriesPerSection {
            updated.removeFirst(updated.count - maximumEntriesPerSection)
        }
        return updated
    }

    /// Trims the edges and caps the length. Never returns more than `maximumMessageLength`
    /// characters, so no single value can make the report unbounded.
    private static func bounded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumMessageLength else { return trimmed }
        return String(trimmed.prefix(maximumMessageLength))
    }
}
