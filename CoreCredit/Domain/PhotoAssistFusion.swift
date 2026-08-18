//
//  PhotoAssistFusion.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — no Vision, no ARKit, no SwiftUI, no SwiftData.
//
//  ## What this file is for
//
//  AI Photo Assist hands the user's photographs to recognisers that already exist: the same text
//  recogniser the document scanner uses, the same barcode classifier the live scanner uses, and one
//  new thing — Apple's general image classifier looking at the part itself. Each of those produces
//  `ScanCandidate`s for *one* image, using rules that were written, argued over, and tested long
//  before this feature existed. None of that is reimplemented here.
//
//  What is new is the word **across**. Six photographs of the same core produce six independent
//  opinions, and somebody has to decide what to do when two of them disagree, when three of them
//  agree, and when the only thing supporting a value is a photograph of a lump of metal. That
//  decision is this file, and it is deliberately pure: no clock, no randomness, no I/O. The same
//  observations in the same order always fuse to the same result, which is the only reason the
//  rules below can be tested at all.
//
//  ## The four rules that matter
//
//  1. **A photograph of a part cannot know a number.** Image classification may support
//     `.partName` and nothing else. Not a part number, not a vendor, not a reference, and above all
//     not an amount of money. This is enforced here rather than trusted, because the classifier
//     itself has no idea what it is not allowed to say.
//  2. **Money is never pre-ticked.** A core charge read off a photograph is capped below the
//     pre-selection threshold no matter how clean the OCR was. A wrong number that nobody looked at
//     is the single most expensive mistake this app can make, and the cost lands on a shop.
//  3. **Disagreement is shown, not resolved.** When two photographs read the same field
//     differently, both survive, both are capped below pre-selection, and each one's reason names
//     the other. Silently picking the higher score would be the app inventing a fact.
//  4. **Corroboration is reported, never rewarded.** A value found in three photographs says so in
//     its reason. It does not get a higher score for it. Scores come from the recognisers, which
//     looked at pixels; agreement between photographs of the same label mostly means the label was
//     legible twice.
//

import Foundation

/// What a photograph is *of*, as the user was asked to take it.
///
/// Only ever a hint. The pipeline reads whatever is actually in the image — a part number found on
/// a photo tagged `.part` is still a part number — but the hint lets the capture screen tell
/// somebody what is still missing, which is most of the difference between four useful photographs
/// and four photographs of the same angle.
enum PhotoAssistShot: String, CaseIterable, Codable, Sendable, Identifiable {

    /// The core itself, out of the box, filling the frame.
    case part

    /// The parts label, the box, or a printed tag — where the numbers actually live.
    case label

    /// The vendor's invoice or receipt — where the core charge actually lives.
    case invoice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .part: return "Part"
        case .label: return "Label or box"
        case .invoice: return "Invoice or receipt"
        }
    }

    /// One line under the thumbnail. Written for somebody holding a greasy alternator.
    var guidance: String {
        switch self {
        case .part:
            return "The core itself, filling the frame."
        case .label:
            return "Any printed label, sticker, or box panel."
        case .invoice:
            return "The line showing the core charge."
        }
    }

    var symbolName: String {
        switch self {
        case .part: return "shippingbox"
        case .label: return "barcode.viewfinder"
        case .invoice: return "doc.text"
        }
    }
}

/// One candidate, plus which photograph produced it.
///
/// `ScanCandidate` already carries `page`, which multi-page document scans use as a page index.
/// A photo session reuses it as the image index, so the review sheet's existing "which page was
/// this?" plumbing works unchanged for "which photo was this?".
struct PhotoAssistObservation: Equatable, Sendable {

    /// Zero-based index of the image in the session, in the order the user arranged them.
    var imageIndex: Int

    /// What the user said the photograph was of, when they said anything.
    var shot: PhotoAssistShot?

    var candidate: ScanCandidate

    init(imageIndex: Int, shot: PhotoAssistShot? = nil, candidate: ScanCandidate) {
        self.imageIndex = imageIndex
        self.shot = shot
        self.candidate = candidate
    }
}

/// Everything the review sheet needs, and everything the capture screen needs to decide whether to
/// apologise.
struct PhotoAssistFusionResult: Equatable, Sendable {

    /// Fused candidates, deterministically ordered: declaration order of the kind, then strongest
    /// first, then alphabetical. Ready to hand to the existing review sheet unchanged.
    var candidates: [ScanCandidate]

    /// Kinds where two photographs disagreed. Every candidate of these kinds is capped below
    /// pre-selection and says so in its reason.
    var conflictedKinds: [ScanCandidateKind]

    /// Whether anything actually identified the part: a barcode, or a part number, at medium
    /// confidence or better.
    ///
    /// When this is `false` the capture screen says so plainly instead of presenting a review sheet
    /// full of shrugs. A part name guessed from a photograph does not count — "it looks like an
    /// alternator" is not an identification, and treating it as one is exactly the fake precision
    /// this feature is not allowed to have.
    var hasConfidentIdentification: Bool

    static let empty = PhotoAssistFusionResult(candidates: [],
                                               conflictedKinds: [],
                                               hasConfidentIdentification: false)
}

/// Fuses per-image candidates into one reviewable set.
enum PhotoAssistFusion {

    /// The most photographs one session will analyse.
    ///
    /// Not a performance limit so much as a usefulness limit: past about six, people photograph the
    /// same angle again rather than the thing that was missing, and every extra image is another
    /// full Vision pass on a phone that may be holding the part in the other hand.
    static let maximumImages = 6

    /// The highest score a candidate may carry and still be barred from starting ticked.
    ///
    /// `ScanConfidenceBand` calls anything from `0.80` up `.high`, and `.high` is what
    /// `ScanCandidate.isSafeToPreselect` reads. Capping to just under that boundary is how this
    /// layer says "show it, explain it, but make somebody actually decide" without inventing a
    /// second selection mechanism the review sheet would have to learn.
    static let reviewRequiredCeiling = 0.79

    /// Kinds where two different values mean somebody has to choose.
    ///
    /// `.barcode` is absent on purpose: a part carries one symbol and its box carries another, and
    /// both being present is ordinary rather than contradictory. `.date` and `.unknown` are absent
    /// because they are informational and plural by nature.
    static let singleValuedKinds: Set<ScanCandidateKind> = [
        .partNumber, .partName, .vendorName, .coreAmount,
        .invoiceNumber, .repairOrder, .returnReference,
    ]

    /// Fuse observations from every image in a session.
    ///
    /// Deterministic in the strict sense: no clock, no randomness, no dictionary iteration order
    /// leaking into the output.
    static func fuse(_ observations: [PhotoAssistObservation]) -> PhotoAssistFusionResult {
        let admissible = observations.filter { isAdmissible($0.candidate) }
        guard admissible.isEmpty == false else { return .empty }

        // 1. Collapse repeats. Two photographs of the same label produce the same value twice.
        var groups: [GroupKey: [PhotoAssistObservation]] = [:]
        var order: [GroupKey] = []
        for observation in admissible {
            let key = GroupKey(kind: observation.candidate.kind,
                               value: groupingValue(for: observation.candidate))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(observation)
        }

        // 2. One representative per distinct value, and a note of how many photos agreed.
        var merged: [(key: GroupKey, candidate: ScanCandidate, imageCount: Int)] = []
        for key in order {
            guard let members = groups[key], members.isEmpty == false else { continue }
            let best = members.min(by: strongerObservation)!
            let distinctImages = Set(members.map(\.imageIndex)).count
            merged.append((key, best.candidate, distinctImages))
        }

        // 3. Which kinds ended up with more than one surviving value.
        var valuesByKind: [ScanCandidateKind: Set<String>] = [:]
        for entry in merged {
            valuesByKind[entry.key.kind, default: []].insert(entry.key.value)
        }
        let conflicted = valuesByKind
            .filter { singleValuedKinds.contains($0.key) && $0.value.count > 1 }
            .map(\.key)

        // 4. Apply the caps and write the reasons.
        var output: [ScanCandidate] = []
        for entry in merged {
            var candidate = entry.candidate
            let isConflicted = conflicted.contains(entry.key.kind)

            if isConflicted {
                let others = merged
                    .filter { $0.key.kind == entry.key.kind && $0.key.value != entry.key.value }
                    .map { "\"" + $0.candidate.normalizedValue + "\"" }
                    .sorted()
                candidate.reason = appended(
                    to: candidate.reason,
                    "Another photo read this as " + others.joined(separator: " or ")
                        + " — pick the right one."
                )
            }

            if entry.imageCount > 1 {
                candidate.reason = appended(
                    to: candidate.reason,
                    "Read from " + String(entry.imageCount) + " photos."
                )
            }

            if candidate.kind == .coreAmount {
                candidate.reason = appended(
                    to: candidate.reason,
                    "Money is never ticked for you — check it against the invoice."
                )
            }

            let mustBeReviewed = isConflicted || candidate.kind == .coreAmount
            candidate.confidence = clamped(
                mustBeReviewed ? min(candidate.confidence, reviewRequiredCeiling)
                               : candidate.confidence
            )
            output.append(candidate)
        }

        // 5. Deterministic order for the review sheet.
        let kindOrder = Dictionary(
            uniqueKeysWithValues: ScanCandidateKind.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        output.sort { left, right in
            let leftKind = kindOrder[left.kind] ?? Int.max
            let rightKind = kindOrder[right.kind] ?? Int.max
            if leftKind != rightKind { return leftKind < rightKind }
            if left.confidence != right.confidence { return left.confidence > right.confidence }
            return left.normalizedValue < right.normalizedValue
        }

        return PhotoAssistFusionResult(
            candidates: output,
            conflictedKinds: conflicted.sorted { (kindOrder[$0] ?? 0) < (kindOrder[$1] ?? 0) },
            hasConfidentIdentification: identifies(output)
        )
    }

    // MARK: - Rules

    /// Image classification may support a part *name* and nothing else.
    ///
    /// Enforced here rather than in the classifier because the classifier has no notion of what a
    /// part number is: it returns "alternator" with a score and would return it just as happily if
    /// something upstream asked it to fill a money field. This is the wall.
    static func isAdmissible(_ candidate: ScanCandidate) -> Bool {
        guard candidate.normalizedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return false }

        if candidate.source == .imageClassification {
            return candidate.kind == .partName
        }
        return true
    }

    /// Whether anything in the set actually identifies the part.
    static func identifies(_ candidates: [ScanCandidate]) -> Bool {
        candidates.contains { candidate in
            (candidate.kind == .partNumber || candidate.kind == .barcode)
                && candidate.band != .low
        }
    }

    /// What the capture screen says when nothing identified the part.
    static let noConfidentMatchMessage =
        "Couldn't confidently identify this part. Add a label or invoice photo, or enter it manually."

    // MARK: - Private

    private struct GroupKey: Hashable {
        var kind: ScanCandidateKind
        var value: String
    }

    /// How two candidates are recognised as "the same value".
    ///
    /// Identifiers are compared exactly: `03-1887` and `031887` are genuinely different strings and
    /// this app has never been willing to guess which one the vendor prints. Prose — a part name, a
    /// vendor — is compared case- and whitespace-insensitively, because "NAPA" and "Napa" off two
    /// photographs of the same masthead are not a disagreement worth showing anybody.
    private static func groupingValue(for candidate: ScanCandidate) -> String {
        switch candidate.kind {
        case .partName, .vendorName, .unknown:
            return candidate.normalizedValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        case .partNumber, .barcode, .invoiceNumber, .repairOrder,
             .coreAmount, .date, .returnReference:
            return candidate.normalizedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Ranked so a symbol beats read text, and read text beats a guess from a photograph.
    ///
    /// This is rule 1 of the feature: barcode and exact OCR identifiers outrank visual
    /// classification, always, regardless of the scores each one happens to report. A classifier
    /// that is 0.9 sure it sees an alternator is not better evidence than a Code 128 symbol.
    private static func sourceRank(_ source: ScanSource) -> Int {
        switch source {
        case .liveBarcode, .photoBarcode: return 0
        case .documentOCR, .photoOCR, .liveText: return 1
        case .imageClassification: return 2
        }
    }

    /// Total ordering, strongest first. Every tiebreak is deterministic — the last one falls back to
    /// the image index so that two identical readings from two photographs always resolve the same
    /// way rather than however the array happened to be built.
    private static func strongerObservation(_ left: PhotoAssistObservation,
                                            _ right: PhotoAssistObservation) -> Bool {
        let leftRank = sourceRank(left.candidate.source)
        let rightRank = sourceRank(right.candidate.source)
        if leftRank != rightRank { return leftRank < rightRank }
        if left.candidate.confidence != right.candidate.confidence {
            return left.candidate.confidence > right.candidate.confidence
        }
        return left.imageIndex < right.imageIndex
    }

    private static func appended(to reason: String, _ sentence: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return sentence }
        if trimmed.contains(sentence) { return trimmed }
        let separator = trimmed.hasSuffix(".") ? " " : ". "
        return trimmed + separator + sentence
    }

    /// Mirrors `ScanCandidate`'s own clamping, which direct mutation bypasses.
    private static func clamped(_ score: Double) -> Double {
        if score.isNaN { return 0 }
        return min(max(score, 0), 1)
    }
}
