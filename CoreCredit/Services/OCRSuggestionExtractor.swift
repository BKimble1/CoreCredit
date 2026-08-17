//
//  OCRSuggestionExtractor.swift
//  CoreCredit
//
//  Capture layer — turning recognised text into *suggestions*.
//
//  ## The rule this file exists to enforce
//
//  Vision is a suggestion engine and nothing more. Nothing here writes to a record, and nothing
//  here is ever "confident enough to just apply". Every value produced lands in an editable
//  confirmation field, and a person taps Save. A misread `8` for a `3` in a core charge is a
//  money error in someone's ledger, so the human stays in the loop by construction.
//
//  ## How to read the heuristics
//
//  Everything below is deliberately boring, deterministic, and pure Foundation: same input, same
//  output, no locale drift, no clock, no I/O. Amounts are parsed with a fixed POSIX locale so a
//  device set to German and a device set to English extract the same number from the same photo.
//  Each rule carries a comment saying *why* it fires, because the only way to debug "the app
//  suggested a weird part number" months from now is to be able to read the rule that produced it.
//

import Foundation

/// Extracts editable field suggestions from recognised text lines.
///
/// Pure and side-effect free, so it can be unit-tested with hand-written line arrays — no images,
/// no Vision, no camera.
enum OCRSuggestionExtractor {

    // MARK: - Public entry points

    /// At most one suggestion per `OCRField`, ordered by `OCRField.allCases`.
    ///
    /// Extraction order matters: invoice and repair-order references are resolved first, because
    /// the part-number heuristic explicitly refuses to re-suggest a token that has already been
    /// claimed as a reference. Without that, `INV-55219` would show up as both.
    static func suggestions(from lines: [String]) -> [OCRFieldSuggestion] {
        let cleanedLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedLines.isEmpty else { return [] }

        var claimedValues: Set<String> = []
        var results: [OCRField: OCRFieldSuggestion] = [:]

        // 1. Invoice reference — "INV-55219", "Invoice #55219", "INVOICE: 55219".
        if let invoice = rankedReferences(from: cleanedLines, prefixes: invoicePrefixes).first {
            claimedValues.insert(invoice.value.uppercased())
            results[.invoiceReference] = OCRFieldSuggestion(
                field: .invoiceReference,
                value: invoice.value,
                confidence: confidence(for: invoice)
            )
        }

        // 2. Repair-order reference. A value already claimed as the invoice is skipped rather than
        //    duplicated: one number cannot be both, and the invoice label is the more specific of
        //    the two on a parts invoice.
        let repairOrders = rankedReferences(from: cleanedLines, prefixes: repairOrderPrefixes)
        if let repairOrder = repairOrders.first(where: { !claimedValues.contains($0.value.uppercased()) }) {
            claimedValues.insert(repairOrder.value.uppercased())
            results[.repairOrderReference] = OCRFieldSuggestion(
                field: .repairOrderReference,
                value: repairOrder.value,
                confidence: confidence(for: repairOrder)
            )
        }

        // 3. Core charge. `plainDecimalString` is used as the value so it drops straight into the
        //    editor's amount field and re-parses identically in any locale.
        if let amount = rankedAmounts(from: cleanedLines).first {
            results[.amount] = OCRFieldSuggestion(
                field: .amount,
                value: amount.money.plainDecimalString,
                confidence: confidence(forAmountScore: amount.score)
            )
        }

        // 4. Part number, excluding anything already claimed above.
        if let part = rankedPartNumbers(from: cleanedLines, excluding: claimedValues).first {
            results[.partNumber] = OCRFieldSuggestion(
                field: .partNumber,
                value: part.value,
                confidence: confidence(forPartScore: part.score)
            )
        }

        // 5. Vendor name — the weakest guess of the five, and scored accordingly.
        if let vendor = bestVendorName(from: cleanedLines) {
            results[.vendorName] = OCRFieldSuggestion(
                field: .vendorName,
                value: vendor.value,
                confidence: vendor.confidence
            )
        }

        return OCRField.allCases.compactMap { results[$0] }
    }

    /// Every plausible money amount in the text, strongest candidate first.
    ///
    /// "Strongest" means *most likely to be the core charge*, not "largest". A line mentioning a
    /// core charge or a deposit outranks a bare amount, which in turn outranks anything on an
    /// invoice-total line — the grand total is the single most common wrong answer.
    ///
    /// Only positive amounts are returned. A leading `-` is treated as part of a code (`03-1887.50`)
    /// rather than as a negative amount, and the editor requires a positive core charge anyway.
    static func amountCandidates(from lines: [String]) -> [Money] {
        rankedAmounts(from: lines).map { $0.money }
    }

    /// Values that follow one of `prefixes`, in reading order.
    ///
    /// Handles the forms that actually appear on parts invoices: `INV-552`, `INV# 552`,
    /// `Invoice: 552`, `INV.552`, `R.O. 4471`, `RO#4471`. Matching is case-insensitive, and each
    /// prefix letter may be followed by a period, so `RO` also matches `R.O.`.
    ///
    /// A candidate must contain at least one digit and be 2–20 characters long. When no separator
    /// character sits between the label and the value, the value must *start* with a digit — that
    /// is what stops the prefix `REF` from harvesting `ERENCE` out of the word `REFERENCE`.
    static func referenceCandidates(from lines: [String], prefixes: [String]) -> [String] {
        rankedReferences(from: lines, prefixes: prefixes).map { $0.value }
    }

    // MARK: - Amounts

    /// One amount found in the text, with the evidence that supports it.
    private struct RankedAmount {
        let money: Money
        /// 1 (invoice-total line) … 4 (explicit core charge line). See `amountScore(for:)`.
        let score: Int
        let lineIndex: Int
        let characterOffset: Int
    }

    /// Matches a money token.
    ///
    /// Two shapes are accepted:
    /// 1. a currency symbol followed by digits, with the cents part optional (`$86`, `$1,234.56`);
    /// 2. bare digits that *must* carry a two-digit cents part (`86.50`, `1,234.56`, `86,50`).
    ///
    /// Requiring either a symbol or cents is what keeps quantities, years, and part numbers out.
    /// The leading look-behind blocks matches that start in the middle of a code, so `03-1887.50`
    /// does not contribute `1887.50`.
    private static let amountPattern =
        "(?<![-0-9A-Za-z])"
        + "(?:"
        + "[$€£¥]\\s*(?:[0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]+)(?:[.,][0-9]{2})?"
        + "|"
        + "(?:[0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]+)[.,][0-9]{2}"
        + ")"
        + "(?![0-9])"

    /// Fixed parsing locale. OCR text is machine print from a vendor's system, and unit tests must
    /// not change answer with the simulator's region setting. `Money.parse` still reads both
    /// `1,234.56` and `1.234,56` correctly under POSIX rules.
    private static let parsingLocale = Locale(identifier: "en_US_POSIX")

    /// Anything above this is not a core charge — it is a total, a VIN, or a misread.
    /// Mirrors `CoreItemValidator`'s ceiling of $999,999.99.
    private static let maximumPlausibleCents: Int64 = 99_999_999

    /// Phrases that mark a line as talking about the core itself.
    private static let strongAmountKeywords = ["core charge", "core deposit", "core dep", "core fee"]

    /// Weaker but still core-related wording.
    private static let amountKeywords = ["core", "deposit"]

    /// Wording that marks a line as an invoice summary rather than a line item.
    private static let totalKeywords = ["total", "subtotal", "balance", "amount due", "tax", "grand"]

    private static func rankedAmounts(from lines: [String]) -> [RankedAmount] {
        guard let regex = try? NSRegularExpression(pattern: amountPattern, options: []) else {
            return []
        }

        var found: [RankedAmount] = []
        for (lineIndex, line) in lines.enumerated() {
            let score = amountScore(for: line)
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, options: [], range: fullRange) {
                guard let tokenRange = Range(match.range, in: line) else { continue }
                let token = String(line[tokenRange])
                guard let money = Money.parse(token, locale: parsingLocale) else { continue }
                guard money.isPositive, money.cents <= maximumPlausibleCents else { continue }
                found.append(RankedAmount(money: money,
                                          score: score,
                                          lineIndex: lineIndex,
                                          characterOffset: match.range.location))
            }
        }

        // Deterministic ordering: strongest evidence first, then reading order. `sorted(by:)` is
        // not documented as stable, so every tie is broken explicitly.
        let ordered = found.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            if lhs.characterOffset != rhs.characterOffset { return lhs.characterOffset < rhs.characterOffset }
            return lhs.money.cents < rhs.money.cents
        }

        // The same amount printed twice (line item and summary) is one candidate.
        var seenCents: Set<Int64> = []
        return ordered.filter { seenCents.insert($0.money.cents).inserted }
    }

    /// Scores a line by how likely an amount on it is the core charge.
    /// 4 = says "core charge"/"core deposit"; 3 = mentions a core or a deposit;
    /// 2 = an ordinary line; 1 = an invoice-total line, which is almost never the right answer.
    private static func amountScore(for line: String) -> Int {
        let lowercased = line.lowercased()
        if strongAmountKeywords.contains(where: { lowercased.contains($0) }) { return 4 }
        if amountKeywords.contains(where: { lowercased.contains($0) }) { return 3 }
        if totalKeywords.contains(where: { lowercased.contains($0) }) { return 1 }
        return 2
    }

    private static func confidence(forAmountScore score: Int) -> Double {
        switch score {
        case 4: return 0.9
        case 3: return 0.75
        case 2: return 0.5
        default: return 0.3
        }
    }

    // MARK: - References (invoice / repair order)

    /// One reference found in the text, with the evidence that supports it.
    private struct RankedReference {
        let value: String
        /// The label that introduced it, e.g. `"INVOICE"`.
        let prefix: String
        /// `true` when a separator (`#`, `:`, `-`, space) sat between the label and the value.
        let hasExplicitSeparator: Bool
        let lineIndex: Int
    }

    /// Labels that introduce a vendor invoice number.
    private static let invoicePrefixes = ["INVOICE", "INV", "INVC", "BILL"]

    /// Labels that introduce the shop's own repair-order / work-order number.
    /// `R.O.` is covered by `RO` because each prefix letter may be followed by a period.
    private static let repairOrderPrefixes = ["REPAIR ORDER", "WORK ORDER", "ORDER", "TICKET", "RO", "WO"]

    private static func rankedReferences(from lines: [String], prefixes: [String]) -> [RankedReference] {
        // Longest label first, so `INVOICE 552` is read by `INVOICE` rather than by `INV`
        // (which would leave `OICE` behind). Ties keep the caller's order.
        let ordered = prefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .enumerated()
            .filter { !$0.element.isEmpty }
            .sorted { lhs, rhs in
                if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        // One regex per label, built once and reused across every line.
        let compiled: [(prefix: String, regex: NSRegularExpression)] = ordered.compactMap { label in
            guard let regex = referenceRegex(forPrefix: label) else { return nil }
            return (prefix: label, regex: regex)
        }
        guard !compiled.isEmpty else { return [] }

        var results: [RankedReference] = []
        var seen: Set<String> = []

        for (lineIndex, line) in lines.enumerated() {
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for entry in compiled {
                for match in entry.regex.matches(in: line, options: [], range: fullRange) {
                    guard match.numberOfRanges >= 3 else { continue }
                    guard let separatorRange = Range(match.range(at: 1), in: line),
                          let valueRange = Range(match.range(at: 2), in: line) else { continue }

                    let separator = String(line[separatorRange])
                    let raw = String(line[valueRange])
                    guard let value = normalizedReference(raw) else { continue }

                    // Nothing at all between label and value means the label ran straight into the
                    // value. That is only credible when the value starts with a digit (`INV552`);
                    // otherwise the label is really just the first letters of a longer word
                    // (`REF` inside `REFERENCE`).
                    if separator.isEmpty {
                        guard let first = value.first, first.isNumber else { continue }
                    }
                    let hasSeparator = separator.contains(where: { !$0.isWhitespace })

                    guard seen.insert(value.uppercased()).inserted else { continue }
                    results.append(RankedReference(value: value,
                                                   prefix: entry.prefix,
                                                   hasExplicitSeparator: hasSeparator,
                                                   lineIndex: lineIndex))
                }
            }
        }

        return results
    }

    /// Builds the matcher for one label.
    ///
    /// Each letter may be followed by a period, and the letters may be separated by whitespace, so
    /// a single `RO` entry matches `RO`, `R.O.`, and `R O`. The trailing whitespace is deliberately
    /// left for group 1 to capture, so the "no separator at all" test below stays meaningful.
    /// Group 1 captures the separator run, group 2 the value.
    private static func referenceRegex(forPrefix prefix: String) -> NSRegularExpression? {
        var pieces: [String] = []
        for character in prefix where !character.isWhitespace {
            pieces.append(NSRegularExpression.escapedPattern(for: String(character)) + "\\.?")
        }
        guard !pieces.isEmpty else { return nil }

        var pattern = "(?<![A-Za-z0-9])"
        pattern += pieces.joined(separator: "\\s*")
        pattern += "([:#\\-–—.\\s]*)"
        pattern += "([A-Za-z0-9][A-Za-z0-9\\-/]{0,19})"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Trims stray punctuation and applies the shared shape rules for a reference value.
    private static func normalizedReference(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-/.,:;#"))
        guard trimmed.count >= 2, trimmed.count <= 20 else { return nil }
        // A reference without a digit is a word, not a number.
        guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        return trimmed
    }

    /// A longer, more specific label is stronger evidence than a two-letter one, and an explicit
    /// separator is stronger than none. Capped below 1 — this is a guess, never a certainty.
    private static func confidence(for reference: RankedReference) -> Double {
        var score = 0.6
        if reference.prefix.count >= 5 { score += 0.2 } else { score += 0.1 }
        if reference.hasExplicitSeparator { score += 0.05 }
        if reference.lineIndex < 5 { score += 0.05 }
        return min(score, 0.95)
    }

    // MARK: - Part numbers

    private struct RankedPartNumber {
        let value: String
        /// 2 … 5. See `rankedPartNumbers(from:excluding:)`.
        let score: Int
        let lineIndex: Int
    }

    /// Wording that means the line is naming a part.
    private static let partContextKeywords = ["part", "p/n", "pn ", "part no", "part #", "core"]

    /// Matches a date, which is the most common false positive for a hyphenated part number.
    private static let datePattern = "^[0-9]{1,4}[-/][0-9]{1,2}[-/][0-9]{2,4}$"

    /// Part-number candidates, strongest first.
    ///
    /// Shape rules, in order of strength:
    /// - **strong (3)** — the token contains a hyphen *and* a digit, e.g. `03-1887`. This is what
    ///   a parts catalogue number looks like.
    /// - **medium (2)** — the token mixes letters and digits, e.g. `A1234B`.
    ///
    /// Plus a **+2 context bonus** when the line mentions a part or a core.
    ///
    /// Tokens that are all digits are deliberately *not* candidates: on an invoice they are far
    /// more often a quantity, a price, a phone number, or a date fragment. Dates, amounts, and
    /// anything already claimed as an invoice/RO reference are excluded outright.
    private static func rankedPartNumbers(from lines: [String],
                                          excluding claimed: Set<String>) -> [RankedPartNumber] {
        let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [])
        var found: [RankedPartNumber] = []
        var seen: Set<String> = []

        for (lineIndex, line) in lines.enumerated() {
            let lowercasedLine = line.lowercased()
            let hasContext = partContextKeywords.contains(where: { lowercasedLine.contains($0) })

            for rawToken in line.split(whereSeparator: { $0.isWhitespace }) {
                let token = String(rawToken).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;#()[]\"'"))
                guard token.count >= 4, token.count <= 20 else { continue }
                guard !isClaimed(token, claimed: claimed) else { continue }
                guard token.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
                guard !containsCurrencyOrDecimal(token) else { continue }
                guard !isDateLike(token, regex: dateRegex) else { continue }

                let hasHyphen = token.contains("-")
                let hasLetter = token.contains(where: { $0.isLetter })
                let baseScore: Int
                if hasHyphen {
                    baseScore = 3
                } else if hasLetter {
                    baseScore = 2
                } else {
                    continue        // all digits — too ambiguous to suggest
                }

                guard seen.insert(token.uppercased()).inserted else { continue }
                found.append(RankedPartNumber(value: token,
                                              score: baseScore + (hasContext ? 2 : 0),
                                              lineIndex: lineIndex))
            }
        }

        return found.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            return lhs.value < rhs.value
        }
    }

    /// `true` when a token is, or contains, a value already suggested as an invoice/RO reference.
    ///
    /// Containment matters as much as equality: the reference extractor reports `55219` out of
    /// `INV-55219`, and without the substring test the whole token would come back as a part
    /// number. Only claimed values of three characters or more are matched by containment, so a
    /// very short reference cannot swallow unrelated codes.
    private static func isClaimed(_ token: String, claimed: Set<String>) -> Bool {
        let uppercased = token.uppercased()
        if claimed.contains(uppercased) { return true }
        for value in claimed where value.count >= 3 {
            if uppercased.contains(value) { return true }
        }
        return false
    }

    /// `true` for tokens that are really money (`$86.50`, `86.50`) rather than a code.
    private static func containsCurrencyOrDecimal(_ token: String) -> Bool {
        if token.contains(where: { $0.isCurrencySymbol }) { return true }
        // A trailing ".dd" or ",dd" is the signature of an amount, not of a part number.
        let characters = Array(token)
        guard characters.count >= 3 else { return false }
        let separatorIndex = characters.count - 3
        let separator = characters[separatorIndex]
        guard separator == "." || separator == "," else { return false }
        return characters[(separatorIndex + 1)...].allSatisfy { $0.isNumber }
    }

    private static func isDateLike(_ token: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return regex.firstMatch(in: token, options: [], range: range) != nil
    }

    private static func confidence(forPartScore score: Int) -> Double {
        switch score {
        case 5: return 0.9
        case 4: return 0.75
        case 3: return 0.6
        default: return 0.45
        }
    }

    // MARK: - Vendor name

    private struct VendorGuess {
        let value: String
        let confidence: Double
    }

    /// How many lines from the top are considered part of the invoice header.
    private static let vendorHeaderLineCount = 6

    /// Single words that mean a header line is a form label rather than a vendor's name.
    ///
    /// Matched as **whole words**, which is the whole point: `PART` on its own is a column
    /// heading, while `AUTO PARTS` is half the vendor names in the trade. Substring matching here
    /// would throw away exactly the lines this heuristic exists to find.
    private static let vendorStopWords: Set<String> = [
        "invoice", "receipt", "statement", "customer", "date", "page", "part", "qty",
        "quantity", "description", "total", "subtotal", "tax", "remit", "terms", "account",
        "phone", "fax", "order", "core", "charge", "deposit", "amount", "price", "each"
    ]

    /// Multi-word form labels, matched as substrings.
    private static let vendorStopPhrases = [
        "bill to", "ship to", "sold to", "thank you", "remit to", "part no", "p/n"
    ]

    /// The vendor's name, if a header line looks like one.
    ///
    /// Vendors print their name in the first few lines, in capitals, with no digits in it — a
    /// street address, a phone number, or a form label all fail at least one of those tests. This
    /// is the weakest heuristic in the file, so its confidence stays low: the UI shows it as a
    /// hint next to the vendor picker, never as a selection.
    private static func bestVendorName(from lines: [String]) -> VendorGuess? {
        for (index, line) in lines.prefix(vendorHeaderLineCount).enumerated() {
            let candidate = line.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;#*-"))
            guard candidate.count >= 3, candidate.count <= 40 else { continue }
            guard candidate.rangeOfCharacter(from: .decimalDigits) == nil else { continue }

            let lowercased = candidate.lowercased()
            guard !vendorStopPhrases.contains(where: { lowercased.contains($0) }) else { continue }

            let words = lowercased.split(whereSeparator: { !$0.isLetter }).map(String.init)
            guard !words.contains(where: { vendorStopWords.contains($0) }) else { continue }

            let letters = candidate.filter { $0.isLetter }
            guard letters.count >= 3 else { continue }
            let uppercaseCount = letters.filter { $0.isUppercase }.count
            let uppercaseRatio = Double(uppercaseCount) / Double(letters.count)

            // Either it is shouting (the usual invoice masthead) or it is the very first line.
            guard uppercaseRatio >= 0.6 || index == 0 else { continue }

            let score = index == 0 ? 0.55 : 0.4
            return VendorGuess(value: candidate, confidence: score)
        }
        return nil
    }
}

// MARK: - Ranked scan candidates
//
// ## Why this is a second entry point rather than a rewrite
//
// `suggestions(from:)` answers a narrow question — "one best guess per editor field" — and its
// exact confidences and ordering are pinned by unit tests. The scan review sheet asks a broader
// one: "everything you saw, ranked, each with the reason you saw it, so a person can pick." The
// two answers need different shapes, so this extension adds the second alongside the first and
// reuses the same private scoring helpers wherever the answers agree.
//
// Two things are deliberately *not* shared:
//
// 1. **Amount scoring.** The scan path recognises a longer list of negative keywords (`freight`,
//    `shipping`, `handling`, `delivery`, `misc`, `environmental`, `disposal`, `fee`, `labor`,
//    `discount`) on top of the shared `total/subtotal/balance/amount due/tax/grand` group. Adding
//    those to `totalKeywords` would change what `suggestions(from:)` returns — a fixture with a
//    `LABOR 120.00` line would re-order — so `scanRankedAmounts(from:)` duplicates the minimum
//    loop and scores with its own table. The regex, the parsing locale, the plausibility ceiling
//    and `confidence(forAmountScore:)` are all still the shared ones.
// 2. **`core value`.** Recognised as a strong core label here only, for the same reason.
// 3. **The money parser.** Tokens on this path go through `ScanMoneyParser`, which rejects an
//    ambiguous separator (`$1.234`) instead of resolving it the way `Money.parse` does for text a
//    person typed while watching. `suggestions(from:)` keeps `Money.parse`, so nothing it returns
//    moves.
//
// Everything else — references, part numbers, the vendor guess, the date matcher — is the
// existing helper, called unchanged.

extension OCRSuggestionExtractor {

    /// Ranked candidates with reasons, highest confidence first.
    ///
    /// Ordering is fully deterministic. Ties on confidence are broken by, in order:
    /// proximity to a recognised label (only when both candidates carry a bounding box), then line
    /// index, then the normalized value, then the kind. Two runs over the same input always
    /// produce the same array.
    ///
    /// This function does not write anything and does not read a clock. It is a pure function from
    /// recognised lines to proposals.
    /// Letters and digits only, uppercased — `"INV-100200"` and `"INV 100200"` share a key.
    private static func alphanumericKey(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Drops a reference whose characters are already wholly contained in a higher-ranked
    /// reference from the **same** pass.
    ///
    /// A line reading `INVOICE INV-100200` matches the invoice prefixes twice: once as
    /// `INV-100200` (introduced by the word `INVOICE`) and again as `100200` (introduced by the
    /// `INV` sitting inside that very value). Both are the same number, so offering two rows
    /// makes the user choose between a value and its own tail.
    ///
    /// Deliberately scoped to one pass. Cross-kind collisions still use exact-match claiming,
    /// because an invoice `INV-1024` and a repair order `1024` on the same page are genuinely
    /// two different references and both deserve a row.
    private static func removingSubsumedReferences(_ references: [RankedReference]) -> [RankedReference] {
        var kept: [RankedReference] = []
        for reference in references {
            let key = alphanumericKey(reference.value)
            guard !key.isEmpty else { continue }
            let isSubsumed = kept.contains { existing in
                let existingKey = alphanumericKey(existing.value)
                return existingKey != key && existingKey.contains(key)
            }
            guard !isSubsumed else { continue }
            kept.append(reference)
        }
        return kept
    }

    static func candidates(from lines: [RecognizedLine], source: ScanSource) -> [ScanCandidate] {
        let contexts = scanLineContexts(from: lines)
        guard !contexts.isEmpty else { return [] }

        let texts = contexts.map { $0.text }
        let labelPositions = labelMidYValues(in: contexts)

        var scored: [ScoredScanCandidate] = []
        var claimedValues: Set<String> = []

        // 1. Invoice numbers. Resolved first, exactly as in `suggestions(from:)`, so a value the
        //    invoice label introduced cannot come back as a part number further down.
        for reference in removingSubsumedReferences(rankedReferences(from: texts, prefixes: invoicePrefixes)) {
            let key = reference.value.uppercased()
            guard claimedValues.insert(key).inserted else { continue }
            appendReference(reference,
                            kind: .invoiceNumber,
                            contexts: contexts,
                            labelPositions: labelPositions,
                            source: source,
                            into: &scored)
        }

        // 2. Repair orders, skipping anything already claimed as the invoice.
        for reference in removingSubsumedReferences(rankedReferences(from: texts, prefixes: repairOrderPrefixes)) {
            let key = reference.value.uppercased()
            guard claimedValues.insert(key).inserted else { continue }
            appendReference(reference,
                            kind: .repairOrder,
                            contexts: contexts,
                            labelPositions: labelPositions,
                            source: source,
                            into: &scored)
        }

        // 3. Return authorisations / RMAs.
        for reference in removingSubsumedReferences(rankedReferences(from: texts, prefixes: returnReferencePrefixes)) {
            let key = reference.value.uppercased()
            guard claimedValues.insert(key).inserted else { continue }
            appendReference(reference,
                            kind: .returnReference,
                            contexts: contexts,
                            labelPositions: labelPositions,
                            source: source,
                            into: &scored)
        }

        // 4. Amounts. `normalizedValue` is `plainDecimalString` so it drops straight into the
        //    editor's amount field and re-parses identically in any locale; `rawValue` keeps the
        //    token exactly as it was printed, currency symbol and all.
        for amount in scanRankedAmounts(from: texts) {
            guard let entry = scanCandidate(kind: .coreAmount,
                                            rawValue: amount.rawToken,
                                            normalizedValue: amount.money.plainDecimalString,
                                            confidence: confidence(forAmountScore: amount.score),
                                            reason: amountReason(for: amount),
                                            alternatives: [],
                                            lineIndex: amount.lineIndex,
                                            contexts: contexts,
                                            labelPositions: labelPositions,
                                            source: source) else { continue }
            scored.append(entry)
        }

        // 5. Part numbers, excluding every value already claimed as a reference.
        for part in rankedPartNumbers(from: texts, excluding: claimedValues) {
            let identifier = ScanTextNormalizer.normalizedIdentifier(part.value)
            guard !identifier.isEmpty else { continue }
            guard let entry = scanCandidate(kind: .partNumber,
                                            rawValue: part.value,
                                            normalizedValue: identifier,
                                            confidence: confidence(forPartScore: part.score),
                                            reason: partNumberReason(score: part.score, value: identifier),
                                            alternatives: ScanTextNormalizer.confusionAlternatives(for: identifier),
                                            lineIndex: part.lineIndex,
                                            contexts: contexts,
                                            labelPositions: labelPositions,
                                            source: source) else { continue }
            scored.append(entry)
        }

        // 6. Vendor name — the weakest guess, and scored accordingly by `bestVendorName`.
        if let vendor = bestVendorName(from: texts) {
            let lineIndex = vendorLineIndex(for: vendor.value, in: texts)
            let reason = lineIndex == 0
                ? "The first line of the page, printed like a vendor masthead"
                : "Near the top of the page, printed like a vendor masthead"
            if let entry = scanCandidate(kind: .vendorName,
                                         rawValue: vendor.value,
                                         normalizedValue: vendor.value,
                                         confidence: vendor.confidence,
                                         reason: reason,
                                         alternatives: [],
                                         lineIndex: lineIndex,
                                         contexts: contexts,
                                         labelPositions: labelPositions,
                                         source: source) {
                scored.append(entry)
            }
        }

        // 7. Dates. Informational only — `ScanCandidateKind.date` fills no field, because the
        //    received date comes from the app's own clock, never from a photo.
        for date in scanDateTokens(from: texts) {
            guard let entry = scanCandidate(kind: .date,
                                            rawValue: date.value,
                                            normalizedValue: date.value,
                                            confidence: dateConfidence,
                                            reason: "Reads as a date printed on the document",
                                            alternatives: [],
                                            lineIndex: date.lineIndex,
                                            contexts: contexts,
                                            labelPositions: labelPositions,
                                            source: source) else { continue }
            scored.append(entry)
        }

        return sortedCandidates(scored)
    }

    // MARK: - Line bookkeeping

    /// One recognised line, plus whatever geometry the recogniser supplied for it.
    private struct ScanLineContext {
        let text: String
        let boundingBox: ScanBoundingBox?
        let page: Int?
    }

    /// A candidate with the extra keys used to break ties. Only `candidate` escapes.
    private struct ScoredScanCandidate {
        let candidate: ScanCandidate
        let lineIndex: Int
        /// Vertical distance to the nearest label line, or `nil` when either side has no box.
        let labelProximity: Double?
    }

    /// Trims and drops blank lines, keeping geometry alongside each survivor.
    ///
    /// The returned array is what every helper below is indexed against, so a `lineIndex` coming
    /// back from `rankedReferences` / `rankedPartNumbers` / `scanRankedAmounts` addresses the same
    /// element here. Every lookup is still bounds-checked.
    private static func scanLineContexts(from lines: [RecognizedLine]) -> [ScanLineContext] {
        var contexts: [ScanLineContext] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            contexts.append(ScanLineContext(text: text,
                                            boundingBox: line.boundingBox,
                                            page: line.page))
        }
        return contexts
    }

    // MARK: - Label proximity

    /// The labels the ranking layer knows how to read, lowercased.
    ///
    /// Entries of four characters or more are matched as substrings, because that is how they
    /// appear in the wild (`PARTS`, `SUBTOTAL`). Entries of three or fewer are matched as whole
    /// words: `RO` as a substring would fire on `PRODUCT`, and a spurious label line drags the
    /// proximity tie-break in the wrong direction.
    private static let scanLabelPhrases = [
        "core charge", "core deposit", "core value", "part number", "invoice number",
        "repair order", "invoice", "return", "credit", "amount", "total", "core", "part",
        "rma", "p/n", "ro"
    ]

    /// `true` when the line reads like a label rather than a value.
    private static func isLabelLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        for phrase in scanLabelPhrases where phrase.count > 3 {
            if lowercased.contains(phrase) { return true }
        }
        let words = labelWords(in: lowercased)
        for phrase in scanLabelPhrases where phrase.count <= 3 {
            if words.contains(phrase) { return true }
        }
        return false
    }

    /// Splits on everything that is not a letter, a digit, or a slash, so `p/n` survives as one
    /// word and can be matched exactly.
    private static func labelWords(in lowercasedLine: String) -> [String] {
        lowercasedLine
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" })
            .map(String.init)
    }

    /// Vertical centres of every label line that has a bounding box.
    private static func labelMidYValues(in contexts: [ScanLineContext]) -> [Double] {
        var values: [Double] = []
        for context in contexts {
            guard let box = context.boundingBox else { continue }
            guard isLabelLine(context.text) else { continue }
            let midY = box.midY
            guard midY.isFinite else { continue }
            values.append(midY)
        }
        return values
    }

    /// Distance from this line to the nearest label line, or `nil` when geometry is unavailable on
    /// either side.
    ///
    /// A value printed on the same row as `CORE CHARGE` scores 0 and therefore wins any tie
    /// against an equally-scored amount from elsewhere on the page. Absent geometry the tie-break
    /// is simply skipped — it never *lowers* a candidate that has no box below one that does on
    /// score alone, because confidence is compared first.
    private static func labelProximity(for context: ScanLineContext,
                                       labelPositions: [Double]) -> Double? {
        guard let box = context.boundingBox else { return nil }
        let midY = box.midY
        guard midY.isFinite, !labelPositions.isEmpty else { return nil }

        var nearest: Double?
        for position in labelPositions {
            let distance = abs(midY - position)
            guard distance.isFinite else { continue }
            if let current = nearest {
                if distance < current { nearest = distance }
            } else {
                nearest = distance
            }
        }
        return nearest
    }

    // MARK: - Amounts, scan path

    /// One amount found by the scan path, with the evidence and the token that produced it.
    private struct ScanRankedAmount {
        let money: Money
        /// The token exactly as printed, e.g. `"$86.50"`.
        let rawToken: String
        /// 1 (negative keyword) … 4 (explicit core charge). See `scanAmountEvidence(for:)`.
        let score: Int
        /// The keyword that decided the score, for the `reason` sentence.
        let matchedKeyword: String?
        let lineIndex: Int
        let characterOffset: Int
    }

    private struct ScanAmountEvidence {
        let score: Int
        let keyword: String?
    }

    /// Phrases that mark a line as being about the core itself. Outranks everything, including the
    /// invoice total. `core value` is here and not in the shared `strongAmountKeywords`.
    private static let scanStrongCoreKeywords = [
        "core charge", "core deposit", "core value", "core dep", "core fee"
    ]

    /// Weaker but still core-related wording.
    private static let scanCoreKeywords = ["core", "deposit"]

    /// Wording that means an amount on this line is *not* the core credit. Matched as substrings,
    /// longest and most specific first so the `reason` names the better phrase.
    ///
    /// These amounts are still offered — a technician may have to pick one — but they score 1,
    /// which is `confidence(forAmountScore:)` 0.3, which bands `.low`. They can never start ticked.
    private static let scanNegativeAmountPhrases = [
        "grand total", "sub total", "subtotal", "amount due", "sales tax", "balance",
        "environmental", "shipping", "handling", "delivery", "discount", "freight",
        "disposal", "labour", "labor", "total"
    ]

    /// Short negative keywords, matched as whole words. `vat` as a substring fires inside
    /// `private`, and `fee` inside `coffee`; as words they behave.
    private static let scanNegativeAmountWords = ["tax", "vat", "gst", "fee", "fees", "misc"]

    /// Splits on everything that is not a letter, so `TAX 12.00` yields `["tax"]`.
    private static func letterWords(in lowercasedLine: String) -> [String] {
        lowercasedLine.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Scores a line by how likely an amount on it is the core charge, and records why.
    ///
    /// Core wording is tested before the negative list on purpose: a line reading
    /// `CORE CHARGE (NON-REFUNDABLE FEE)` is a core charge, not a fee.
    private static func scanAmountEvidence(for line: String) -> ScanAmountEvidence {
        let lowercased = line.lowercased()

        if let match = scanStrongCoreKeywords.first(where: { lowercased.contains($0) }) {
            return ScanAmountEvidence(score: 4, keyword: match)
        }
        if let match = scanCoreKeywords.first(where: { lowercased.contains($0) }) {
            return ScanAmountEvidence(score: 3, keyword: match)
        }
        if let match = scanNegativeAmountPhrases.first(where: { lowercased.contains($0) }) {
            return ScanAmountEvidence(score: 1, keyword: match)
        }
        let words = letterWords(in: lowercased)
        if let match = scanNegativeAmountWords.first(where: { words.contains($0) }) {
            return ScanAmountEvidence(score: 1, keyword: match)
        }
        return ScanAmountEvidence(score: 2, keyword: nil)
    }

    /// The scan path's amount finder.
    ///
    /// Deliberately a near-copy of `rankedAmounts(from:)`: it reuses that function's regex, its
    /// POSIX parsing locale and its plausibility ceiling, but scores with `scanAmountEvidence` and
    /// keeps the printed token so the review sheet can show what was actually on the page.
    /// Changing `rankedAmounts` instead would move `suggestions(from:)`, which is pinned.
    ///
    /// The one place the two genuinely disagree is the parser. `rankedAmounts` reads its tokens
    /// with `Money.parse`, which resolves an ambiguity with a rule; this path reads them with
    /// `ScanMoneyParser`, which refuses. `$1.234` cannot be told apart from a thousands group by
    /// anything on the page, and a camera's guess about a core charge ends up in someone's ledger,
    /// so every `.failure` — `.ambiguousSeparator`, `.tooManyFractionDigits`, `.outOfRange`,
    /// `.notMoney` — is dropped rather than banded low. Typing the amount in is always available.
    private static func scanRankedAmounts(from lines: [String]) -> [ScanRankedAmount] {
        guard let regex = try? NSRegularExpression(pattern: amountPattern, options: []) else {
            return []
        }

        var found: [ScanRankedAmount] = []
        for (lineIndex, line) in lines.enumerated() {
            let evidence = scanAmountEvidence(for: line)
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, options: [], range: fullRange) {
                guard let tokenRange = Range(match.range, in: line) else { continue }
                let token = String(line[tokenRange])
                guard case .success(let money) = ScanMoneyParser.parse(token,
                                                                       locale: parsingLocale) else {
                    continue
                }
                guard money.isPositive, money.cents <= maximumPlausibleCents else { continue }
                found.append(ScanRankedAmount(money: money,
                                              rawToken: token,
                                              score: evidence.score,
                                              matchedKeyword: evidence.keyword,
                                              lineIndex: lineIndex,
                                              characterOffset: match.range.location))
            }
        }

        // Strongest evidence first, then reading order. `sorted(by:)` is not documented as stable,
        // so every tie is broken explicitly.
        let ordered = found.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            if lhs.characterOffset != rhs.characterOffset {
                return lhs.characterOffset < rhs.characterOffset
            }
            return lhs.money.cents < rhs.money.cents
        }

        // The same amount printed twice (line item and summary) is one candidate, and the copy
        // that survives is the best-evidenced one because the array is already ordered.
        var seenCents: Set<Int64> = []
        return ordered.filter { seenCents.insert($0.money.cents).inserted }
    }

    /// The sentence shown under an amount row.
    private static func amountReason(for amount: ScanRankedAmount) -> String {
        switch amount.score {
        case 4:
            guard let keyword = amount.matchedKeyword else {
                return "On a line that names the core charge"
            }
            return "Follows the label \"\(keyword.uppercased())\""
        case 3:
            return "On a line that mentions a core or a deposit"
        case 1:
            guard let keyword = amount.matchedKeyword else {
                return "On a summary line, which is rarely the core charge"
            }
            return "On a \"\(keyword.uppercased())\" line, which is rarely the core charge"
        default:
            return "A money amount printed on the page"
        }
    }

    // MARK: - References, part numbers, vendor, dates

    /// Labels that introduce a vendor return authorisation.
    ///
    /// `CREDIT` is deliberately absent: as a prefix it would harvest the `86` out of
    /// `CREDIT 86.50` and offer it as a reference number.
    private static let returnReferencePrefixes = ["RETURN AUTHORIZATION", "RETURN", "RMA", "RGA"]

    /// Dates are informational, so they sit in the `.low` band and sort below everything else.
    private static let dateConfidence = 0.45

    private struct ScanDateToken {
        let value: String
        let lineIndex: Int
    }

    /// Builds and appends one reference candidate.
    private static func appendReference(_ reference: RankedReference,
                                        kind: ScanCandidateKind,
                                        contexts: [ScanLineContext],
                                        labelPositions: [Double],
                                        source: ScanSource,
                                        into scored: inout [ScoredScanCandidate]) {
        let identifier = ScanTextNormalizer.normalizedIdentifier(reference.value)
        guard !identifier.isEmpty else { return }
        guard let entry = scanCandidate(kind: kind,
                                        rawValue: reference.value,
                                        normalizedValue: identifier,
                                        confidence: confidence(for: reference),
                                        reason: "Follows the label \"\(reference.prefix)\"",
                                        alternatives: [],
                                        lineIndex: reference.lineIndex,
                                        contexts: contexts,
                                        labelPositions: labelPositions,
                                        source: source) else { return }
        scored.append(entry)
    }

    /// The sentence shown under a part-number row. `rankedPartNumbers` adds 2 to the shape score
    /// when the line mentions a part or a core, so a score of 4 or more means context was found.
    private static func partNumberReason(score: Int, value: String) -> String {
        let shape = value.contains("-")
            ? "Alphanumeric with a hyphen, typical of a part number"
            : "Mixes letters and digits, typical of a part number"
        if score >= 4 { return shape + ", on a line that names a part" }
        return shape
    }

    /// Finds which line `bestVendorName` picked, so the candidate can carry that line's geometry.
    /// Falls back to the first line, which is where the guess almost always comes from.
    private static func vendorLineIndex(for value: String, in texts: [String]) -> Int {
        let edgeCharacters = CharacterSet(charactersIn: " .,:;#*-")
        for (index, text) in texts.enumerated() {
            if text.trimmingCharacters(in: edgeCharacters) == value { return index }
        }
        return 0
    }

    /// Date-shaped tokens, in reading order, deduplicated by value.
    ///
    /// Uses the same `datePattern` that keeps dates *out* of the part-number heuristic, so the two
    /// can never disagree about what a date looks like.
    private static func scanDateTokens(from lines: [String]) -> [ScanDateToken] {
        guard let regex = try? NSRegularExpression(pattern: datePattern, options: []) else {
            return []
        }
        var results: [ScanDateToken] = []
        var seen: Set<String> = []

        for (lineIndex, line) in lines.enumerated() {
            for rawToken in line.split(whereSeparator: { $0.isWhitespace }) {
                let token = String(rawToken)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;#()[]\"'"))
                guard isDateLike(token, regex: regex) else { continue }
                guard seen.insert(token).inserted else { continue }
                results.append(ScanDateToken(value: token, lineIndex: lineIndex))
            }
        }
        return results
    }

    // MARK: - Assembly and ordering

    /// Builds one scored candidate, stamping it with the geometry of the line it came from.
    /// Returns `nil` when the line index does not address a real line, so a future change to any
    /// ranking helper degrades to "one fewer candidate" rather than to a crash.
    private static func scanCandidate(kind: ScanCandidateKind,
                                      rawValue: String,
                                      normalizedValue: String,
                                      confidence: Double,
                                      reason: String,
                                      alternatives: [String],
                                      lineIndex: Int,
                                      contexts: [ScanLineContext],
                                      labelPositions: [Double],
                                      source: ScanSource) -> ScoredScanCandidate? {
        guard contexts.indices.contains(lineIndex) else { return nil }
        let context = contexts[lineIndex]

        let candidate = ScanCandidate(kind: kind,
                                      rawValue: rawValue,
                                      normalizedValue: normalizedValue,
                                      confidence: confidence,
                                      source: source,
                                      reason: reason,
                                      page: context.page,
                                      boundingBox: context.boundingBox,
                                      alternatives: alternatives)

        return ScoredScanCandidate(candidate: candidate,
                                   lineIndex: lineIndex,
                                   labelProximity: labelProximity(for: context,
                                                                  labelPositions: labelPositions))
    }

    /// Highest confidence first, with every tie broken explicitly so the array is reproducible.
    private static func sortedCandidates(_ scored: [ScoredScanCandidate]) -> [ScanCandidate] {
        let ordered = scored.sorted { lhs, rhs in
            if lhs.candidate.confidence != rhs.candidate.confidence {
                return lhs.candidate.confidence > rhs.candidate.confidence
            }
            // Physical proximity to a label separates two equally-scored candidates. A candidate
            // with geometry beats one without, because "we can see it sits next to the label" is
            // more evidence than "we have no idea where it is".
            let leftProximity = lhs.labelProximity
            let rightProximity = rhs.labelProximity
            if let left = leftProximity, let right = rightProximity {
                if left != right { return left < right }
            } else if leftProximity != nil {
                return true
            } else if rightProximity != nil {
                return false
            }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            if lhs.candidate.normalizedValue != rhs.candidate.normalizedValue {
                return lhs.candidate.normalizedValue < rhs.candidate.normalizedValue
            }
            return lhs.candidate.kind.rawValue < rhs.candidate.kind.rawValue
        }
        return ordered.map { $0.candidate }
    }
}
