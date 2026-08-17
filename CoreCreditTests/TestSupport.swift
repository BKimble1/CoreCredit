//
//  TestSupport.swift
//  CoreCreditTests
//
//  Shared fixtures for the CoreCredit unit test suite.
//
//  Two rules hold everywhere in this target:
//
//  1. **No test reads the wall clock.** Every date comes from `TestClock`, which is built on the
//     app's own `FixedDateProvider` pinned to a Gregorian/UTC/POSIX calendar. A test that passes in
//     Columbus passes in Auckland.
//  2. **No force unwraps.** Optional results are unwrapped with `try #require(...)`, and the few
//     helpers that build a date fall back to a deterministic value rather than trapping.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

// MARK: - Deterministic clock

/// The single source of time for the whole test target.
enum TestClock {

    /// Gregorian, `TimeZone(secondsFromGMT: 0)`, `en_US_POSIX` — the app's own test calendar.
    static let calendar: Calendar = FixedDateProvider.utcCalendar

    /// A provider frozen at midday UTC on the given day.
    static func provider(year: Int, month: Int, day: Int, hour: Int = 12) -> FixedDateProvider {
        FixedDateProvider(year: year, month: month, day: day, hour: hour, calendar: TestClock.calendar)
    }

    /// An instant on the given day, at `hour:00:00` UTC.
    static func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        TestClock.provider(year: year, month: month, day: day, hour: hour).now
    }

    /// An instant on the given day, at `hour:minute:00` UTC.
    ///
    /// Falls back to the same day at `hour:00` if the components cannot be resolved, which cannot
    /// happen for the hard-coded values used in these tests but keeps the helper free of `!`.
    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return TestClock.calendar.date(from: components)
            ?? TestClock.date(year: year, month: month, day: day, hour: hour)
    }

    /// The instant every fixture is anchored to: **12 March 2026, 12:00 UTC**.
    static let referenceProvider = TestClock.provider(year: 2026, month: 3, day: 12)

    /// `referenceProvider.now`.
    static let referenceNow = TestClock.referenceProvider.now
}

// MARK: - Pure-domain fixture

/// A plain value conforming to `CoreItemRepresenting`.
///
/// Lets the calculator, filter, planner, and reconciliation tests run with no `ModelContainer` and
/// no SwiftData at all. Property order mirrors `CoreItemRepresenting` so the synthesised memberwise
/// initialiser reads in the same order the protocol declares.
struct TestItem: CoreItemRepresenting {
    var identifier: UUID = UUID()
    var partName: String = "Alternator"
    var partNumber: String = "03-1887"
    var invoiceReference: String = ""
    var repairOrderReference: String = ""
    var creditReference: String = ""
    var notes: String = ""
    var binLabel: String?
    var vendorName: String?
    var vendorIdentifier: UUID?
    var status: CoreStatus = .awaitingCore
    var expectedCredit: Money = Money(cents: 8_650)
    var actualCredit: Money?
    var receivedDate: Date = TestClock.referenceNow
    var dueDate: Date?
    var returnedDate: Date?
    var creditedDate: Date?
    var createdAt: Date = TestClock.referenceNow
}

// MARK: - Store helpers

/// A `ModelContext` over a fresh in-memory container built from the current (V2) schema.
///
/// The returned context keeps its container alive, so callers only need to hold the context.
@MainActor
func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema(versionedSchema: CoreCreditSchemaV2.self)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: schema,
        migrationPlan: CoreCreditMigrationPlan.self,
        configurations: configuration
    )
    return ModelContext(container)
}

/// A `CoreItemService` wired to the frozen clock.
@MainActor
func makeItemService(context: ModelContext,
                     provider: FixedDateProvider = TestClock.referenceProvider) -> CoreItemService {
    CoreItemService(context: context, dateProvider: provider)
}

/// A `ReturnBatchService` wired to the frozen clock.
@MainActor
func makeBatchService(context: ModelContext,
                      provider: FixedDateProvider = TestClock.referenceProvider) -> ReturnBatchService {
    ReturnBatchService(context: context, dateProvider: provider)
}

/// A unique, empty directory under the system temporary directory. Callers delete it afterwards.
func makeTemporaryDirectory() throws -> URL {
    let directory = URL.temporaryDirectory
        .appending(path: "CoreCreditTests-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Model factories

/// Inserts a vendor. Not saved — the item factory's `createItem` call saves the context.
@MainActor
@discardableResult
func makeVendor(context: ModelContext,
                name: String = "NAPA",
                windowDays: Int = 30) -> Vendor {
    let vendor = Vendor(name: name, defaultReturnWindowDays: windowDays, now: TestClock.referenceNow)
    context.insert(vendor)
    return vendor
}

/// Inserts a storage bin.
@MainActor
@discardableResult
func makeBin(context: ModelContext,
             label: String = "A3",
             locationNote: String = "Back wall, top shelf") -> StorageBin {
    let bin = StorageBin(label: label, locationNote: locationNote, now: TestClock.referenceNow)
    context.insert(bin)
    return bin
}

/// Creates a core item **through the service**, so validation, the due date, and the `.created`
/// event all happen exactly as they do in the app.
///
/// When `vendor` is `nil` a default "NAPA" vendor is inserted, because the validator refuses a
/// draft with no vendor.
@MainActor
@discardableResult
func makeItem(context: ModelContext,
              service: CoreItemService,
              partName: String = "Alternator",
              amountCents: Int64 = 8_650,
              vendor: Vendor? = nil,
              bin: StorageBin? = nil,
              partNumber: String = "03-1887",
              invoiceReference: String = "",
              repairOrderReference: String = "",
              notes: String = "",
              receivedDate: Date = TestClock.referenceNow) throws -> CoreItem {

    let resolvedVendor = vendor ?? makeVendor(context: context)
    let draft = CoreItemDraft(
        partName: partName,
        partNumber: partNumber,
        vendorIdentifier: resolvedVendor.id,
        binIdentifier: bin?.id,
        expectedCreditText: Money(cents: amountCents).plainDecimalString,
        invoiceReference: invoiceReference,
        repairOrderReference: repairOrderReference,
        receivedDate: receivedDate,
        notes: notes
    )
    return try service.createItem(from: draft, vendor: resolvedVendor, bin: bin)
}

/// Walks a freshly created item all the way to `.credited` with an exact credit.
@MainActor
func creditInFull(_ item: CoreItem,
                  service: CoreItemService,
                  reference: String = "CM-0001") throws {
    if item.status == .awaitingCore {
        try service.transition(item, to: .readyToReturn, detail: nil)
    }
    if item.status == .readyToReturn {
        try service.transition(item, to: .returnedAwaitingCredit, detail: nil)
    }
    let reconciliation = CreditReconciliation(
        creditDate: TestClock.referenceNow,
        reference: reference,
        amount: item.expectedCredit
    )
    try service.recordCredit(item, reconciliation: reconciliation)
}

// MARK: - Text helpers

/// The non-empty records of a CSV document, header row included.
func csvRows(_ csv: String) -> [String] {
    csv.components(separatedBy: CSVLedgerExporter.lineTerminator).filter { !$0.isEmpty }
}

/// Decodes export bytes as UTF-8 for substring assertions.
func utf8Text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

/// Float artefacts that must never appear in an export of `$86.50`.
let floatingPointArtefacts = ["86.499999", "86.5000001", "86.49999999999999", "86.50000000000001"]
