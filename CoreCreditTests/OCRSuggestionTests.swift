//
//  OCRSuggestionTests.swift
//  CoreCreditTests
//
//  Required scenario 13: recognised text becomes *suggestions* — never a written record.
//
//  Two properties are asserted throughout:
//
//  1. **Nothing is fabricated.** Text with no reference in it produces no suggestion, an amount
//     buried inside a part code is not harvested as money, and an implausible figure is dropped.
//  2. **Nothing is applied.** The extractor is a pure function from `[String]` to values; it has no
//     API that writes to a `CoreItemDraft`, and `extractionOnlySuggestsAndNeverWritesToADraft`
//     documents that.
//
//  Note on the extracted reference values: the extractor reports the *number*, not the label that
//  introduced it — `INV-552` yields `"552"`, `RO 1024` yields `"1024"`. That is deliberate (see
//  `OCRSuggestionExtractor.isClaimed`), and the expectations below match it.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Recognised invoice text becomes editable suggestions, never a written record")
struct OCRSuggestionTests {

    // MARK: - Fixtures

    /// A parts invoice as Vision would hand it over: a masthead, a couple of references, one line
    /// item, the core charge, and the summary block that is the most common wrong answer.
    private let invoiceLines = [
        "CENTRAL AUTO PARTS",
        "1420 Fifth Street",
        "INV-552",
        "RO 1024",
        "1  ALTERNATOR  03-1887   214.00",
        "CORE CHARGE  $86.50",
        "SUBTOTAL  300.50",
        "TOTAL DUE  318.53"
    ]

    /// The POSIX locale the extractor parses with, used here to re-parse a suggested amount.
    private let posix = Locale(identifier: "en_US_POSIX")

    private func suggestion(_ field: OCRField,
                            in suggestions: [OCRFieldSuggestion]) -> OCRFieldSuggestion? {
        suggestions.first { $0.field == field }
    }

    // MARK: - A realistic invoice

    @Test("A realistic invoice yields the invoice, repair order, part number, and core charge")
    func aRealisticInvoiceYieldsEveryField() throws {
        let results = OCRSuggestionExtractor.suggestions(from: invoiceLines)

        #expect(results.map(\.field) == [.partNumber,
                                         .invoiceReference,
                                         .repairOrderReference,
                                         .amount,
                                         .vendorName])

        let invoice = try #require(suggestion(.invoiceReference, in: results))
        #expect(invoice.value == "552")

        let repairOrder = try #require(suggestion(.repairOrderReference, in: results))
        #expect(repairOrder.value == "1024")

        let partNumber = try #require(suggestion(.partNumber, in: results))
        #expect(partNumber.value == "03-1887")
        #expect(partNumber.confidence == 0.6)

        let amount = try #require(suggestion(.amount, in: results))
        #expect(amount.value == "86.50")
        #expect(amount.confidence == 0.9)
        #expect(Money.parse(amount.value, locale: posix) == Money(cents: 8_650))

        let vendor = try #require(suggestion(.vendorName, in: results))
        #expect(vendor.value == "CENTRAL AUTO PARTS")
        #expect(vendor.confidence == 0.55)
    }

    @Test("The label variants that actually appear on parts invoices all read correctly")
    func theCommonLabelVariantsAllRead() {
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["INV# 552"],
                                                           prefixes: ["INVOICE", "INV"]) == ["552"])
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["Invoice: 552"],
                                                           prefixes: ["INVOICE", "INV"]) == ["552"])
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["INV.552"],
                                                           prefixes: ["INVOICE", "INV"]) == ["552"])
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["R.O. 1024"],
                                                           prefixes: ["RO"]) == ["1024"])
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["RO#1024"],
                                                           prefixes: ["RO"]) == ["1024"])

        let mixed = OCRSuggestionExtractor.suggestions(from: ["Invoice: 552", "R.O. 1024"])
        #expect(mixed.map(\.field) == [.invoiceReference, .repairOrderReference])
        #expect(mixed.map(\.value) == ["552", "1024"])
    }

    @Test("At most one suggestion is offered per field")
    func atMostOneSuggestionPerField() {
        let noisyLines = invoiceLines + [
            "INV-553",
            "RO 1099",
            "CORE CHARGE  $54.00",
            "PART NO 17-4420"
        ]
        let results = OCRSuggestionExtractor.suggestions(from: noisyLines)

        #expect(results.count <= OCRField.allCases.count)
        for field in OCRField.allCases {
            #expect(results.filter({ $0.field == field }).count <= 1)
        }
        #expect(Set(results.map(\.field)).count == results.count)
    }

    @Test("Every confidence stays inside zero through one, however the score was built")
    func everyConfidenceStaysInsideZeroThroughOne() {
        let results = OCRSuggestionExtractor.suggestions(from: invoiceLines)
        #expect(!results.isEmpty)
        for result in results {
            #expect(result.confidence >= 0)
            #expect(result.confidence <= 1)
        }

        // The clamp is part of the type, so a future heuristic cannot leak an out-of-range score
        // (or a NaN) into the UI.
        #expect(OCRFieldSuggestion(field: .amount, value: "86.50", confidence: 4.2).confidence == 1)
        #expect(OCRFieldSuggestion(field: .amount, value: "86.50", confidence: -1).confidence == 0)
        #expect(OCRFieldSuggestion(field: .amount,
                                   value: "86.50",
                                   confidence: Double.nan).confidence == 0)
    }

    // MARK: - Nothing to find

    @Test("Empty input produces no suggestions and no crash")
    func emptyInputProducesNoSuggestions() {
        #expect(OCRSuggestionExtractor.suggestions(from: []).isEmpty)
        #expect(OCRSuggestionExtractor.suggestions(from: ["", "   ", "\n"]).isEmpty)
        #expect(OCRSuggestionExtractor.amountCandidates(from: []).isEmpty)
        #expect(OCRSuggestionExtractor.referenceCandidates(from: [], prefixes: ["INV"]).isEmpty)
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["INV-552"], prefixes: []).isEmpty)
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["INV-552"], prefixes: ["  "]).isEmpty)
    }

    @Test("Text with no reference in it suggests nothing rather than inventing something")
    func textWithNoReferenceSuggestsNothing() {
        let footer = ["Thank you for your business", "Please pay within 30 days"]
        #expect(OCRSuggestionExtractor.suggestions(from: footer).isEmpty)
        #expect(OCRSuggestionExtractor.amountCandidates(from: footer).isEmpty)
        #expect(OCRSuggestionExtractor.referenceCandidates(from: footer,
                                                           prefixes: ["INVOICE", "INV"]).isEmpty)
    }

    @Test("A label with no digits after it is a word, not a reference")
    func aLabelWithNoDigitsIsNotAReference() {
        // `REF` inside `REFERENCE` must not harvest `ERENCE`; a label running straight into digits
        // still counts.
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["REFERENCE1 attached"],
                                                           prefixes: ["REF"]).isEmpty)
        #expect(OCRSuggestionExtractor.referenceCandidates(from: ["REF552"],
                                                           prefixes: ["REF"]) == ["552"])
    }

    // MARK: - Amounts

    @Test("A core-charge line outranks an unrelated total")
    func aCoreChargeLineOutranksATotal() {
        let charge = OCRSuggestionExtractor.amountCandidates(from: [
            "TOTAL DUE  318.53",
            "CORE CHARGE  86.50",
            "LABOR  120.00"
        ])
        #expect(charge == [Money(cents: 8_650), Money(cents: 12_000), Money(cents: 31_853)])

        let deposit = OCRSuggestionExtractor.amountCandidates(from: [
            "INVOICE TOTAL 318.53",
            "CORE DEPOSIT $86.50"
        ])
        #expect(deposit == [Money(cents: 8_650), Money(cents: 31_853)])
        #expect(deposit.first?.cents == 8_650)
    }

    @Test("Amounts are parsed through Money as exact cents, never through a float")
    func amountsAreParsedThroughMoneyAsExactCents() throws {
        let candidates = OCRSuggestionExtractor.amountCandidates(from: ["CORE CHARGE  $86.50"])
        let first = try #require(candidates.first)

        #expect(first == Money(cents: 8_650))
        #expect(first.cents == 8_650)
        #expect(first.plainDecimalString == "86.50")

        let results = OCRSuggestionExtractor.suggestions(from: ["CORE CHARGE  $86.50"])
        let amount = try #require(suggestion(.amount, in: results))
        #expect(amount.value == "86.50")
        for artefact in floatingPointArtefacts {
            #expect(!amount.value.contains(artefact))
        }
    }

    @Test("The same amount printed twice is one candidate")
    func theSameAmountPrintedTwiceIsOneCandidate() {
        let candidates = OCRSuggestionExtractor.amountCandidates(from: [
            "CORE CHARGE  86.50",
            "TOTAL  86.50"
        ])
        #expect(candidates == [Money(cents: 8_650)])
    }

    @Test("Digits inside a part code and implausible figures are not read as money")
    func digitsInsideACodeAreNotReadAsMoney() {
        #expect(OCRSuggestionExtractor.amountCandidates(from: ["ALTERNATOR 03-1887.50 EA"]).isEmpty)
        #expect(OCRSuggestionExtractor.amountCandidates(from: ["MISREAD 1,234,567.89"]).isEmpty)
        #expect(OCRSuggestionExtractor.amountCandidates(from: ["QTY 2  RO 1024"]).isEmpty)
    }

    // MARK: - References and part numbers do not collide

    @Test("A value claimed as the invoice is never suggested as the part number too")
    func aClaimedReferenceIsNotAlsoAPartNumber() throws {
        let results = OCRSuggestionExtractor.suggestions(from: ["INV-55219"])

        #expect(results.count == 1)
        let invoice = try #require(suggestion(.invoiceReference, in: results))
        #expect(invoice.value == "55219")
        #expect(invoice.confidence > 0.6)
        #expect(invoice.confidence <= 0.95)
        #expect(suggestion(.partNumber, in: results) == nil)
    }

    @Test("A line that names a part scores its part number higher than a bare code")
    func aPartContextLineScoresHigher() {
        let labelled = OCRSuggestionExtractor.suggestions(from: ["PART NO 03-1887"])
        #expect(labelled == [OCRFieldSuggestion(field: .partNumber,
                                                value: "03-1887",
                                                confidence: 0.9)])

        let bare = OCRSuggestionExtractor.suggestions(from: ["1  ALTERNATOR  03-1887   214.00"])
        #expect(suggestion(.partNumber, in: bare)?.confidence == 0.6)
    }

    // MARK: - A suggestion is only ever a suggestion

    @Test("Extraction only ever suggests: it never writes to a draft")
    func extractionOnlySuggestsAndNeverWritesToADraft() throws {
        // `OCRSuggestionExtractor` exposes exactly three entry points — `suggestions(from:)`,
        // `amountCandidates(from:)`, and `referenceCandidates(from:prefixes:)` — and every one of
        // them takes text and returns values. None of them accepts a `CoreItemDraft`, so there is
        // no path from a photo to a saved record that does not pass through a human tap. This test
        // documents that: a draft held alongside a full extraction is untouched by it.
        var draft = CoreItemDraft(partName: "Alternator", receivedDate: TestClock.referenceNow)
        let untouched = draft

        let results = OCRSuggestionExtractor.suggestions(from: invoiceLines)
        _ = OCRSuggestionExtractor.amountCandidates(from: invoiceLines)
        _ = OCRSuggestionExtractor.referenceCandidates(from: invoiceLines, prefixes: ["INV"])

        #expect(!results.isEmpty)
        #expect(draft == untouched)
        #expect(draft.partNumber.isEmpty)
        #expect(draft.invoiceReference.isEmpty)
        #expect(draft.repairOrderReference.isEmpty)
        #expect(draft.expectedCreditText.isEmpty)

        // Applying a suggestion is the editor's job, and it is an ordinary assignment onto the
        // field the suggestion names.
        #expect(OCRField.amount.coreItemField == .expectedCredit)
        #expect(OCRField.partNumber.coreItemField == .partNumber)
        #expect(OCRField.vendorName.coreItemField == .vendor)

        let partSuggestion = try #require(suggestion(.partNumber, in: results))
        let amountSuggestion = try #require(suggestion(.amount, in: results))
        draft.partNumber = partSuggestion.value
        draft.expectedCreditText = amountSuggestion.value

        #expect(draft != untouched)
        #expect(draft.partNumber == "03-1887")
        #expect(draft.expectedCredit == Money(cents: 8_650))
    }
}
