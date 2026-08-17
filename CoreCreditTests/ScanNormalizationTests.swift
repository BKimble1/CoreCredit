//
//  ScanNormalizationTests.swift
//  CoreCreditTests
//
//  An identifier is a string. Nothing in `ScanTextNormalizer` may turn `00123` into `123`, and
//  nothing may quietly rewrite a character on the user's behalf.
//
//  Two separate jobs are pinned here:
//
//  1. **Control characters are removed.** A keyboard-wedge scanner emits GS/RS/US/EOT between and
//     after fields; those are invisible, so the shop-floor symptom is a part number that "looks
//     fine" and matches nothing. Everything visible — spaces, hyphens, slashes, letters, leading
//     zeros — survives byte for byte.
//  2. **Character confusions are offered, never applied.** `confusionAlternatives` returns variants
//     in a deterministic order, excludes the input, honours `limit`, and leaves the input alone.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Scanned text is cleaned without ever becoming a number")
struct ScanNormalizationTests {

    /// The four control characters a hardware scanner actually emits: GS, RS, US, and EOT.
    private let groupSeparator = "\u{001D}"
    private let recordSeparator = "\u{001E}"
    private let unitSeparator = "\u{001F}"
    private let endOfTransmission = "\u{0004}"

    // MARK: - Leading zeros

    @Test("Leading zeros survive both stripping and identifier normalisation")
    func leadingZerosSurvive() {
        #expect(ScanTextNormalizer.stripControlCharacters("00123") == "00123")
        #expect(ScanTextNormalizer.normalizedIdentifier("00123") == "00123")

        // The failure this guards against is an `Int` conversion somewhere on the path.
        #expect(ScanTextNormalizer.normalizedIdentifier("00123") != "123")
        #expect(ScanTextNormalizer.normalizedIdentifier("007") == "007")
        #expect(ScanTextNormalizer.normalizedIdentifier("  0000  ") == "0000")

        #expect(ScanTextNormalizer.isAllDigits("00123"))
        // All digits and nothing else: a bare number is not, by itself, an identifier.
        #expect(ScanTextNormalizer.looksLikeIdentifier("00123") == false)
    }

    // MARK: - Alphanumeric part numbers

    @Test("Alphanumeric part numbers survive intact")
    func alphanumericPartNumbersSurviveIntact() {
        #expect(ScanTextNormalizer.stripControlCharacters("03-1887") == "03-1887")
        #expect(ScanTextNormalizer.normalizedIdentifier("03-1887") == "03-1887")

        #expect(ScanTextNormalizer.stripControlCharacters("AC-DELCO/45D") == "AC-DELCO/45D")
        #expect(ScanTextNormalizer.normalizedIdentifier("AC-DELCO/45D") == "AC-DELCO/45D")

        // Uppercasing is the only transformation applied to letters, and it is locale-independent.
        #expect(ScanTextNormalizer.normalizedIdentifier("ac-delco/45d") == "AC-DELCO/45D")

        #expect(ScanTextNormalizer.looksLikeIdentifier("03-1887"))
        #expect(ScanTextNormalizer.looksLikeIdentifier("AC-DELCO/45D"))
    }

    // MARK: - Separators

    @Test("Spaces, slashes and hyphens are preserved; only control characters are removed")
    func separatorsArePreservedAndOnlyControlCharactersAreRemoved() {
        #expect(ScanTextNormalizer.stripControlCharacters("03-18/87 A") == "03-18/87 A")
        // Inner runs of whitespace are untouched by stripping — only the edges are trimmed.
        #expect(ScanTextNormalizer.stripControlCharacters("  03  1887  ") == "03  1887")
        // The identifier form collapses those runs to one space, and nothing else.
        #expect(ScanTextNormalizer.normalizedIdentifier("  03   1887  ") == "03 1887")

        #expect(ScanTextNormalizer.scannerControlCharacters.contains(" ") == false)
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("-") == false)
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("/") == false)
        #expect(ScanTextNormalizer.scannerControlCharacters.contains(".") == false)
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("0") == false)
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("A") == false)
    }

    // MARK: - Scanner control characters

    @Test("Scanner control characters are stripped and the visible characters are untouched")
    func scannerControlCharactersAreStripped() {
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("\u{001D}"))
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("\u{001E}"))
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("\u{001F}"))
        #expect(ScanTextNormalizer.scannerControlCharacters.contains("\u{0004}"))

        let payload = endOfTransmission
            + "03-1887"
            + groupSeparator
            + " AC-DELCO/45D"
            + recordSeparator
            + unitSeparator

        #expect(ScanTextNormalizer.stripControlCharacters(payload) == "03-1887 AC-DELCO/45D")
        #expect(ScanTextNormalizer.normalizedIdentifier(payload) == "03-1887 AC-DELCO/45D")

        // A payload that is nothing but noise cleans down to nothing, rather than to a stray space.
        let noise = groupSeparator + recordSeparator + unitSeparator + endOfTransmission
        #expect(ScanTextNormalizer.stripControlCharacters(noise).isEmpty)

        // Leading zeros still survive when the separators sit right next to them.
        let zeroed = groupSeparator + "00123" + endOfTransmission
        #expect(ScanTextNormalizer.stripControlCharacters(zeroed) == "00123")
    }

    // MARK: - Confusion alternatives

    @Test("O and zero, I and one are offered as alternatives and never applied")
    func confusionAlternativesAreOfferedNeverApplied() {
        let value = "O3-1S87"
        let alternatives = ScanTextNormalizer.confusionAlternatives(for: value)

        // One variant per substitutable position, scanned left to right.
        #expect(alternatives == ["03-1S87", "O3-IS87", "O3-1587"])

        // The input is never one of its own alternatives, and it is never mutated.
        #expect(alternatives.contains(value) == false)
        #expect(value == "O3-1S87")

        // Deterministic: the same input produces the same array every time.
        #expect(ScanTextNormalizer.confusionAlternatives(for: value) == alternatives)

        // `limit` is honoured exactly, and a limit of zero means "offer nothing".
        #expect(ScanTextNormalizer.confusionAlternatives(for: value, limit: 1) == ["03-1S87"])
        #expect(ScanTextNormalizer.confusionAlternatives(for: value, limit: 2)
            == ["03-1S87", "O3-IS87"])
        #expect(ScanTextNormalizer.confusionAlternatives(for: value, limit: 0).isEmpty)

        // Both directions of each pair are offered: O -> 0, 0 -> O, I -> 1, 1 -> I.
        #expect(ScanTextNormalizer.confusionAlternatives(for: "IO") == ["1O", "I0"])
        #expect(ScanTextNormalizer.confusionAlternatives(for: "10") == ["I0", "1O"])

        // A value with nothing to swap offers nothing rather than inventing something.
        #expect(ScanTextNormalizer.confusionAlternatives(for: "372-44").isEmpty)
        #expect(ScanTextNormalizer.confusionAlternatives(for: "").isEmpty)
    }
}
