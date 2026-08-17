//
//  ScanMoneyParser.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//
//  ## Why this is stricter than `Money.parse`
//
//  `Money.parse` reads what a *person typed*, and a person who types `1.234` into the amount field
//  is standing there and can see the result. This parser reads what a *camera thought it saw*, and
//  nobody is watching. So where `Money.parse` resolves an ambiguity with a sensible rule, this
//  parser refuses and says why: a wrong core charge is a wrong number in a shop's ledger, and
//  "type it in" is always an acceptable outcome.
//
//  Every accepted value still goes through `Money.parse` / `Decimal`. There is no `Double` and no
//  `Float` anywhere on this path — `86.50` becomes exactly `8650`, never `8649.999999`.
//

import Foundation

/// Why a money-shaped token was refused. Each case has a sentence written for a technician.
enum ScanMoneyRejection: String, Equatable, Sendable {

    /// Not money at all: empty, letters, a code like `12-34`, or stray punctuation.
    case notMoney

    /// The separator could be a decimal point or a thousands separator and nothing in the token
    /// settles it.
    case ambiguousSeparator

    /// More precision than cents. An invoice amount has two fraction digits.
    case tooManyFractionDigits

    /// Larger than any plausible core charge (over $999,999.99), so it is a misread or a total.
    case outOfRange

    var explanation: String {
        switch self {
        case .notMoney:
            return "That doesn't read as an amount. Type the core charge in instead."
        case .ambiguousSeparator:
            return "That amount could be read two ways. Type it in so there's no doubt."
        case .tooManyFractionDigits:
            return "That amount has more than cents in it. Type it in instead."
        case .outOfRange:
            return "That's too large to be a core charge. Type it in instead."
        }
    }
}

enum ScanMoneyParser {

    // MARK: - Decision table
    //
    // `S` is the single separator character in the token, `n` the number of digits after it, and
    // `D` the locale's decimal separator. `$` means a currency symbol was present anywhere in the
    // token. Rows are evaluated top to bottom.
    //
    // | token                | shape                       | locale       | result                    |
    // |----------------------|-----------------------------|--------------|---------------------------|
    // | ""  / "  "           | empty                       | any          | .notMoney                 |
    // | "CORE"               | letters                     | any          | .notMoney                 |
    // | "12-34"              | `-` after a digit           | any          | .notMoney                 |
    // | "86."                | separator with no digits    | any          | .notMoney                 |
    // | "86"                 | no separator                | any          | 8600                      |
    // | "$1234"              | no separator                | any          | 123400                    |
    // | "86.50"              | n = 2, S == D               | en_US        | 8650                      |
    // | "86,50"              | n = 2, S == D               | de_DE        | 8650                      |
    // | "86,50"              | n = 2, S != D, no `$`       | en_US        | .ambiguousSeparator       |
    // | "$86,50"             | n = 2, S != D, `$`          | en_US        | 8650  (symbol settles it) |
    // | "86.5"               | n = 1, S == D               | en_US        | 8650                      |
    // | "1,234"              | n = 3, S != D, lead 1–3     | en_US        | 123400 (thousands group)  |
    // | "1.234"              | n = 3, S == D, last digit≠0 | en_US        | .ambiguousSeparator       |
    // | "$1.234"             | n = 3, S == D, last digit≠0 | en_US        | .ambiguousSeparator       |
    // | "86.500"             | n = 3, S == D, last digit 0 | en_US        | .tooManyFractionDigits    |
    // | "86.5000"            | n >= 4                      | any          | .tooManyFractionDigits    |
    // | "1,234.56"           | groups + 2 fraction digits  | any          | 123456                    |
    // | "1.234,56"           | groups + 2 fraction digits  | any          | 123456                    |
    // | "1,234.567"          | groups + 3 fraction digits  | any          | .tooManyFractionDigits    |
    // | "1.2,34"             | a group that isn't 3 digits | any          | .ambiguousSeparator       |
    // | "1,234,567.89"       | 123456789 cents             | any          | .outOfRange               |
    //
    // The `n = 3` split deserves a word, because it is the only judgement call in the table. Three
    // digits after a separator is never cents, so the token is either a thousands group or a
    // misread. When the separator is *not* the locale's decimal separator it can only be a group,
    // and the token is read as whole currency units. When it *is* the decimal separator both
    // readings are live — except in the one case where the third digit is `0`, which makes the
    // decimal reading collapse onto exactly two significant fraction digits (`86.500` == `86.50`).
    // That is over-precision rather than a genuine ambiguity, so it is reported as such.

    /// Fixed locale used for the final `Decimal` conversion. The canonical string this parser
    /// builds always uses `.`, so POSIX is the only correct locale to read it with.
    private static let parsingLocale = Locale(identifier: "en_US_POSIX")

    /// Largest accepted magnitude, mirroring `CoreItemValidator.maximumExpectedCreditCents`
    /// ($999,999.99). Anything bigger is a total, a VIN, or a misread.
    private static let maximumCents: Int64 = 99_999_999

    /// Integer digits (leading zeros removed) beyond this are refused before `Decimal` is asked to
    /// hold them. Nine digits is already three orders of magnitude past `maximumCents`.
    private static let maximumIntegerDigits = 9

    /// Exact `Int64` cents through `Money` / `Decimal`. Never constructs a `Double`.
    ///
    /// See the decision table above for the full behaviour, including which rejection each refused
    /// shape produces.
    static func parse(_ token: String, locale: Locale) -> Result<Money, ScanMoneyRejection> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notMoney) }

        var digitsAndSeparators = ""
        var isNegative = false
        var sawDigit = false
        var sawCurrencySymbol = false

        for character in trimmed {
            if character.isWhitespace { continue }
            if character.isCurrencySymbol {
                sawCurrencySymbol = true
                continue
            }
            // A sign or a bracket is only a sign before the digits start. After them it is part of
            // a code — which is what makes `12-34` a rejection rather than `12` minus `34`.
            if character == "-" || character == "\u{2212}" {
                if sawDigit { return .failure(.notMoney) }
                isNegative = true
                continue
            }
            if character == "+" {
                if sawDigit { return .failure(.notMoney) }
                continue
            }
            if character == "(" {
                if sawDigit { return .failure(.notMoney) }
                isNegative = true
                continue
            }
            if character == ")" { continue }
            if character.isASCII, character.isNumber {
                digitsAndSeparators.append(character)
                sawDigit = true
                continue
            }
            if character == "." || character == "," {
                digitsAndSeparators.append(character)
                continue
            }
            return .failure(.notMoney)
        }

        guard sawDigit else { return .failure(.notMoney) }

        let characters = Array(digitsAndSeparators)
        let separatorPositions = characters.indices.filter { characters[$0] == "." || characters[$0] == "," }
        let localeDecimalSeparator: Character = (locale.decimalSeparator ?? ".").first ?? "."

        let split: SeparatorReading
        switch separatorPositions.count {
        case 0:
            split = .success(integerDigits: digitsAndSeparators, fractionDigits: "")
        case 1:
            split = readSingleSeparator(characters,
                                        position: separatorPositions[0],
                                        localeDecimalSeparator: localeDecimalSeparator,
                                        sawCurrencySymbol: sawCurrencySymbol)
        default:
            split = readGroupedNumber(characters, separatorPositions: separatorPositions)
        }

        switch split {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let integerDigits, let fractionDigits):
            return money(integerDigits: integerDigits,
                         fractionDigits: fractionDigits,
                         isNegative: isNegative)
        }
    }

    /// Money-shaped substrings of `line`, in reading order. **Does not parse them** — feed each one
    /// to `parse(_:locale:)` to find out whether it is really money and, if not, why not.
    ///
    /// A bare run of digits is not money-shaped: on an invoice that is a quantity, a year, or a
    /// line number far more often than it is an amount. A token qualifies when it carries a
    /// currency symbol or a decimal/grouping separator.
    static func moneyTokens(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: moneyTokenPattern, options: []) else {
            return []
        }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        var tokens: [String] = []
        for match in regex.matches(in: line, options: [], range: fullRange) {
            guard let tokenRange = Range(match.range, in: line) else { continue }
            tokens.append(String(line[tokenRange]))
        }
        return tokens
    }

    // MARK: - Private

    /// Matches a money-shaped run.
    ///
    /// The look-behind stops a match from starting in the middle of a code, so `03-1887.50`
    /// contributes nothing; the look-ahead stops a match from ending in the middle of a longer
    /// number. Up to three fraction digits are captured deliberately: `parse` needs to *see*
    /// `86.500` in order to reject it as over-precise, and a pattern that stopped at two digits
    /// would silently hand back `86.50`.
    private static let moneyTokenPattern =
        "(?<![0-9A-Za-z.,-])"
        + "(?:"
        + "[$€£¥]\\s*(?:[0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]+)(?:[.,][0-9]{1,3})?"
        + "|"
        + "(?:[0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]+)[.,][0-9]{1,3}"
        + ")"
        + "(?![0-9])"

    /// Outcome of splitting a token into integer and fraction digits.
    private enum SeparatorReading {
        case success(integerDigits: String, fractionDigits: String)
        case failure(ScanMoneyRejection)
    }

    /// Handles a token with exactly one `.` or `,` in it. See the decision table.
    private static func readSingleSeparator(_ characters: [Character],
                                            position: Int,
                                            localeDecimalSeparator: Character,
                                            sawCurrencySymbol: Bool) -> SeparatorReading {
        let separator = characters[position]
        let leading = String(characters[0..<position])
        let trailing = String(characters[(position + 1)...])
        guard !leading.isEmpty, !trailing.isEmpty else { return .failure(.notMoney) }

        let isLocaleDecimal = separator == localeDecimalSeparator

        switch trailing.count {
        case 1, 2:
            // One or two digits cannot be a thousands group, so the separator is a decimal point —
            // provided the locale agrees, or a currency symbol says the token is money regardless.
            guard isLocaleDecimal || sawCurrencySymbol else { return .failure(.ambiguousSeparator) }
            return .success(integerDigits: leading, fractionDigits: trailing)
        case 3:
            if !isLocaleDecimal {
                // The locale's decimal separator is the other character, so this one groups.
                guard leading.count <= 3 else { return .failure(.ambiguousSeparator) }
                return .success(integerDigits: leading + trailing, fractionDigits: "")
            }
            // Three fraction digits ending in zero is over-precision, not an ambiguity:
            // `86.500` and `86.50` are the same amount, so the decimal reading is the only
            // coherent one and the token is simply written with a digit too many.
            if trailing.hasSuffix("0") { return .failure(.tooManyFractionDigits) }
            return .failure(.ambiguousSeparator)
        default:
            return .failure(.tooManyFractionDigits)
        }
    }

    /// Handles a token with two or more separators. The **last** one is the decimal separator and
    /// every earlier one must be a well-formed thousands group written with the other character.
    private static func readGroupedNumber(_ characters: [Character],
                                          separatorPositions: [Int]) -> SeparatorReading {
        guard let decimalPosition = separatorPositions.last,
              let firstPosition = separatorPositions.first else {
            return .failure(.notMoney)
        }
        let decimalSeparator = characters[decimalPosition]

        // A grouped number starts with one to three digits: `1,234.56`, `123,456.78`.
        guard firstPosition >= 1, firstPosition <= 3 else { return .failure(.ambiguousSeparator) }

        for position in separatorPositions.dropLast() {
            // Mixing the same character for grouping and for the decimal point (`12.34.56`) is not
            // a number this parser is willing to interpret.
            guard characters[position] != decimalSeparator else { return .failure(.ambiguousSeparator) }
            let nextPosition = separatorPositions.first(where: { $0 > position }) ?? characters.count
            guard nextPosition - position - 1 == 3 else { return .failure(.ambiguousSeparator) }
        }

        let trailing = String(characters[(decimalPosition + 1)...])
        guard !trailing.isEmpty else { return .failure(.notMoney) }
        guard trailing.count <= 2 else { return .failure(.tooManyFractionDigits) }

        let integerDigits: String = String(characters[0..<decimalPosition])
            .filter { $0 != "." && $0 != "," }
        return .success(integerDigits: integerDigits, fractionDigits: trailing)
    }

    /// Builds the final `Money` from digit strings, entirely through `Decimal`.
    private static func money(integerDigits: String,
                              fractionDigits: String,
                              isNegative: Bool) -> Result<Money, ScanMoneyRejection> {
        let significantIntegerDigits = String(integerDigits.drop(while: { $0 == "0" }))
        guard significantIntegerDigits.count <= maximumIntegerDigits else {
            return .failure(.outOfRange)
        }

        let canonicalInteger = significantIntegerDigits.isEmpty ? "0" : significantIntegerDigits
        let canonicalFraction = fractionDigits.isEmpty ? "0" : fractionDigits
        let canonical = canonicalInteger + "." + canonicalFraction

        guard let parsed = Money.parse(canonical, locale: parsingLocale) else {
            return .failure(.notMoney)
        }
        // `canonical` carries no sign, so `parsed.cents` is never negative here; the sign is
        // re-applied below, which keeps the range check on a single, positive magnitude.
        // The failure case is spelled out in full here. In this one guard the two `Int64`
        // comparisons and the `else` branch are solved in a single constraint system, and the
        // leading-dot `.failure(.outOfRange)` needs *two* levels of inference at once — Xcode 26.4
        // gives up with "cannot infer contextual base in reference to member 'outOfRange'".
        // Naming the Result type removes the ambiguity without changing behaviour.
        guard parsed.cents >= 0, parsed.cents <= maximumCents else {
            return Result<Money, ScanMoneyRejection>.failure(.outOfRange)
        }

        if isNegative { return .success(Money(cents: -parsed.cents)) }
        return .success(parsed)
    }
}
