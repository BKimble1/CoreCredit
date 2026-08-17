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
