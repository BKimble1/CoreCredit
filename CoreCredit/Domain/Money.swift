//
//  Money.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — no SwiftData, no SwiftUI, no UIKit.
//

import Foundation

/// A whole number of currency minor units (cents).
///
/// Money is deliberately **never** backed by `Double` or `Float`. Every conversion to or from a
/// human-readable string goes through `Decimal` / `NSDecimalNumber`, so a core charge of `$86.50`
/// is stored as exactly `8650` and can never drift by a fraction of a cent.
///
/// The type is currency-agnostic: the currency code is supplied at formatting time by the shop
/// profile, so the same value can be rendered as `$86.50` or `€86,50` without re-parsing.
struct Money: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {

    /// The signed amount in minor units (cents for USD).
    var cents: Int64

    init(cents: Int64) {
        self.cents = cents
    }

    /// Convenience with an unlabelled argument; identical to `init(cents:)`.
    init(_ cents: Int64) {
        self.cents = cents
    }

    // MARK: - Constants

    /// Zero money.
    static let zero = Money(cents: 0)

    /// Builds an amount from whole currency units, e.g. `Money.dollars(86)` == `Money(cents: 8600)`.
    ///
    /// Saturates instead of trapping when `value` is large enough to overflow `Int64` once scaled.
    static func dollars(_ value: Int64) -> Money {
        let (product, didOverflow) = value.multipliedReportingOverflow(by: 100)
        if didOverflow {
            return Money(cents: value < 0 ? Int64.min : Int64.max)
        }
        return Money(cents: product)
    }

    // MARK: - Inspection

    var isZero: Bool { cents == 0 }
    var isNegative: Bool { cents < 0 }
    var isPositive: Bool { cents > 0 }

    /// Absolute value. `Int64.min` saturates to `Int64.max` rather than trapping on negation.
    var magnitude: Money {
        if cents == Int64.min { return Money(cents: Int64.max) }
        return Money(cents: cents < 0 ? -cents : cents)
    }

    /// The exact decimal value (`cents / 100`), computed with `NSDecimalMultiplyByPowerOf10`
    /// so no binary floating-point rounding can ever be introduced.
    var decimalValue: Decimal {
        var source = Decimal(cents)
        var scaled = Decimal()
        // The calculation error is discarded on purpose: shifting an Int64 down by two decimal
        // places can neither overflow nor lose precision in a Decimal.
        _ = NSDecimalMultiplyByPowerOf10(&scaled, &source, -2, .plain)
        return scaled
    }

    // MARK: - Arithmetic

    /// Saturating addition — a ledger total can never wrap around into a negative number.
    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, didOverflow) = lhs.addingReportingOverflow(rhs)
        if didOverflow {
            return rhs > 0 ? Int64.max : Int64.min
        }
        return sum
    }

    /// Saturating subtraction — see `saturatingAdd`.
    private static func saturatingSubtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (difference, didOverflow) = lhs.subtractingReportingOverflow(rhs)
        if didOverflow {
            return rhs < 0 ? Int64.max : Int64.min
        }
        return difference
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        Money(cents: saturatingAdd(lhs.cents, rhs.cents))
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        Money(cents: saturatingSubtract(lhs.cents, rhs.cents))
    }

    static func += (lhs: inout Money, rhs: Money) {
        lhs = lhs + rhs
    }

    static func -= (lhs: inout Money, rhs: Money) {
        lhs = lhs - rhs
    }

    static prefix func - (value: Money) -> Money {
        if value.cents == Int64.min { return Money(cents: Int64.max) }
        return Money(cents: -value.cents)
    }

    static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.cents < rhs.cents
    }

    // MARK: - Rendering

    /// Debug/diagnostic description. Identical to `plainDecimalString`.
    var description: String { plainDecimalString }

    /// Locale-aware currency string, e.g. `"$86.50"`.
    ///
    /// Falls back to `plainDecimalString` if the formatter cannot produce a string, so callers
    /// never have to deal with an optional.
    func formatted(currencyCode: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = NSDecimalNumber(decimal: decimalValue)
        if let text = formatter.string(from: number) {
            return text
        }
        return plainDecimalString
    }

    /// Plain, unlocalised `"86.50"` — always a period, never a grouping separator.
    ///
    /// CSV and JSON exports use this so a file produced on a German device still imports into a
    /// US spreadsheet. Built from integer division only; no formatter, no floating point.
    var plainDecimalString: String {
        let magnitudeCents = cents.magnitude          // UInt64, so Int64.min is safe
        let whole = magnitudeCents / 100
        let fraction = magnitudeCents % 100
        let fractionText = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        let sign = cents < 0 ? "-" : ""
        return sign + "\(whole)." + fractionText
    }

    /// Spoken form for VoiceOver, e.g. `"86 US dollars and 50 cents"`.
    ///
    /// The major unit name comes from the locale via `.currencyPlural`; the minor unit is spoken as
    /// "cent"/"cents", which is correct for the currencies this app ships with (USD/CAD/EUR).
    func accessibilityText(currencyCode: String, locale: Locale = .current) -> String {
        let magnitudeCents = cents.magnitude
        let whole = magnitudeCents / 100
        let fraction = magnitudeCents % 100

        let formatter = NumberFormatter()
        formatter.numberStyle = .currencyPlural
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0

        let majorText: String
        if let text = formatter.string(from: NSNumber(value: whole)) {
            majorText = text
        } else {
            majorText = "\(whole) \(currencyCode)"
        }

        var spoken = majorText
        if fraction > 0 {
            spoken += fraction == 1 ? " and 1 cent" : " and \(fraction) cents"
        }
        if cents < 0 {
            spoken = "negative " + spoken
        }
        return spoken
    }

    // MARK: - Parsing

    /// Locale used to turn the normalised digit string into a `Decimal`. POSIX always uses `.`.
    private static let parsingLocale = Locale(identifier: "en_US_POSIX")

    /// Fraction digits beyond this are dropped before rounding; far more precision than any
    /// hand-typed core charge needs, and it keeps pathological input away from `Decimal`'s limits.
    private static let maximumFractionDigits = 12

    /// Largest number of integer digits accepted before the value is rejected as out of range.
    private static let maximumIntegerDigits = 19

    /// Parses shop-floor input into cents.
    ///
    /// Accepts `"86.50"`, `"$86.50"`, `"86,50"`, `"1,234.56"`, `" 86.5 "`, `"86"`, `"-11.50"`,
    /// and `"(11.50)"`. Returns `nil` for empty strings, anything containing letters, and values
    /// whose magnitude would overflow `Int64`.
    ///
    /// Separator disambiguation, in order:
    /// 1. If both `.` and `,` appear, the **last** one is the decimal separator and the other is a
    ///    grouping separator. That reads `"1,234.56"` and `"1.234,56"` correctly.
    /// 2. If only one appears once, it is the decimal separator when it matches the locale's
    ///    decimal separator; otherwise it is a decimal separator unless exactly three digits
    ///    follow it, in which case it is grouping (`"1,234"` in en_US).
    /// 3. If one appears repeatedly, every occurrence must be followed by exactly three digits,
    ///    otherwise the input is rejected.
    ///
    /// Rounding is half-away-from-zero at two decimal places, performed by `NSDecimalRound`.
    static func parse(_ text: String, locale: Locale = .current) -> Money? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let localeDecimalSeparator: Character = (locale.decimalSeparator ?? ".").first ?? "."

        var cleaned = ""
        var isNegative = false
        var sawDigit = false

        for character in trimmed {
            if character.isWhitespace { continue }
            if character.isCurrencySymbol { continue }

            if character == "-" || character == "\u{2212}" {
                if sawDigit { return nil }
                isNegative = true
                continue
            }
            if character == "+" {
                if sawDigit { return nil }
                continue
            }
            if character == "(" {
                if sawDigit { return nil }
                isNegative = true
                continue
            }
            if character == ")" {
                continue
            }
            if character.isNumber, let digit = character.wholeNumberValue, digit >= 0, digit <= 9 {
                cleaned += String(digit)
                sawDigit = true
                continue
            }
            if character == "." || character == "," {
                cleaned.append(character)
                continue
            }
            return nil
        }

        guard sawDigit else { return nil }

        let characters = Array(cleaned)
        let dotPositions = characters.indices.filter { characters[$0] == "." }
        let commaPositions = characters.indices.filter { characters[$0] == "," }

        var decimalPosition: Int?

        if let lastDot = dotPositions.last, let lastComma = commaPositions.last {
            if lastDot > lastComma {
                guard dotPositions.count == 1 else { return nil }
                decimalPosition = lastDot
            } else {
                guard commaPositions.count == 1 else { return nil }
                decimalPosition = lastComma
            }
        } else if !dotPositions.isEmpty || !commaPositions.isEmpty {
            let usesDot = !dotPositions.isEmpty
            let positions = usesDot ? dotPositions : commaPositions
            let separator: Character = usesDot ? "." : ","

            if positions.count == 1 {
                guard let only = positions.first else { return nil }
                let digitsAfter = characters.count - only - 1
                if separator == localeDecimalSeparator {
                    decimalPosition = only
                } else if digitsAfter == 3 {
                    decimalPosition = nil
                } else {
                    decimalPosition = only
                }
            } else {
                for position in positions {
                    let nextPosition = positions.first(where: { $0 > position })
                    let end = nextPosition ?? characters.count
                    if end - position - 1 != 3 { return nil }
                }
                decimalPosition = nil
            }
        }

        var integerDigits = ""
        var fractionDigits = ""
        for (offset, character) in characters.enumerated() {
            if character == "." || character == "," { continue }
            if let position = decimalPosition, offset > position {
                fractionDigits += String(character)
            } else {
                integerDigits += String(character)
            }
        }

        guard integerDigits.count <= maximumIntegerDigits else { return nil }
        if fractionDigits.count > maximumFractionDigits {
            fractionDigits = String(fractionDigits.prefix(maximumFractionDigits))
        }

        let canonical = (integerDigits.isEmpty ? "0" : integerDigits)
            + "."
            + (fractionDigits.isEmpty ? "0" : fractionDigits)

        guard var amount = Decimal(string: canonical, locale: parsingLocale) else { return nil }
        guard !amount.isNaN else { return nil }

        var scaled = Decimal()
        // A calculation error here (overflow on absurd input) leaves `scaled` unusable, so the
        // range check below rejects it; there is nothing extra to report.
        _ = NSDecimalMultiplyByPowerOf10(&scaled, &amount, 2, .plain)

        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)

        guard !rounded.isNaN else { return nil }
        guard rounded >= 0, rounded <= Decimal(Int64.max) else { return nil }

        let value = NSDecimalNumber(decimal: rounded).int64Value
        return Money(cents: isNegative ? -value : value)
    }
}
