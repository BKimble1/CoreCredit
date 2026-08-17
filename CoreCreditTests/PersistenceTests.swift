//
//  PersistenceTests.swift
//  CoreCreditTests
//
//  Required scenario 11: data survives an app relaunch. The test writes through one container on a
//  file-backed store in a unique temporary directory, drops it, opens a second container at the
//  same URL, and reads the record back.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("Persistence, the item service, and draft validation")
struct PersistenceTests {

    private let calendar = TestClock.calendar

    // MARK: - Scenario 11

    @MainActor
    @Test("Data survives an app relaunch")
    func dataSurvivesAnAppRelaunch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "CoreCredit.store", directoryHint: .notDirectory)
        let schema = Schema(versionedSchema: CoreCreditSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)

        // First launch: write the ledger, then let the container go out of scope.
        func firstLaunch() throws {
            let container = try ModelContainer(for: schema,
                                               migrationPlan: CoreCreditMigrationPlan.self,
                                               configurations: configuration)
            let context = ModelContext(container)

            let napa = Vendor(name: "NAPA", defaultReturnWindowDays: 30, now: TestClock.referenceNow)
            context.insert(napa)

            let item = CoreItem(partName: "Alternator",
                                expectedCredit: Money(cents: 8_650),
                                receivedDate: TestClock.referenceNow,
                                vendor: napa,
                                now: TestClock.referenceNow)
            item.partNumber = "03-1887"
            item.invoiceReference = "INV-552"
            item.dueDate = DueDateCalculator.dueDate(receivedDate: TestClock.referenceNow,
                                                     windowDays: 30,
                                                     calendar: calendar)
            context.insert(item)
            try context.save()
        }

        try firstLaunch()
        #expect(FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))

        // Second launch: a brand-new container over the same file.
        let reopened = try ModelContainer(for: schema,
                                          migrationPlan: CoreCreditMigrationPlan.self,
                                          configurations: configuration)
        let reopenedContext = ModelContext(reopened)
        let restoredItems = try reopenedContext.fetch(FetchDescriptor<CoreItem>())

        #expect(restoredItems.count == 1)
        let restored = try #require(restoredItems.first)
        #expect(restored.partName == "Alternator")
        #expect(restored.partNumber == "03-1887")
        #expect(restored.invoiceReference == "INV-552")
        #expect(restored.expectedCreditCents == 8_650)
        #expect(restored.expectedCredit == Money(cents: 8_650))
        #expect(restored.status == .awaitingCore)
        #expect(restored.vendor?.name == "NAPA")
        #expect(restored.dueDate == TestClock.date(year: 2026, month: 4, day: 11, hour: 0))

        let restoredVendors = try reopenedContext.fetch(FetchDescriptor<Vendor>())
        #expect(restoredVendors.count == 1)
    }

    // MARK: - Schema V1 -> V2 compatibility

    @MainActor
    @Test("A store written before the scanned-barcode fields existed still opens, reading them as nil")
    func aStoreWrittenBeforeTheScannedBarcodeFieldsStillOpens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "CoreCredit.store", directoryHint: .notDirectory)

        // First launch: the shape a TestFlight build wrote, under the V1 versioned schema. Nothing
        // here ever sets `scannedBarcodeValue` or `scannedBarcodeSymbology` — they did not exist.
        func firstLaunch() throws {
            let schema = Schema(versionedSchema: CoreCreditSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema,
                                               migrationPlan: CoreCreditMigrationPlan.self,
                                               configurations: configuration)
            let context = ModelContext(container)

            let napa = Vendor(name: "NAPA", defaultReturnWindowDays: 30, now: TestClock.referenceNow)
            context.insert(napa)

            let item = CoreItem(partName: "Alternator",
                                expectedCredit: Money(cents: 8_650),
                                receivedDate: TestClock.referenceNow,
                                vendor: napa,
                                now: TestClock.referenceNow)
            item.partNumber = "03-1887"
            item.invoiceReference = "INV-552"
            context.insert(item)
            try context.save()
        }

        try firstLaunch()

        // Second launch: the shipping schema, opened through the lightweight V1 -> V2 stage. The
        // existing row must survive untouched, with the two new attributes reading back as nil.
        let currentSchema = Schema(versionedSchema: CoreCreditSchemaV2.self)
        let currentConfiguration = ModelConfiguration(schema: currentSchema, url: storeURL)
        let reopened = try ModelContainer(for: currentSchema,
                                          migrationPlan: CoreCreditMigrationPlan.self,
                                          configurations: currentConfiguration)
        let reopenedContext = ModelContext(reopened)
        let restoredItems = try reopenedContext.fetch(FetchDescriptor<CoreItem>())

        #expect(restoredItems.count == 1)
        let restored = try #require(restoredItems.first)
        #expect(restored.partName == "Alternator")
        #expect(restored.partNumber == "03-1887")
        #expect(restored.invoiceReference == "INV-552")
        #expect(restored.expectedCredit == Money(cents: 8_650))
        #expect(restored.vendor?.name == "NAPA")
        #expect(restored.scannedBarcodeValue == nil)
        #expect(restored.scannedBarcodeSymbology == nil)

        // The plan itself: two versions, one additive stage between them.
        #expect(CoreCreditMigrationPlan.schemas.count == 2)
        #expect(CoreCreditMigrationPlan.stages.count == 1)
    }

    // MARK: - Creating items

    @MainActor
    @Test("Creating a core persists it and opens its timeline with a created event")
    func creatingACorePersistsItAndOpensItsTimeline() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let item = try makeItem(context: context, service: service,
                                partName: "  Alternator  ", amountCents: 8_650,
                                invoiceReference: " INV-552 ")

        #expect(item.partName == "Alternator")
        #expect(item.invoiceReference == "INV-552")
        #expect(item.expectedCredit == Money(cents: 8_650))
        #expect(item.createdAt == TestClock.referenceNow)
        #expect(item.updatedAt == TestClock.referenceNow)

        let created = item.timeline.filter { $0.type == .created }
        #expect(created.count == 1)
        #expect(created.contains(where: { $0.amount == Money(cents: 8_650) }))
        #expect(created.contains(where: { $0.toStatus == .awaitingCore }))

        let stored = try service.allItems()
        #expect(stored.count == 1)
        #expect(try service.item(with: item.id)?.id == item.id)
        #expect(try service.item(with: UUID()) == nil)
    }

    @MainActor
    @Test("A new core takes its due date from the vendor's return window")
    func aNewCoreTakesItsDueDateFromTheVendorWindow() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let quickVendor = makeVendor(context: context, name: "O'Reilly", windowDays: 14)
        let item = try makeItem(context: context, service: service, vendor: quickVendor)

        #expect(item.usesCustomDueDate == false)
        #expect(item.dueDate == TestClock.date(year: 2026, month: 3, day: 26, hour: 0))
    }

    @MainActor
    @Test("A pinned custom due date beats the vendor window")
    func aPinnedCustomDueDateWins() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        let draft = CoreItemDraft(partName: "Alternator",
                                  vendorIdentifier: vendor.id,
                                  expectedCreditText: "86.50",
                                  receivedDate: TestClock.referenceNow,
                                  usesCustomDueDate: true,
                                  customDueDate: TestClock.date(year: 2026, month: 3, day: 20, hour: 18))
        let item = try service.createItem(from: draft, vendor: vendor, bin: nil)

        #expect(item.usesCustomDueDate)
        #expect(item.dueDate == TestClock.date(year: 2026, month: 3, day: 20, hour: 0))
    }

    @MainActor
    @Test("Changing a vendor's return window refreshes the due dates of its open cores")
    func changingAVendorWindowRefreshesOpenDueDates() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let item = try makeItem(context: context, service: service, vendor: napa)
        #expect(item.dueDate == TestClock.date(year: 2026, month: 4, day: 11, hour: 0))

        napa.defaultReturnWindowDays = 14
        try service.updateVendor(napa)

        #expect(napa.defaultReturnWindowDays == 14)
        #expect(item.dueDate == TestClock.date(year: 2026, month: 3, day: 26, hour: 0))
    }

    @MainActor
    @Test("Recalculating a due date is a no-op for a core with a pinned date")
    func recalculatingSkipsPinnedDueDates() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context, windowDays: 30)

        let draft = CoreItemDraft(partName: "Alternator",
                                  vendorIdentifier: vendor.id,
                                  expectedCreditText: "86.50",
                                  receivedDate: TestClock.referenceNow,
                                  usesCustomDueDate: true,
                                  customDueDate: TestClock.date(year: 2026, month: 3, day: 20))
        let item = try service.createItem(from: draft, vendor: vendor, bin: nil)

        service.recalculateDueDate(for: item)
        #expect(item.dueDate == TestClock.date(year: 2026, month: 3, day: 20, hour: 0))
    }

    // MARK: - Counting and lookups

    @MainActor
    @Test("The unresolved count ignores credited and written-off cores")
    func unresolvedCountIgnoresClosedCores() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)

        let credited = try makeItem(context: context, service: service, partName: "One", vendor: vendor)
        let writtenOff = try makeItem(context: context, service: service, partName: "Two", vendor: vendor)
        _ = try makeItem(context: context, service: service, partName: "Three", vendor: vendor)

        try creditInFull(credited, service: service)
        try service.writeOff(writtenOff, reason: "Scrapped")

        #expect(try service.unresolvedCount() == 1)
        #expect(try service.allItems().count == 3)
    }

    @MainActor
    @Test("The shop profile is created once and reused thereafter")
    func theShopProfileIsCreatedOnceAndReused() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let first = try service.shopProfile()
        let second = try service.shopProfile()

        #expect(first.id == second.id)
        #expect(first.currencyCode == AppConfiguration.defaultCurrencyCode)
        #expect(first.reminderLeadDays == AppConfiguration.defaultReminderLeadDays)
        #expect(first.reminderHour == AppConfiguration.defaultReminderHour)
        #expect(first.remindersEnabled)
        #expect(first.hasCompletedOnboarding == false)
        #expect(first.displayName == "Your shop")
        #expect(first.createdAt == TestClock.referenceNow)
    }

    @MainActor
    @Test("Vendors and bins sort by name and hide inactive rows unless asked for")
    func vendorsAndBinsSortAndHideInactiveRows() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let zenith = try service.createVendor(name: "Zenith Parts", returnWindowDays: 30)
        _ = try service.createVendor(name: "Acme Supply", returnWindowDays: 30)
        zenith.isActive = false
        try service.updateVendor(zenith)

        #expect(try service.allVendors(includeInactive: false).map(\.name) == ["Acme Supply"])
        #expect(try service.allVendors(includeInactive: true).map(\.name) == ["Acme Supply", "Zenith Parts"])

        let cage = try service.createBin(label: "B1", locationNote: " Core cage ")
        _ = try service.createBin(label: "A3", locationNote: "Back wall")
        #expect(cage.locationNote == "Core cage")

        cage.isActive = false
        try service.updateBin(cage)

        #expect(try service.allBins(includeInactive: false).map(\.label) == ["A3"])
        #expect(try service.allBins(includeInactive: true).map(\.label) == ["A3", "B1"])
    }

    @MainActor
    @Test("A vendor's return window is clamped when it is created")
    func vendorWindowsAreClampedOnCreation() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let tooLong = try service.createVendor(name: "  Long Window  ", returnWindowDays: 400)
        let tooShort = try service.createVendor(name: "Short Window", returnWindowDays: 0)

        #expect(tooLong.defaultReturnWindowDays == 365)
        #expect(tooLong.name == "Long Window")
        #expect(tooShort.defaultReturnWindowDays == 1)
    }

    @MainActor
    @Test("Deleting a core leaves its vendor and bin in place")
    func deletingACoreLeavesItsVendorAndBinInPlace() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let vendor = makeVendor(context: context)
        let bin = makeBin(context: context)
        let item = try makeItem(context: context, service: service, vendor: vendor, bin: bin)

        #expect(item.binLabel == "A3")
        #expect(item.vendorName == "NAPA")
        #expect(item.vendorIdentifier == vendor.id)

        try service.delete(item)

        #expect(try service.allItems().isEmpty)
        #expect(try service.allVendors(includeInactive: true).count == 1)
        #expect(try service.allBins(includeInactive: true).count == 1)
    }

    @MainActor
    @Test("Deleting a vendor detaches its cores instead of destroying the ledger")
    func deletingAVendorDetachesItsCores() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let vendor = makeVendor(context: context)
        let item = try makeItem(context: context, service: service, vendor: vendor)

        try service.deleteVendor(vendor)

        #expect(try service.allVendors(includeInactive: true).isEmpty)
        #expect(try service.allItems().count == 1)
        #expect(item.vendor == nil)
        #expect(item.vendorName == nil)
        #expect(item.vendorIdentifier == nil)
    }

    // MARK: - Draft validation

    @MainActor
    @Test("Validation reports part name, then amount, then vendor")
    func validationReportsIssuesInFieldOrder() {
        let draft = CoreItemDraft(partName: "   ", expectedCreditText: "abc",
                                  receivedDate: TestClock.referenceNow)
        let issues = CoreItemValidator.validate(draft, calendar: calendar)

        #expect(issues.map(\.field) == [.partName, .expectedCredit, .vendor])
        #expect(issues.map(\.message) == [
            "Enter a part name or description.",
            "Enter the core charge, for example 86.50.",
            "Choose the vendor this core goes back to."
        ])
    }

    @MainActor
    @Test("A zero or oversized amount is rejected with its own message")
    func amountBoundsAreValidated() {
        let vendorID = UUID()
        let base = CoreItemDraft(partName: "Alternator", vendorIdentifier: vendorID,
                                 receivedDate: TestClock.referenceNow)

        var zero = base
        zero.expectedCreditText = "0.00"
        #expect(CoreItemValidator.validate(zero, calendar: calendar).map(\.message)
            == ["The expected credit must be more than zero."])

        var huge = base
        huge.expectedCreditText = "1000000.00"
        #expect(CoreItemValidator.validate(huge, calendar: calendar).map(\.message)
            == ["That amount looks too large."])

        var atCeiling = base
        atCeiling.expectedCreditText = Money(cents: CoreItemValidator.maximumExpectedCreditCents).plainDecimalString
        #expect(CoreItemValidator.validate(atCeiling, calendar: calendar).isEmpty)
    }

    @MainActor
    @Test("A pinned due date before the received date is rejected")
    func aBackdatedDueDateIsRejected() {
        let draft = CoreItemDraft(partName: "Alternator",
                                  vendorIdentifier: UUID(),
                                  expectedCreditText: "86.50",
                                  receivedDate: TestClock.date(year: 2026, month: 3, day: 12),
                                  usesCustomDueDate: true,
                                  customDueDate: TestClock.date(year: 2026, month: 3, day: 10))
        let issues = CoreItemValidator.validate(draft, calendar: calendar)

        #expect(issues.map(\.field) == [.dueDate])
        #expect(CoreItemValidator.firstIssue(issues, for: .dueDate)?.message
            == "The due date can't be before the received date.")
        #expect(CoreItemValidator.firstIssue(issues, for: .partName) == nil)
    }

    @MainActor
    @Test("A complete draft produces no issues")
    func aCompleteDraftIsAccepted() {
        let draft = CoreItemDraft(partName: "Alternator",
                                  partNumber: "03-1887",
                                  vendorIdentifier: UUID(),
                                  expectedCreditText: "86.50",
                                  invoiceReference: "INV-552",
                                  receivedDate: TestClock.referenceNow)

        #expect(CoreItemValidator.validate(draft, calendar: calendar).isEmpty)
        #expect(draft.expectedCredit == Money(cents: 8_650))
        #expect(draft.trimmedPartName == "Alternator")
    }

    @MainActor
    @Test("Validation issues identify themselves by field and message")
    func validationIssuesAreIdentifiable() {
        let issue = ValidationIssue(field: .vendor, message: "Choose the vendor this core goes back to.")
        #expect(issue.id == "vendor|Choose the vendor this core goes back to.")
        #expect(CoreItemField.expectedCredit.displayName == "Expected credit")
        #expect(CoreItemField.repairOrderReference.displayName == "Repair order")
        #expect(CoreItemField.allCases.count == 10)
    }

    @MainActor
    @Test("The service refuses to create a core from an invalid draft")
    func theServiceRefusesAnInvalidDraft() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let draft = CoreItemDraft(partName: "", expectedCreditText: "",
                                  receivedDate: TestClock.referenceNow)

        #expect(throws: DomainError.self) {
            try service.createItem(from: draft, vendor: nil, bin: nil)
        }
        #expect(try service.allItems().isEmpty)
    }

    @MainActor
    @Test("A round-tripped draft reproduces the stored core exactly")
    func aRoundTrippedDraftReproducesTheStoredCore() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let vendor = makeVendor(context: context)
        let bin = makeBin(context: context)

        let item = try makeItem(context: context, service: service, vendor: vendor, bin: bin,
                                invoiceReference: "INV-552", repairOrderReference: "1024",
                                notes: "Left on the core shelf.")

        let draft = service.draft(for: item)
        #expect(draft.existingID == item.id)
        #expect(draft.partName == "Alternator")
        #expect(draft.partNumber == "03-1887")
        #expect(draft.vendorIdentifier == vendor.id)
        #expect(draft.binIdentifier == bin.id)
        #expect(draft.expectedCreditText == "86.50")
        #expect(draft.invoiceReference == "INV-552")
        #expect(draft.repairOrderReference == "1024")
        #expect(draft.notes == "Left on the core shelf.")
        #expect(draft.receivedDate == item.receivedDate)
        #expect(CoreItemValidator.validate(draft, calendar: calendar).isEmpty)
    }
}
