//
//  MoneyTests.swift
//  CoreCreditTests
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Money stays exact integer cents from parsing through to rendering")
struct MoneyTests {

    private let usEnglish = Locale(identifier: "en_US")
    private let germany = Locale(identifier: "de_DE")
    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - Parsing

    @Test("A plain decimal amount parses to exact cents")
    func parsesAPlainDecimalAmount() {
        #expect(Money.parse("86.50", locale: usEnglish) == Money(cents: 8_650))
        #expect(Money.parse("0.05", locale: usEnglish) == Money(cents: 5))
        #expect(Money.parse("86.5", locale: usEnglish) == Money(cents: 8_650))
    }

    @Test("A currency symbol and a grouping separator are both accepted")
    func parsesACurrencySymbolAndGroupingSeparator() {
        #expect(Money.parse("$1,234.56", locale: usEnglish) == Money(cents: 123_456))
        #expect(Money.parse("$86.50", locale: usEnglish) == Money(cents: 8_650))
    }

    @Test("A whole number with no decimal part parses as whole currency units")
    func parsesAWholeNumberWithNoDecimalPart() {
        #expect(Money.parse("86", locale: usEnglish) == Money(cents: 8_600))
    }

    @Test("A grouped integer with no decimal part is not mistaken for a fraction")
    func parsesAGroupedIntegerWithoutADecimalPart() {
        #expect(Money.parse("1,234", locale: usEnglish) == Money(cents: 123_400))
    }

    @Test("Empty and whitespace-only text parse to nil")
    func returnsNilForEmptyText() {
        #expect(Money.parse("", locale: usEnglish) == nil)
        #expect(Money.parse("   ", locale: usEnglish) == nil)
    }

    @Test("Text with no digits parses to nil")
    func returnsNilForGarbage() {
        #expect(Money.parse("abc", locale: usEnglish) == nil)
        #expect(Money.parse("86.50 USD", locale: usEnglish) == nil)
        #expect(Money.parse("$", locale: usEnglish) == nil)
        #expect(Money.parse("-", locale: usEnglish) == nil)
    }

    @Test("A comma decimal separator parses correctly in a comma-decimal locale")
    func parsesACommaDecimalLocale() {
        #expect(Money.parse("86,50", locale: germany) == Money(cents: 8_650))
        #expect(Money.parse("1.234,56", locale: germany) == Money(cents: 123_456))
    }

    @Test("Surrounding whitespace is trimmed before parsing")
    func trimsSurroundingWhitespace() {
        #expect(Money.parse(" 86.5 ", locale: usEnglish) == Money(cents: 8_650))
    }

    @Test("A negative amount keeps its sign")
    func parsesANegativeAmount() {
        #expect(Money.parse("-11.50", locale: usEnglish) == Money(cents: -1_150))
        #expect(Money.parse("(11.50)", locale: usEnglish) == Money(cents: -1_150))
    }

    @Test("A third decimal place rounds half away from zero, never through a Double")
    func roundsHalfAwayFromZero() {
        #expect(Money.parse("86.505", locale: usEnglish) == Money(cents: 8_651))
        #expect(Money.parse("86.504", locale: usEnglish) == Money(cents: 8_650))
    }

    // MARK: - Rendering

    @Test("plainDecimalString renders zero, positive, and negative values without a formatter")
    func plainDecimalStringCoversZeroAndNegativeValues() {
        #expect(Money.zero.plainDecimalString == "0.00")
        #expect(Money(cents: 5).plainDecimalString == "0.05")
        #expect(Money(cents: 8_650).plainDecimalString == "86.50")
        #expect(Money(cents: -1_150).plainDecimalString == "-11.50")
        #expect(Money(cents: 123_456).plainDecimalString == "1234.56")
    }

    @Test("description matches plainDecimalString")
    func descriptionMatchesPlainDecimalString() {
        #expect(Money(cents: 8_650).description == "86.50")
        #expect(Money(cents: -1_150).description == Money(cents: -1_150).plainDecimalString)
    }

    @Test("A formatted amount carries the currency symbol and the exact figure")
    func formattedIncludesSymbolAndAmount() {
        let text = Money(cents: 8_650).formatted(currencyCode: "USD", locale: usEnglish)
        #expect(text.contains("86.50"))
        #expect(text.contains("$"))
    }

    @Test("Accessibility text speaks the cents separately")
    func accessibilityTextSpeaksTheCents() {
        let spoken = Money(cents: 8_650).accessibilityText(currencyCode: "USD", locale: usEnglish)
        #expect(spoken.contains("and 50 cents"))

        let single = Money(cents: 8_601).accessibilityText(currencyCode: "USD", locale: usEnglish)
        #expect(single.contains("and 1 cent"))

        let negative = Money(cents: -8_650).accessibilityText(currencyCode: "USD", locale: usEnglish)
        #expect(negative.hasPrefix("negative "))

        let whole = Money(cents: 8_600).accessibilityText(currencyCode: "USD", locale: usEnglish)
        #expect(!whole.contains("cents"))
    }

    // MARK: - Arithmetic and inspection

    @Test("Arithmetic stays in integer cents")
    func arithmeticStaysInIntegerCents() {
        #expect(Money(cents: 8_650) + Money(cents: 1_150) == Money(cents: 9_800))
        #expect(Money(cents: 8_650) - Money(cents: 7_500) == Money(cents: 1_150))
        #expect(-Money(cents: 8_650) == Money(cents: -8_650))

        var running = Money.zero
        running += Money(cents: 8_650)
        running += Money(cents: 5_400)
        running -= Money(cents: 50)
        #expect(running == Money(cents: 14_000))
    }

    @Test("Whole-unit and inspection helpers agree with the cent value")
    func inspectionHelpers() {
        #expect(Money.dollars(86) == Money(cents: 8_600))
        #expect(Money.dollars(0) == Money.zero)
        #expect(Money.zero.isZero)
        #expect(Money(cents: 1).isPositive)
        #expect(Money(cents: -1).isNegative)
        #expect(Money(cents: -1_150).magnitude == Money(cents: 1_150))
        #expect(Money(cents: 1_150).magnitude == Money(cents: 1_150))
        #expect(Money(cents: 100) < Money(cents: 200))
        #expect(Money(cents: 200) > Money(cents: 100))
    }

    @Test("decimalValue is an exact Decimal, never a binary float")
    func decimalValueIsExact() throws {
        let expected = try #require(Decimal(string: "86.50", locale: posix))
        #expect(Money(cents: 8_650).decimalValue == expected)

        let negative = try #require(Decimal(string: "-11.50", locale: posix))
        #expect(Money(cents: -1_150).decimalValue == negative)
    }

    @Test("Money round-trips through Codable as integer cents")
    func codableRoundTripPreservesCents() throws {
        let original = Money(cents: 8_650)
        let data = try JSONEncoder().encode(original)
        let text = utf8Text(data)

        #expect(text.contains("8650"))
        for artefact in floatingPointArtefacts {
            #expect(!text.contains(artefact))
        }

        let decoded = try JSONDecoder().decode(Money.self, from: data)
        #expect(decoded == original)
        #expect(decoded.cents == 8_650)
    }
}
