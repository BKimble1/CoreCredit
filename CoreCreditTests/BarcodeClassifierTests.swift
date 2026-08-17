//
//  BarcodeClassifierTests.swift
//  CoreCreditTests
//
//  A UPC identifies a product. A part number is what the vendor's credit department matches a
//  returned core against. Pre-filling the part-number field with a UPC produces a return the vendor
//  rejects weeks later, so the classifier is only ever allowed to propose a part number when the
//  evidence actually says "part number": an alphanumeric linear symbology, or an unambiguous GS1
//  AI 240/241.
//
//  Every payload here is synthetic. No real vendor account number, no real catalogue number.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("A scanned symbol becomes a barcode value, and only sometimes a part number")
struct BarcodeClassifierTests {

    /// The separator a scanner emits in place of FNC1.
    private let groupSeparator = "\u{001D}"

    private func partNumbers(in candidates: [ScanCandidate]) -> [ScanCandidate] {
        candidates.filter { $0.kind == .partNumber }
    }

    // MARK: - Symbology classes

    @Test("Symbologies classify by family, however the raw value is spelled")
    func symbologiesClassifyByFamily() {
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyEAN13") == .linearNumeric)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyUPCE") == .linearNumeric)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyITF14") == .linearNumeric)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyCode128") == .linearAlphanumeric)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyCode39") == .linearAlphanumeric)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyCode39FullASCII") == .linearAlphanumeric)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyDataMatrix") == .twoDimensional)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyQR") == .twoDimensional)

        // A bare token classifies the same way as the framework's prefixed raw value.
        #expect(BarcodeSymbologyClass.classify("code128") == .linearAlphanumeric)
        #expect(BarcodeSymbologyClass.classify("") == .unknown)
        #expect(BarcodeSymbologyClass.classify("VNBarcodeSymbologyMadeUp") == .unknown)
    }

    // MARK: - Numeric product codes

    @Test("A numeric UPC or EAN stays a barcode and never becomes a part number")
    func aNumericProductCodeNeverBecomesAPartNumber() throws {
        let upc = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: "012345678905", symbology: "VNBarcodeSymbologyUPCE")
        )

        #expect(upc.count == 1)
        let upcBarcode = try #require(upc.first)
        #expect(upcBarcode.kind == .barcode)
        #expect(upcBarcode.rawValue == "012345678905")
        #expect(upcBarcode.normalizedValue == "012345678905")
        #expect(upcBarcode.barcodeSymbology == "VNBarcodeSymbologyUPCE")
        #expect(upcBarcode.reason.contains("product"))
        #expect(partNumbers(in: upc).isEmpty)

        let ean = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: "0123456789012", symbology: "VNBarcodeSymbologyEAN13")
        )

        #expect(ean.count == 1)
        let eanBarcode = try #require(ean.first)
        #expect(eanBarcode.kind == .barcode)
        #expect(eanBarcode.rawValue == "0123456789012")
        #expect(partNumbers(in: ean).isEmpty)

        // The barcode value fills no intake field on its own, so a confident read cannot pre-fill
        // the part number by the back door.
        #expect(ScanCandidateKind.barcode.coreItemField == nil)
    }

    @Test("A two-dimensional code with no GS1 structure offers no part number either")
    func aPlainTwoDimensionalCodeOffersNoPartNumber() {
        let candidates = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: "03-1887", symbology: "VNBarcodeSymbologyQR")
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.kind == .barcode)
        #expect(partNumbers(in: candidates).isEmpty)
    }

    // MARK: - Alphanumeric symbologies

    @Test("An alphanumeric Code 39 or Code 128 payload may rank as a part number but never as high")
    func anAlphanumericPayloadMayRankAsAPartNumberButNeverAsHigh() throws {
        let code128 = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: "03-1887", symbology: "VNBarcodeSymbologyCode128")
        )

        #expect(code128.count == 2)
        // Ranked highest confidence first: the machine-verified read, then the interpretation.
        #expect(code128.first?.kind == .barcode)

        let part = try #require(partNumbers(in: code128).first)
        #expect(part.rawValue == "03-1887")
        #expect(part.normalizedValue == "03-1887")
        #expect(part.confidence == 0.70)
        #expect(part.band == .medium)
        #expect(part.isSafeToPreselect == false)
        #expect(part.barcodeSymbology == "VNBarcodeSymbologyCode128")
        #expect(part.reason.isEmpty == false)
        #expect(part.alternatives == ["O3-1887", "03-I887"])

        // An all-digit payload in an alphanumeric symbology is weaker still — it may be a product
        // code printed in Code 39 — and says so.
        let code39 = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: "4471902", symbology: "VNBarcodeSymbologyCode39")
        )
        let digitsOnly = try #require(partNumbers(in: code39).first)
        #expect(digitsOnly.confidence == 0.55)
        #expect(digitsOnly.band == .medium)
        #expect(digitsOnly.isSafeToPreselect == false)
        #expect(digitsOnly.confidence < part.confidence)
    }

    // MARK: - GS1

    @Test("GS1 is parsed only when the structure is unambiguous, and nothing is stripped either way")
    func gs1IsParsedOnlyWhenUnambiguous() throws {
        // (a) Explicit separators are present, so the variable-length fields are delimited rather
        //     than guessed.
        let structured = "0109521234543213" + groupSeparator + "10LOT42" + groupSeparator + "240PN-4471"
        let elements = try #require(GS1Parser.parse(structured))

        #expect(elements.map(\.applicationIdentifier) == ["01", "10", "240"])
        #expect(elements.map(\.value) == ["09521234543213", "LOT42", "PN-4471"])
        #expect(GS1Parser.fixedLengthAIs["01"] == 14)

        // (b) A bare 12-digit numeric payload only *starts* with digits that resemble AI 01. AI 01
        //     needs 14 digits and 10 remain, so the parser refuses rather than deleting a prefix.
        #expect(GS1Parser.parse("012345678905") == nil)

        // A variable-length AI with no separator is equally unknowable, so it refuses too.
        #expect(GS1Parser.parse("10012345678902") == nil)

        // Fixed-length AIs that consume the payload exactly are the one separator-free case.
        let sscc = try #require(GS1Parser.parse("00123456789012345675"))
        #expect(sscc.map(\.applicationIdentifier) == ["00"])
        #expect(sscc.map(\.value) == ["123456789012345675"])

        // Nothing is stripped from the raw value in either case.
        let structuredCandidates = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: structured, symbology: "VNBarcodeSymbologyDataMatrix")
        )
        let structuredBarcode = try #require(structuredCandidates.first(where: { $0.kind == .barcode }))
        #expect(structuredBarcode.rawValue == structured)
        #expect(structuredBarcode.normalizedValue == "010952123454321310LOT42240PN-4471")

        let numericCandidates = BarcodePayloadClassifier.candidates(
            for: BarcodeScanInput(payload: "012345678905", symbology: "VNBarcodeSymbologyUPCE")
        )
        let numericBarcode = try #require(numericCandidates.first(where: { $0.kind == .barcode }))
        #expect(numericBarcode.rawValue == "012345678905")

        // AI 240 is "additional product identification" — the one field allowed to propose a part
        // number, and still only in the medium band.
        let gs1Part = try #require(partNumbers(in: structuredCandidates).first)
        #expect(gs1Part.rawValue == "PN-4471")
        #expect(gs1Part.normalizedValue == "PN-4471")
        #expect(gs1Part.confidence == 0.78)
        #expect(gs1Part.band == .medium)
        #expect(gs1Part.isSafeToPreselect == false)
        #expect(gs1Part.reason == "GS1 field 240 carries the manufacturer part number")
    }
}
