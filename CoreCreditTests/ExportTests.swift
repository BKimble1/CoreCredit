//
//  ExportTests.swift
//  CoreCreditTests
//
//  Required scenario 12: PDF, CSV, and JSON exports carry the expected references and amounts with
//  no floating-point corruption.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("Exports carry exact amounts and every reference a vendor needs")
struct ExportTests {

    private let received = TestClock.date(year: 2026, month: 3, day: 12)
    private let due = TestClock.date(year: 2026, month: 4, day: 11, hour: 0)
    private let returned = TestClock.date(year: 2026, month: 3, day: 14)
    private let credited = TestClock.date(year: 2026, month: 3, day: 20)

    // MARK: - Fixtures

    /// An alternator short-paid by $11.50, returned on batch RET-991 against invoice INV-552.
    private func shortPaidAlternator() -> CoreItemExportSnapshot {
        CoreItemExportSnapshot(
            identifier: UUID(),
            partName: "Alternator",
            partNumber: "03-1887",
            invoiceReference: "INV-552",
            repairOrderReference: "1024",
            creditReference: "CM-4471",
            notes: "Returned to vendor on batch RET-991.",
            binLabel: "A3",
            vendorName: "NAPA",
            vendorIdentifier: UUID(),
            status: .disputed,
            expectedCredit: Money(cents: 8_650),
            actualCredit: Money(cents: 7_500),
            receivedDate: received,
            dueDate: due,
            returnedDate: returned,
            creditedDate: credited,
            createdAt: received,
            updatedAt: credited,
            returnBatchReference: "RET-991",
            returnMethod: .driverPickup,
            events: [
                CoreEventSnapshot(timestamp: received, type: .created,
                                  detail: "Logged Alternator.", amount: Money(cents: 8_650),
                                  reference: "INV-552", fromStatus: nil, toStatus: .awaitingCore),
                CoreEventSnapshot(timestamp: returned, type: .returned,
                                  detail: "Returned to NAPA.", amount: Money(cents: 8_650),
                                  reference: "RET-991", fromStatus: .readyToReturn,
                                  toStatus: .returnedAwaitingCredit),
                CoreEventSnapshot(timestamp: credited, type: .creditRecorded,
                                  detail: "Vendor credit recorded.", amount: Money(cents: 7_500),
                                  reference: "CM-4471", fromStatus: .returnedAwaitingCredit,
                                  toStatus: .disputed)
            ]
        )
    }

    private var shop: ShopProfileSnapshot {
        ShopProfileSnapshot(name: "Sample Auto Service",
                            phone: "555-0142",
                            email: "sample@example.com",
                            addressLines: ["18 Shop Lane", "Columbus, OH 43004"],
                            currencyCode: "USD")
    }

    // MARK: - CSV

    @Test("The CSV carries the exact amount and every reference the vendor needs")
    func csvCarriesExactAmountsAndReferences() {
        let csv = CSVLedgerExporter.makeCSV(items: [shortPaidAlternator()], currencyCode: "USD")

        #expect(csv.contains("86.50"))
        #expect(csv.contains("INV-552"))
        #expect(csv.contains("RET-991"))
        #expect(csv.contains("1024"))
        #expect(csv.contains("CM-4471"))
        #expect(csv.contains("A3"))

        // Whole cells, so a value can never be a fragment of a longer number.
        #expect(csv.contains(",86.50,"))
        #expect(csv.contains(",75.00,"))
        #expect(csv.contains(",11.50,"))
    }

    @Test("No export string ever carries a floating-point artefact")
    func csvNeverCarriesAFloatArtefact() {
        let csv = CSVLedgerExporter.makeCSV(items: [shortPaidAlternator()], currencyCode: "USD")
        for artefact in floatingPointArtefacts {
            #expect(csv.contains(artefact) == false)
        }
        #expect(csv.contains("86.499") == false)
        #expect(csv.contains("86.501") == false)
    }

    @Test("The CSV header row is the contracted column order")
    func csvHeaderRowIsTheContractedOrder() {
        let csv = CSVLedgerExporter.makeCSV(items: [], currencyCode: "USD")
        let rows = csvRows(csv)

        #expect(rows.count == 1)
        #expect(rows.first == CSVLedgerExporter.headerRow.joined(separator: ","))
        #expect(CSVLedgerExporter.headerRow.count == 16)
        #expect(CSVLedgerExporter.headerRow.first == "Part")
        #expect(CSVLedgerExporter.headerRow.last == "Notes")
    }

    @Test("One core produces exactly one data row after the header")
    func oneCoreProducesOneDataRow() {
        let csv = CSVLedgerExporter.makeCSV(items: [shortPaidAlternator()], currencyCode: "USD")
        #expect(csvRows(csv).count == 2)
        #expect(csv.hasSuffix(CSVLedgerExporter.lineTerminator))
    }

    @Test("RFC 4180 quoting covers commas, quotes, and line breaks")
    func escapingFollowsRFC4180() {
        #expect(CSVLedgerExporter.escape("plain") == "plain")
        #expect(CSVLedgerExporter.escape("86.50") == "86.50")
        #expect(CSVLedgerExporter.escape("Alternator, rebuilt") == "\"Alternator, rebuilt\"")
        #expect(CSVLedgerExporter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVLedgerExporter.escape("line one\nline two") == "\"line one\nline two\"")
    }

    @Test("A text cell that starts like a spreadsheet formula is defused")
    func formulaLookingTextIsDefused() {
        var dangerous = shortPaidAlternator()
        dangerous.partName = "=cmd|calc"

        let csv = CSVLedgerExporter.makeCSV(items: [dangerous], currencyCode: "USD")
        #expect(csv.contains("'=cmd|calc"))
    }

    @Test("A negative discrepancy keeps its minus sign and stays numeric")
    func negativeDiscrepanciesStayNumeric() {
        var overCredited = shortPaidAlternator()
        overCredited.expectedCredit = Money(cents: 7_500)
        overCredited.actualCredit = Money(cents: 8_650)

        let csv = CSVLedgerExporter.makeCSV(items: [overCredited], currencyCode: "USD")
        #expect(csv.contains(",-11.50,"))
        #expect(csv.contains(",'-11.50,") == false)
    }

    // MARK: - JSON

    @Test("A JSON backup round-trips with money preserved as exact integer cents")
    func jsonRoundTripsMoneyAsIntegerCents() throws {
        let item = shortPaidAlternator()
        let payload = BackupPayload(
            formatVersion: BackupPayload.currentFormatVersion,
            appVersion: "1.0",
            exportedAt: credited,
            shop: shop,
            vendors: [VendorSnapshot(name: "NAPA", defaultReturnWindowDays: 30)],
            bins: [StorageBinSnapshot(label: "A3", locationNote: "Back wall")],
            items: [item],
            batches: [ReturnBatchSnapshot(vendorName: "NAPA", returnDate: returned,
                                          method: .driverPickup, reference: "RET-991",
                                          itemIdentifiers: [item.identifier])]
        )

        let data = try JSONBackupExporter.encode(payload)
        let text = utf8Text(data)

        #expect(text.contains("\"cents\""))
        #expect(text.contains("8650"))
        #expect(text.contains("7500"))
        #expect(text.contains("INV-552"))
        #expect(text.contains("RET-991"))

        // Money is never written as a decimal number, so no float artefact can exist.
        #expect(text.contains("86.5") == false)
        for artefact in floatingPointArtefacts {
            #expect(text.contains(artefact) == false)
        }

        let decoded = try JSONBackupExporter.decode(data)
        #expect(decoded.formatVersion == 1)
        #expect(decoded.appVersion == "1.0")
        #expect(decoded.items.count == 1)

        let restored = try #require(decoded.items.first)
        #expect(restored.expectedCredit == Money(cents: 8_650))
        #expect(restored.expectedCredit.cents == 8_650)
        #expect(restored.actualCredit == Money(cents: 7_500))
        #expect(restored.invoiceReference == "INV-552")
        #expect(restored.returnBatchReference == "RET-991")
        #expect(restored.returnMethod == .driverPickup)
        #expect(restored.status == .disputed)
        #expect(restored.events.count == 3)
        #expect(restored.events.contains(where: { $0.amount == Money(cents: 7_500) }))
        #expect(RiskCalculator.discrepancy(for: restored) == Money(cents: 1_150))
        #expect(decoded.batches.first?.reference == "RET-991")
    }

    @Test("An empty backup file is refused")
    func anEmptyBackupIsRefused() {
        #expect(throws: ExportError.noData) {
            try JSONBackupExporter.decode(Data())
        }
    }

    @Test("A backup written by a newer build is refused rather than half-imported")
    func aNewerBackupFormatIsRefused() throws {
        let future = BackupPayload(formatVersion: BackupPayload.currentFormatVersion + 1,
                                   appVersion: "9.9",
                                   exportedAt: credited)
        let data = try JSONBackupExporter.encode(future)

        #expect(throws: ExportError.self) {
            try JSONBackupExporter.decode(data)
        }
    }

    @Test("Damaged JSON is refused with a readable message")
    func damagedJSONIsRefused() {
        #expect(throws: ExportError.self) {
            try JSONBackupExporter.decode(Data("{ not json".utf8))
        }
    }

    // MARK: - PDF

    @MainActor
    @Test("The dispute packet renders real PDF bytes")
    func disputePacketRendersPDFBytes() throws {
        let data = try DisputePacketBuilder.makePDFData(item: shortPaidAlternator(),
                                                        shop: shop,
                                                        images: [],
                                                        generatedAt: credited)

        #expect(data.isEmpty == false)
        #expect(Array(data.prefix(4)) == Array("%PDF".utf8))
    }

    @MainActor
    @Test("The ledger report renders real PDF bytes for an empty and a populated ledger")
    func ledgerReportRendersPDFBytes() throws {
        let items = [shortPaidAlternator()]
        let summary = RiskCalculator.summarize(items, now: credited, calendar: TestClock.calendar)

        let populated = try DisputePacketBuilder.makeLedgerPDFData(items: items,
                                                                   shop: shop,
                                                                   summary: summary,
                                                                   generatedAt: credited)
        #expect(populated.isEmpty == false)
        #expect(Array(populated.prefix(4)) == Array("%PDF".utf8))

        let empty = try DisputePacketBuilder.makeLedgerPDFData(items: [],
                                                               shop: .placeholder,
                                                               summary: .empty,
                                                               generatedAt: credited)
        #expect(empty.isEmpty == false)
        #expect(Array(empty.prefix(4)) == Array("%PDF".utf8))
    }

    // MARK: - Snapshots from live models

    @MainActor
    @Test("A live core item freezes into a snapshot the exporters can use")
    func liveCoreItemsFreezeIntoSnapshots() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let bin = makeBin(context: context, label: "A3")
        let item = try makeItem(context: context, service: itemService,
                                partName: "Alternator", amountCents: 8_650,
                                vendor: napa, bin: bin,
                                invoiceReference: "INV-552", repairOrderReference: "1024")

        try batchService.createBatch(vendor: napa, items: [item], returnDate: returned,
                                     method: .driverPickup, reference: "RET-991", notes: "")
        try itemService.recordCredit(item, reconciliation: CreditReconciliation(
            creditDate: credited, reference: "CM-4471", amount: Money(cents: 7_500)))

        let snapshot = SnapshotBuilder.snapshot(item)
        #expect(snapshot.identifier == item.id)
        #expect(snapshot.partName == "Alternator")
        #expect(snapshot.expectedCredit == Money(cents: 8_650))
        #expect(snapshot.actualCredit == Money(cents: 7_500))
        #expect(snapshot.status == .disputed)
        #expect(snapshot.vendorName == "NAPA")
        #expect(snapshot.binLabel == "A3")
        #expect(snapshot.invoiceReference == "INV-552")
        #expect(snapshot.repairOrderReference == "1024")
        #expect(snapshot.returnBatchReference == "RET-991")
        #expect(snapshot.returnMethod == .driverPickup)
        #expect(snapshot.events.isEmpty == false)

        let csv = CSVLedgerExporter.makeCSV(items: [snapshot], currencyCode: "USD")
        #expect(csv.contains(",86.50,"))
        #expect(csv.contains("INV-552"))
        #expect(csv.contains("RET-991") == false)   // the CSV has no return-batch column
    }

    @MainActor
    @Test("A shop profile freezes into printable letterhead lines")
    func shopProfilesFreezeIntoLetterheadLines() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let profile = try service.shopProfile()
        profile.name = "Sample Auto Service"
        profile.phone = "555-0142"
        profile.email = "sample@example.com"
        profile.addressLine1 = "18 Shop Lane"
        profile.city = "Columbus"
        profile.region = "OH"
        profile.postalCode = "43004"
        try service.updateShopProfile(profile)

        let snapshot = SnapshotBuilder.snapshot(profile)
        #expect(snapshot.name == "Sample Auto Service")
        #expect(snapshot.addressLines == ["18 Shop Lane", "Columbus, OH 43004"])
        #expect(snapshot.contactSummary == "555-0142 \u{2022} sample@example.com")
        #expect(snapshot.displayName == "Sample Auto Service")
        #expect(ShopProfileSnapshot.placeholder.displayName == "Your shop")
    }

    // MARK: - Export file store

    @Test("Export kinds carry their extension and uniform type identifier")
    func exportKindsCarryTheirIdentifiers() {
        #expect(ExportKind.pdf.fileExtension == "pdf")
        #expect(ExportKind.csv.fileExtension == "csv")
        #expect(ExportKind.json.fileExtension == "json")
        #expect(ExportKind.pdf.utTypeIdentifier == "com.adobe.pdf")
        #expect(ExportKind.csv.utTypeIdentifier == "public.comma-separated-values-text")
        #expect(ExportKind.json.utTypeIdentifier == "public.json")
    }

    @Test("File names are sanitised into something safe to put in a path")
    func fileNamesAreSanitised() {
        #expect(ExportFileStore.sanitizedFileName("Bob's Auto / Body") == "Bob-s-Auto-Body")
        #expect(ExportFileStore.sanitizedFileName("CoreCredit-Ledger-2026-08-16")
            == "CoreCredit-Ledger-2026-08-16")
        #expect(ExportFileStore.sanitizedFileName("   ///   ") == ExportFileStore.fallbackBaseName)
        #expect(ExportFileStore.sanitizedFileName("") == ExportFileStore.fallbackBaseName)
        #expect(ExportFileStore.sanitizedFileName(String(repeating: "a", count: 200)).count
            == ExportFileStore.maximumBaseNameLength)
    }

    @Test("Writing an export produces a shareable document, and empty data is refused")
    func writingAnExportProducesAShareableDocument() throws {
        let csv = CSVLedgerExporter.makeCSV(items: [shortPaidAlternator()], currencyCode: "USD")
        let document = try ExportFileStore.write(Data(csv.utf8),
                                                 baseName: "CoreCredit Test Ledger",
                                                 kind: .csv)
        defer { try? FileManager.default.removeItem(at: document.url) }

        #expect(document.kind == .csv)
        #expect(document.suggestedName.hasSuffix(".csv"))
        #expect(document.suggestedName.hasPrefix("CoreCredit-Test-Ledger"))
        #expect(FileManager.default.fileExists(atPath: document.url.path(percentEncoded: false)))

        let readBack = try Data(contentsOf: document.url)
        #expect(utf8Text(readBack).contains("86.50"))

        #expect(throws: ExportError.noData) {
            try ExportFileStore.write(Data(), baseName: "Nothing", kind: .json)
        }
    }

    @Test("Export failures read as sentences, not error codes")
    func exportErrorsReadAsSentences() {
        #expect(ExportError.noData.errorDescription == "There is nothing to export yet.")
        #expect(ExportError.renderingFailed("   ").errorDescription == "The file could not be created.")
        #expect(ExportError.renderingFailed("Disk is full.").errorDescription == "Disk is full.")
        #expect(ExportError.writeFailed("").errorDescription
            == "The file could not be saved to this device.")
    }
}
