//
//  ScanCandidateRankingTests.swift
//  CoreCreditTests
//
//  `OCRSuggestionExtractor.candidates(from:source:)` answers a broader question than
//  `suggestions(from:)`: "everything you saw, ranked, each with the reason you saw it, so a person
//  can pick". These tests pin the part of that answer that matters on a shop floor.
//
//  The single most common wrong answer on a parts invoice is the grand total, and the second most
//  common is a tax or freight line. Both must be offered — a technician may have to pick one — and
//  neither may ever outrank an amount that sits on a line naming the core.
//
//  Every fixture is synthetic recognised text. No camera, no image bytes, no real vendor.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Ranked scan candidates put the core charge first and explain themselves")
struct ScanCandidateRankingTests {

    // MARK: - Fixtures

    /// A parts invoice as a recogniser would hand it over: masthead, invoice number, one line item,
    /// the core charge, and the summary block.
    private let invoiceLines: [RecognizedLine] = [
        RecognizedLine(text: "ACME PARTS SUPPLY", confidence: 0.99),
        RecognizedLine(text: "INVOICE INV-100200", confidence: 0.97),
        RecognizedLine(text: "1  ALTERNATOR  03-1887   214.00", confidence: 0.95),
        RecognizedLine(text: "CORE CHARGE  $86.50", confidence: 0.96),
        RecognizedLine(text: "SUBTOTAL  300.50", confidence: 0.94),
        RecognizedLine(text: "TOTAL DUE  318.53", confidence: 0.94)
    ]

    /// The same core charge surrounded by the four charges that are never a core credit.
    private let ancillaryChargeLines: [RecognizedLine] = [
        RecognizedLine(text: "ACME PARTS SUPPLY", confidence: 0.99),
        RecognizedLine(text: "CORE CHARGE  $86.50", confidence: 0.96),
        RecognizedLine(text: "TAX  7.35", confidence: 0.95),
        RecognizedLine(text: "FREIGHT  19.95", confidence: 0.95),
        RecognizedLine(text: "SHIPPING  12.00", confidence: 0.95),
        RecognizedLine(text: "HANDLING  4.25", confidence: 0.95)
    ]

    /// One labelled value per line, so each label can be checked against the kind it produces.
    private let labelledLines: [RecognizedLine] = [
        RecognizedLine(text: "ACME PARTS SUPPLY", confidence: 0.99),
        RecognizedLine(text: "INVOICE INV-100200", confidence: 0.97),
        RecognizedLine(text: "RO 4242", confidence: 0.96),
        RecognizedLine(text: "RMA 88-77", confidence: 0.96),
        RecognizedLine(text: "P/N 03-1887", confidence: 0.96)
    ]

    private func candidate(_ kind: ScanCandidateKind,
                           value: String,
                           in candidates: [ScanCandidate]) -> ScanCandidate? {
        candidates.first { $0.kind == kind && $0.normalizedValue == value }
    }

    // MARK: - Core charge versus the total

    @Test("A core charge outranks a larger invoice total")
    func aCoreChargeOutranksALargerInvoiceTotal() throws {
        let candidates = OCRSuggestionExtractor.candidates(from: invoiceLines, source: .documentOCR)

        let topAmount = try #require(candidates.first(where: { $0.kind == .coreAmount }))
        #expect(topAmount.normalizedValue == "86.50")
        #expect(topAmount.rawValue == "$86.50")
        #expect(topAmount.money == Money(cents: 8_650))
        #expect(topAmount.money?.cents == 8_650)
        #expect(topAmount.reason == "Follows the label \"CORE CHARGE\"")
        #expect(topAmount.band == .high)

        // The grand total is still offered — it is just ranked below, and banded low.
        let total = try #require(candidate(.coreAmount, value: "318.53", in: candidates))
        #expect(total.confidence < topAmount.confidence)
        #expect(total.band == .low)
        #expect(total.isSafeToPreselect == false)

        // The whole ordering, so a future change to the tie-breaks is visible here.
        let amounts = candidates.filter { $0.kind == .coreAmount }.map(\.normalizedValue)
        #expect(amounts == ["86.50", "214.00", "300.50", "318.53"])

        // Only `.coreAmount` carries money.
        let partNumber = try #require(candidate(.partNumber, value: "03-1887", in: candidates))
        #expect(partNumber.money == nil)
        #expect(partNumber.source == .documentOCR)
    }

    // MARK: - Negative keywords

    @Test("Tax, freight, shipping and handling are never the core credit")
    func ancillaryChargesAreNeverTheCoreCredit() throws {
        let candidates = OCRSuggestionExtractor.candidates(from: ancillaryChargeLines,
                                                           source: .documentOCR)

        let topAmount = try #require(candidates.first(where: { $0.kind == .coreAmount }))
        #expect(topAmount.normalizedValue == "86.50")

        let tax = try #require(candidate(.coreAmount, value: "7.35", in: candidates))
        #expect(tax.reason == "On a \"TAX\" line, which is rarely the core charge")

        let freight = try #require(candidate(.coreAmount, value: "19.95", in: candidates))
        #expect(freight.reason == "On a \"FREIGHT\" line, which is rarely the core charge")

        let shipping = try #require(candidate(.coreAmount, value: "12.00", in: candidates))
        #expect(shipping.reason == "On a \"SHIPPING\" line, which is rarely the core charge")

        let handling = try #require(candidate(.coreAmount, value: "4.25", in: candidates))
        #expect(handling.reason == "On a \"HANDLING\" line, which is rarely the core charge")

        for charge in [tax, freight, shipping, handling] {
            #expect(charge.band != .high)
            #expect(charge.band == .low)
            #expect(charge.isSafeToPreselect == false)
            #expect(charge.confidence < topAmount.confidence)
        }
    }

    // MARK: - Reasons and scores

    @Test("Every candidate carries a non-empty reason and a confidence inside zero through one")
    func everyCandidateExplainsItselfAndScoresInRange() {
        let fixtures = [invoiceLines, ancillaryChargeLines, labelledLines]

        for fixture in fixtures {
            let candidates = OCRSuggestionExtractor.candidates(from: fixture, source: .photoOCR)
            #expect(candidates.isEmpty == false)

            for proposal in candidates {
                #expect(proposal.reason.isEmpty == false)
                #expect(proposal.confidence >= 0)
                #expect(proposal.confidence <= 1)
                #expect(proposal.rawValue.isEmpty == false)
                #expect(proposal.normalizedValue.isEmpty == false)
                #expect(proposal.source == .photoOCR)
            }
        }
    }

    @Test("Nothing recognised produces nothing proposed")
    func nothingRecognisedProducesNothingProposed() {
        #expect(OCRSuggestionExtractor.candidates(from: [], source: .photoOCR).isEmpty)
        #expect(OCRSuggestionExtractor.candidates(
            from: [RecognizedLine(text: "   ", confidence: 0.9)],
            source: .photoOCR
        ).isEmpty)
    }

    // MARK: - Labels

    @Test("The labels on a parts invoice each produce the kind they name")
    func labelsProduceTheKindTheyName() throws {
        let candidates = OCRSuggestionExtractor.candidates(from: labelledLines, source: .documentOCR)

        let partNumber = try #require(candidate(.partNumber, value: "03-1887", in: candidates))
        #expect(partNumber.reason
            == "Alphanumeric with a hyphen, typical of a part number, on a line that names a part")
        #expect(partNumber.kind.coreItemField == .partNumber)

        let invoice = try #require(candidate(.invoiceNumber, value: "INV-100200", in: candidates))
        #expect(invoice.reason == "Follows the label \"INVOICE\"")
        #expect(invoice.kind.coreItemField == .invoiceReference)

        let repairOrder = try #require(candidate(.repairOrder, value: "4242", in: candidates))
        #expect(repairOrder.reason == "Follows the label \"RO\"")
        #expect(repairOrder.kind.coreItemField == .repairOrderReference)

        // An RMA is emphatically not an invoice number, so it lands in the notes rather than in a
        // field the vendor reconciles against.
        let returnReference = try #require(candidate(.returnReference, value: "88-77", in: candidates))
        #expect(returnReference.reason == "Follows the label \"RMA\"")
        #expect(returnReference.kind.coreItemField == .notes)

        let vendor = try #require(candidate(.vendorName, value: "ACME PARTS SUPPLY", in: candidates))
        #expect(vendor.kind.coreItemField == .vendor)

        // A value claimed by a label is never re-offered as something else.
        #expect(candidate(.partNumber, value: "4242", in: candidates) == nil)
        #expect(candidate(.partNumber, value: "88-77", in: candidates) == nil)
        #expect(candidate(.partNumber, value: "INV-100200", in: candidates) == nil)
    }
}
