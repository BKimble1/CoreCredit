//
//  ScannedBarcodeTests.swift
//  CoreCreditTests
//
//  The raw barcode payload, and the line between it and the confirmed part number.
//
//  A scan of a parts box very often returns a UPC or an EAN — a retail code identifying the
//  packaging, not the manufacturer's part number. `BarcodePayloadClassifier` refuses to offer one
//  as a part number for that reason, and `CoreItem` keeps the payload in its own property so that
//  "did the scanner misread it, or did somebody change it?" is still answerable months later.
//
//  This suite holds that line at the persistence layer: the payload round-trips, clearing it is an
//  audited mutation through the service, and neither operation is ever allowed to touch
//  `partNumber`.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("A scanned barcode is evidence, kept apart from the confirmed part number")
struct ScannedBarcodeTests {

    // MARK: - It survives a write

    @Test("A scanned payload and its symbology persist alongside a different part number")
    @MainActor
    func aScannedPayloadPersistsAlongsideTheConfirmedPartNumber() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        var draft = CoreItemDraft(
            partName: "Alternator",
            partNumber: "03-1887",
            vendorIdentifier: vendor.id,
            expectedCreditText: "86.50",
            receivedDate: TestClock.referenceNow
        )
        // A UPC-A read off the box. Vision reports UPC-A as EAN-13.
        draft.scannedBarcodeValue = "0123456789012"
        draft.scannedBarcodeSymbology = "VNBarcodeSymbologyEAN13"

        let item = try service.createItem(from: draft, vendor: vendor, bin: nil)

        #expect(item.scannedBarcodeValue == "0123456789012")
        #expect(item.scannedBarcodeSymbology == "VNBarcodeSymbologyEAN13")

        // The whole point: the payload did not become the part number.
        #expect(item.partNumber == "03-1887")
        #expect(item.partNumber != item.scannedBarcodeValue)
    }

    @Test("A numeric product code is never classified as a part number")
    func aNumericProductCodeIsNeverAPartNumber() {
        // The detail screen labels the payload by this classification, so a UPC reads as a
        // "Numeric product code" rather than as anything resembling a part number.
        let ean = BarcodeSymbologyClass.classify("VNBarcodeSymbologyEAN13")
        #expect(ean == .linearNumeric)
        #expect(ean.displayName == "Numeric product code")

        let input = BarcodeScanInput(payload: "0123456789012",
                                     symbology: "VNBarcodeSymbologyEAN13")
        let candidates = BarcodePayloadClassifier.candidates(for: input)

        #expect(candidates.isEmpty == false)
        #expect(candidates.contains { $0.kind == .barcode })
        #expect(candidates.contains { $0.kind == .partNumber } == false,
                "A retail product code must never be offered as a manufacturer part number.")
    }

    // MARK: - Clearing it

    @Test("Clearing the barcode removes the payload, keeps the part number, and is audited")
    @MainActor
    func clearingTheBarcodeIsAuditedAndKeepsThePartNumber() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        var draft = CoreItemDraft(
            partName: "Starter",
            partNumber: "17-4420",
            vendorIdentifier: vendor.id,
            expectedCreditText: "54.00",
            receivedDate: TestClock.referenceNow
        )
        draft.scannedBarcodeValue = "17-4420-XYZ"
        draft.scannedBarcodeSymbology = "VNBarcodeSymbologyCode128"

        let item = try service.createItem(from: draft, vendor: vendor, bin: nil)
        let eventsBefore = item.events?.count ?? 0

        try service.clearScannedBarcode(item)

        #expect(item.scannedBarcodeValue == nil)
        #expect(item.scannedBarcodeSymbology == nil)
        #expect(item.partNumber == "17-4420", "Clearing the evidence must not clear the number.")

        // The append-only timeline is the reason this goes through the service at all.
        let events = item.events ?? []
        #expect(events.count == eventsBefore + 1)
        let latest = try #require(events.max(by: { $0.timestamp < $1.timestamp }))
        #expect(latest.type == .edited)
        #expect(latest.detail.contains("17-4420-XYZ"),
                "The audit entry has to say what was removed, or it is not evidence of anything.")
    }

    @Test("Clearing a core that has no barcode writes nothing at all")
    @MainActor
    func clearingWithNoBarcodeIsANoOp() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service)

        let eventsBefore = item.events?.count ?? 0
        #expect(item.scannedBarcodeValue == nil)

        // A double tap, or a stale screen. Neither may append a second event.
        try service.clearScannedBarcode(item)
        try service.clearScannedBarcode(item)

        #expect(item.events?.count == eventsBefore)
    }

    @Test("Clearing twice after a real payload still writes only one event")
    @MainActor
    func clearingTwiceWritesOneEvent() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        var draft = CoreItemDraft(
            partName: "Water pump",
            partNumber: "WP-9021",
            vendorIdentifier: vendor.id,
            expectedCreditText: "31.50",
            receivedDate: TestClock.referenceNow
        )
        draft.scannedBarcodeValue = "WP-9021"
        let item = try service.createItem(from: draft, vendor: vendor, bin: nil)
        let eventsBefore = item.events?.count ?? 0

        try service.clearScannedBarcode(item)
        try service.clearScannedBarcode(item)

        #expect(item.events?.count == eventsBefore + 1)
    }

    // MARK: - Editing

    @Test("Editing a core carries the payload through untouched")
    @MainActor
    func editingCarriesThePayloadThrough() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        var draft = CoreItemDraft(
            partName: "A/C compressor",
            partNumber: "AC-7714",
            vendorIdentifier: vendor.id,
            expectedCreditText: "125.00",
            receivedDate: TestClock.referenceNow
        )
        draft.scannedBarcodeValue = "AC-7714-RAW"
        draft.scannedBarcodeSymbology = "VNBarcodeSymbologyCode39"
        let item = try service.createItem(from: draft, vendor: vendor, bin: nil)

        // The editor rebuilds its draft from the record; a round trip must not lose the payload,
        // or the detail screen's Barcode card would vanish the first time somebody fixed a typo.
        var edited = service.draft(for: item)
        edited.partName = "A/C compressor, reman"
        try service.update(item, from: edited, vendor: vendor, bin: nil)

        #expect(item.partName == "A/C compressor, reman")
        #expect(item.scannedBarcodeValue == "AC-7714-RAW")
        #expect(item.scannedBarcodeSymbology == "VNBarcodeSymbologyCode39")
    }

    // MARK: - Identifiers

    @Test("The barcode card's identifiers are stable")
    func theBarcodeIdentifiersAreStable() {
        #expect(A11y.Detail.copyBarcode == "detail.copyBarcode")
        #expect(A11y.Detail.clearBarcode == "detail.clearBarcode")
    }
}
