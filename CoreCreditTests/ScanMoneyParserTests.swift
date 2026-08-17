//
//  ScanMoneyParserTests.swift
//  CoreCreditTests
//
//  A wrong core charge is a wrong number in a shop's ledger, and nobody is watching a camera read
//  an invoice. So this parser is stricter than `Money.parse`: where a person typing `1.234` can see
//  the result, a misread of the same token has to be refused with a reason.
//
//  Two properties are pinned throughout:
//
//  1. **Exact `Int64` cents.** Every accepted value goes through `Money` / `Decimal`, so `$86.50`
//     is exactly `8650` and can never drift by a fraction of a cent.
//  2. **Every refusal is named.** `.notMoney`, `.ambiguousSeparator`, `.tooManyFractionDigits` and
//     `.outOfRange` each carry a sentence telling the technician to type the amount in instead.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Money read off a page is exact cents or a named refusal")
struct ScanMoneyParserTests {

    /// A period-decimal locale and a comma-decimal locale. Both fixed, so a machine's own region
    /// setting cannot change any answer below.
    private let unitedStates = Locale(identifier: "en_US")
    private let germany = Locale(identifier: "de_DE")

    private func parsedMoney(_ token: String, locale: Locale) -> Money? {
        switch ScanMoneyParser.parse(token, locale: locale) {
        case .success(let money): return money
        case .failure: return nil
        }
    }

    private func rejection(_ token: String, locale: Locale) -> ScanMoneyRejection? {
        switch ScanMoneyParser.parse(token, locale: locale) {
        case .success: return nil
        case .failure(let rejection): return rejection
        }
    }

    // MARK: - Exact cents

    @Test("A currency-marked amount parses to exact Int64 cents")
    func aCurrencyMarkedAmountParsesToExactCents() throws {
        let money = try #require(parsedMoney("$86.50", locale: unitedStates))

        #expect(money.cents == 8_650)
        #expect(money == Money(cents: 8_650))
        #expect(money.plainDecimalString == "86.50")

        #expect(parsedMoney("86.50", locale: unitedStates)?.cents == 8_650)
        #expect(parsedMoney("86", locale: unitedStates)?.cents == 8_600)
        #expect(parsedMoney("86.5", locale: unitedStates)?.cents == 8_650)
        #expect(parsedMoney("1,234.56", locale: unitedStates)?.cents == 123_456)
        #expect(parsedMoney("1.234,56", locale: unitedStates)?.cents == 123_456)
        // Three digits after a separator that is *not* the locale's decimal point is a thousands
        // group, so the token reads as whole currency units.
        #expect(parsedMoney("1,234", locale: unitedStates)?.cents == 123_400)
    }

    @Test("No amount picks up floating-point drift on the way through")
    func noAmountPicksUpFloatingPointDrift() throws {
        // Values chosen because they are the ones that drift when a Double is involved anywhere.
        #expect(parsedMoney("0.29", locale: unitedStates)?.cents == 29)
        #expect(parsedMoney("1.15", locale: unitedStates)?.cents == 115)
        #expect(parsedMoney("86.50", locale: unitedStates)?.cents == 8_650)
        #expect(parsedMoney("0.01", locale: unitedStates)?.cents == 1)
        #expect(parsedMoney("999999.99", locale: unitedStates)?.cents == 99_999_999)

        #expect(parsedMoney("0.29", locale: unitedStates)?.plainDecimalString == "0.29")
        #expect(parsedMoney("1.15", locale: unitedStates)?.plainDecimalString == "1.15")

        let money = try #require(parsedMoney("$86.50", locale: unitedStates))
        for artefact in floatingPointArtefacts {
            #expect(money.plainDecimalString.contains(artefact) == false)
        }
    }

    // MARK: - Comma decimals

    @Test("A comma decimal parses under a comma-decimal locale")
    func aCommaDecimalParsesUnderACommaDecimalLocale() {
        #expect(parsedMoney("86,50", locale: germany)?.cents == 8_650)
        #expect(parsedMoney("1.234,56", locale: germany)?.cents == 123_456)

        // Under a period-decimal locale the same token could be read two ways, so it is refused —
        // unless a currency symbol settles it.
        #expect(rejection("86,50", locale: unitedStates) == .ambiguousSeparator)
        #expect(parsedMoney("$86,50", locale: unitedStates)?.cents == 8_650)
    }

    // MARK: - Refusals

    @Test("Malformed and ambiguous tokens are refused with the reason that fits")
    func malformedAndAmbiguousTokensAreRefused() {
        #expect(rejection("", locale: unitedStates) == .notMoney)
        #expect(rejection("   ", locale: unitedStates) == .notMoney)
        #expect(rejection("abc", locale: unitedStates) == .notMoney)
        #expect(rejection("CORE", locale: unitedStates) == .notMoney)
        // A hyphen after the digits have started is part of a code, not a minus sign.
        #expect(rejection("12-34", locale: unitedStates) == .notMoney)
        #expect(rejection("86.", locale: unitedStates) == .notMoney)

        // Thousands group or decimal point? Nothing in the token settles it.
        #expect(rejection("1.234", locale: unitedStates) == .ambiguousSeparator)
        #expect(rejection("$1.234", locale: unitedStates) == .ambiguousSeparator)

        // Three fraction digits ending in zero is over-precision rather than ambiguity.
        #expect(rejection("86.500", locale: unitedStates) == .tooManyFractionDigits)
        #expect(rejection("86.5000", locale: unitedStates) == .tooManyFractionDigits)

        // Larger than any plausible core charge.
        #expect(rejection("1,234,567.89", locale: unitedStates) == .outOfRange)
        #expect(rejection("$12345678901.00", locale: unitedStates) == .outOfRange)

        // Nothing refused ever produces a value.
        #expect(parsedMoney("1.234", locale: unitedStates) == nil)
        #expect(parsedMoney("86.500", locale: unitedStates) == nil)
        #expect(parsedMoney("12-34", locale: unitedStates) == nil)
    }

    @Test("Every refusal tells the technician what to do next")
    func everyRefusalExplainsItself() {
        let refusals: [ScanMoneyRejection] = [
            .notMoney, .ambiguousSeparator, .tooManyFractionDigits, .outOfRange
        ]
        for refusal in refusals {
            #expect(refusal.explanation.isEmpty == false)
        }
    }

    // MARK: - Token finding

    @Test("Money-shaped substrings are found in reading order and left unparsed")
    func moneyShapedSubstringsAreFoundInReadingOrder() {
        #expect(ScanMoneyParser.moneyTokens(in: "CORE CHARGE  $86.50") == ["$86.50"])
        #expect(ScanMoneyParser.moneyTokens(in: "CORE 86.50  TOTAL 318.53") == ["86.50", "318.53"])
        // A bare run of digits on an invoice is a quantity or a line number far more often than
        // it is an amount, so it is not money-shaped.
        #expect(ScanMoneyParser.moneyTokens(in: "QTY 2  RO 4242").isEmpty)
        // Over-precision has to be *seen* before it can be refused, so the token is still returned.
        #expect(ScanMoneyParser.moneyTokens(in: "MISREAD 86.500") == ["86.500"])
    }
}
