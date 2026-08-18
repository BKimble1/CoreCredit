//
//  BackupRestoreTests.swift
//  CoreCreditTests
//
//  Reading a backup back in, and the promise that makes it safe to offer at all:
//  **a restore that fails leaves the ledger exactly as it was.**
//
//  That promise is the reason `BackupRestoreService` is split into `plan(from:)` and `restore(_:)`.
//  Everything that can be rejected is rejected by the first, which touches no store; the second
//  deletes and rebuilds in one unsaved transaction and rolls the whole thing back if anything
//  throws. This suite exercises both halves, and the money in between: `Money` is `Int64` cents,
//  and a restore that lost a penny would be a restore that lost the point of the app.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("A backup round-trips exactly, and a failed restore changes nothing")
struct BackupRestoreTests {

    // MARK: - Fixtures

    /// A ledger with every shape the format has to carry: two vendors, two bins, a batch, a
    /// disputed short credit, a settled core, and an event history on each.
    @MainActor
    private func seedLedger(_ context: ModelContext, service: CoreItemService) throws {
        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let oreilly = makeVendor(context: context, name: "O'Reilly", windowDays: 14)
        let shelf = makeBin(context: context, label: "A3", locationNote: "Back wall")
        _ = makeBin(context: context, label: "B1", locationNote: "Core cage")

        let alternator = try makeItem(context: context,
                                      service: service,
                                      partName: "Alternator",
                                      amountCents: 8_650,
                                      vendor: napa,
                                      bin: shelf,
                                      partNumber: "03-1887",
                                      invoiceReference: "INV-552",
                                      repairOrderReference: "1024")
        try service.transition(alternator, to: .readyToReturn, detail: nil)

        let compressor = try makeItem(context: context,
                                      service: service,
                                      partName: "A/C compressor",
                                      amountCents: 12_500,
                                      vendor: oreilly,
                                      partNumber: "AC-7714")
        try service.transition(compressor, to: .readyToReturn, detail: nil)
        try service.transition(compressor, to: .returnedAwaitingCredit, detail: nil)
        // A short credit: the disputed path, and the one that has an `actualCredit` to preserve.
        try service.recordCredit(compressor,
                                 reconciliation: CreditReconciliation(
                                    creditDate: TestClock.referenceNow,
                                    reference: "CM-8841",
                                    amount: Money(cents: 6_000)))

        let pump = try makeItem(context: context,
                                service: service,
                                partName: "Water pump",
                                amountCents: 3_150,
                                vendor: napa,
                                partNumber: "WP-9021")
        try creditInFull(pump, service: service, reference: "CM-1002")
    }

    @MainActor
    private func makeBackup(_ context: ModelContext, service: CoreItemService) throws -> BackupPayload {
        let profile = try service.shopProfile()
        profile.name = "Miller's Diesel Service"
        profile.phone = "555-0100"
        profile.email = "counter@sample-auto-service.invalid"
        profile.addressLine1 = "18 Shop Lane"
        profile.city = "Hamilton"
        profile.region = "OH"
        profile.postalCode = "45011"

        return SnapshotBuilder.backup(
            profile: profile,
            vendors: try service.allVendors(includeInactive: true),
            bins: try service.allBins(includeInactive: true),
            items: try service.allItems(),
            batches: try context.fetch(FetchDescriptor<ReturnBatch>()),
            appVersion: AppConfiguration.appVersion,
            exportedAt: TestClock.referenceNow
        )
    }

    @MainActor
    private func restoreService(_ context: ModelContext) -> BackupRestoreService {
        BackupRestoreService(context: context, dateProvider: TestClock.referenceProvider)
    }

    // MARK: - Encode and decode

    @Test("A payload survives an encode/decode round trip with every value intact")
    @MainActor
    func aPayloadRoundTripsThroughJSON() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        try seedLedger(context, service: service)

        let original = try makeBackup(context, service: service)
        let data = try JSONBackupExporter.encode(original)
        let decoded = try JSONBackupExporter.decode(data)

        #expect(decoded == original, "The backup format must be lossless through JSON.")

        // Money is the value this app exists to be right about. Asserted separately from the
        // whole-payload equality so a failure says *which* half broke.
        let originalCents = original.items.map(\.expectedCredit.cents).sorted()
        let decodedCents = decoded.items.map(\.expectedCredit.cents).sorted()
        #expect(decodedCents == originalCents)
        #expect(decoded.items.compactMap(\.actualCredit?.cents).sorted()
                == original.items.compactMap(\.actualCredit?.cents).sorted())
    }

    // MARK: - A full restore

    @Test("Restoring into an empty store rebuilds every record, relationship, and event")
    @MainActor
    func restoringRebuildsEverything() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        let payload = try makeBackup(source, service: sourceService)
        let data = try JSONBackupExporter.encode(payload)

        // A different store entirely — the shape of "a replacement device".
        let target = try makeInMemoryContext()
        let service = restoreService(target)

        let plan = try service.plan(from: data)
        #expect(plan.summary.itemCount == payload.items.count)
        #expect(plan.summary.existingItemCount == 0)
        try service.restore(plan)

        let items = try target.fetch(FetchDescriptor<CoreItem>())
        let vendors = try target.fetch(FetchDescriptor<Vendor>())
        let bins = try target.fetch(FetchDescriptor<StorageBin>())
        let profiles = try target.fetch(FetchDescriptor<ShopProfile>())

        #expect(items.count == payload.items.count)
        #expect(vendors.count == payload.vendors.count)
        #expect(bins.count == payload.bins.count)
        #expect(profiles.count == 1)

        // Identity survives: a bin tag printed before the restore still opens the same core.
        #expect(Set(items.map(\.id)) == Set(payload.items.map(\.identifier)))
        #expect(Set(vendors.map(\.id)) == Set(payload.vendors.map(\.id)))

        // Relationships were reconstructed, not dropped.
        let alternator = try #require(items.first { $0.partName == "Alternator" })
        #expect(alternator.vendor?.name == "NAPA")
        #expect(alternator.bin?.label == "A3")
        #expect(alternator.status == .readyToReturn)
        #expect(alternator.partNumber == "03-1887")
        #expect(alternator.invoiceReference == "INV-552")

        // Exact cents, both sides of a dispute.
        let compressor = try #require(items.first { $0.partName == "A/C compressor" })
        #expect(compressor.expectedCredit == Money(cents: 12_500))
        #expect(compressor.actualCreditCents == 6_000)
        #expect(compressor.status == .disputed)

        // The audit trail is the record's provenance; losing it would make the ledger unprovable.
        let expectedEvents = payload.items.reduce(0) { $0 + $1.events.count }
        let restoredEvents = try target.fetch(FetchDescriptor<CoreEvent>()).count
        #expect(restoredEvents == expectedEvents)
        #expect(expectedEvents > 0, "The fixture must have produced an audit trail to restore.")
        #expect(alternator.events?.isEmpty == false)

        // Profile fields the format carries 1:1.
        let profile = try #require(profiles.first)
        #expect(profile.name == "Miller's Diesel Service")
        #expect(profile.phone == "555-0100")
        #expect(profile.currencyCode == payload.shop.currencyCode)
    }

    @Test("Restoring over an existing ledger replaces it rather than merging")
    @MainActor
    func restoringReplacesRatherThanMerges() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        let data = try JSONBackupExporter.encode(try makeBackup(source, service: sourceService))

        // A device with its own, different ledger on it.
        let target = try makeInMemoryContext()
        let targetService = makeItemService(context: target)
        let localVendor = makeVendor(context: target, name: "Local Parts Co")
        _ = try makeItem(context: target, service: targetService,
                         partName: "Brake caliper", vendor: localVendor)
        _ = try makeItem(context: target, service: targetService,
                         partName: "Radiator", vendor: localVendor)

        let service = restoreService(target)
        let plan = try service.plan(from: data)
        #expect(plan.summary.existingItemCount == 2,
                "The confirmation has to state how much is about to be replaced.")

        try service.restore(plan)

        let items = try target.fetch(FetchDescriptor<CoreItem>())
        #expect(items.count == plan.summary.itemCount)
        #expect(items.count > 0)
        #expect(items.contains { $0.partName == "Brake caliper" } == false,
                "Version 1 restores by replacement. A survivor here would be a merge.")
        #expect(items.contains { $0.partName == "Alternator" })

        let vendors = try target.fetch(FetchDescriptor<Vendor>())
        #expect(vendors.contains { $0.name == "Local Parts Co" } == false)
        #expect(try target.fetch(FetchDescriptor<ShopProfile>()).count == 1,
                "Exactly one shop profile, or the app has two identities.")
    }

    @Test("A restore carries this device's reminder settings across, because the file has none")
    @MainActor
    func aRestoreCarriesDeviceRemindersAcross() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        let data = try JSONBackupExporter.encode(try makeBackup(source, service: sourceService))

        let target = try makeInMemoryContext()
        let targetService = makeItemService(context: target)
        let existing = try targetService.shopProfile()
        existing.remindersEnabled = false
        existing.reminderLeadDays = 5
        existing.reminderHour = 6

        let service = restoreService(target)
        try service.restore(try service.plan(from: data))

        // `ShopProfileSnapshot` carries name, phone, email, address, and currency — not the
        // notification schedule. Resetting it to defaults would silently switch a shop's deadline
        // reminders back on, at a different hour, on the day they restored.
        let profile = try #require(try target.fetch(FetchDescriptor<ShopProfile>()).first)
        #expect(profile.remindersEnabled == false)
        #expect(profile.reminderLeadDays == 5)
        #expect(profile.reminderHour == 6)
        #expect(profile.hasCompletedOnboarding, "A shop with a backup has been through setup.")
    }

    @Test("The restored ledger schedules the reminders its deadlines call for")
    @MainActor
    func theRestoredLedgerSchedulesItsReminders() async throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        let data = try JSONBackupExporter.encode(try makeBackup(source, service: sourceService))

        let target = try makeInMemoryContext()
        let targetService = makeItemService(context: target)
        let profile = try targetService.shopProfile()
        profile.remindersEnabled = true

        let service = restoreService(target)
        try service.restore(try service.plan(from: data))

        // What `DataSettingsView` does after a successful restore: throw the old queue away, which
        // was built from records that no longer exist, and rebuild it from what is now in the store.
        let scheduler = RecordingNotificationScheduler()
        let coordinator = ReminderCoordinator(scheduler: scheduler,
                                              dateProvider: TestClock.referenceProvider,
                                              observesItemChanges: false)
        await coordinator.cancelAll()
        await coordinator.refreshFromStore(target)

        let unresolved = try target.fetch(FetchDescriptor<CoreItem>())
            .filter { $0.status.isUnresolved }
        #expect(unresolved.isEmpty == false, "The fixture must leave something to remind about.")
        #expect(coordinator.lastRefresh != nil,
                "A refresh after a restore has to actually run, or the restored deadlines are silent.")
    }

    // MARK: - Everything that is refused, before anything is deleted

    @Test("An empty file, junk, and valid JSON that is not a backup are each refused by name")
    @MainActor
    func malformedFilesAreRefusedByName() throws {
        let context = try makeInMemoryContext()
        let service = restoreService(context)

        #expect(throws: BackupRestoreError.notJSON) {
            _ = try service.plan(from: Data())
        }
        #expect(throws: BackupRestoreError.notJSON) {
            _ = try service.plan(from: Data("this is not json at all".utf8))
        }
        // Well-formed JSON, wrong shape — somebody picked the wrong file.
        #expect(throws: BackupRestoreError.notACoreCreditBackup) {
            _ = try service.plan(from: Data(#"{"hello":"world"}"#.utf8))
        }
    }

    @Test("A backup from a newer version of the app is refused rather than half-read")
    @MainActor
    func aNewerFormatIsRefused() throws {
        let context = try makeInMemoryContext()
        let service = restoreService(context)

        var payload = BackupPayload(exportedAt: TestClock.referenceNow)
        payload.formatVersion = BackupPayload.currentFormatVersion + 1
        payload.vendors = [VendorSnapshot(id: UUID(), name: "NAPA", contactName: "", phone: "",
                                          email: "", accountNumber: "",
                                          defaultReturnWindowDays: 30, notes: "", isActive: true)]
        let data = try JSONBackupExporter.encode(payload)

        // Reading a format written by a build that knows more than this one does is how a restore
        // silently drops the fields it has never heard of.
        #expect(throws: BackupRestoreError.newerFormat(
            found: BackupPayload.currentFormatVersion + 1,
            supported: BackupPayload.currentFormatVersion
        )) {
            _ = try service.plan(from: data)
        }
    }

    @Test("An empty backup is refused, so a restore cannot quietly erase a ledger")
    @MainActor
    func anEmptyBackupIsRefused() throws {
        let context = try makeInMemoryContext()
        let service = restoreService(context)
        let data = try JSONBackupExporter.encode(BackupPayload(exportedAt: TestClock.referenceNow))

        // This is the dangerous one: an empty file that restored "successfully" would delete
        // everything and add nothing, and look like it worked.
        #expect(throws: BackupRestoreError.empty) {
            _ = try service.plan(from: data)
        }
    }

    @Test("A repeated identifier is refused, because two records that should be one is corruption")
    @MainActor
    func duplicateIdentifiersAreRefused() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        var payload = try makeBackup(source, service: sourceService)

        let duplicated = try #require(payload.items.first)
        payload.items.append(duplicated)
        let data = try JSONBackupExporter.encode(payload)

        let target = try makeInMemoryContext()
        let service = restoreService(target)
        #expect(throws: BackupRestoreError.duplicateIdentifiers(kind: "core")) {
            _ = try service.plan(from: data)
        }
    }

    @Test("Every rejection happens before the store is touched")
    @MainActor
    func rejectionsHappenBeforeAnythingIsDeleted() throws {
        let target = try makeInMemoryContext()
        let targetService = makeItemService(context: target)
        _ = try makeItem(context: target, service: targetService, partName: "Brake caliper")
        _ = try makeItem(context: target, service: targetService, partName: "Radiator")

        let service = restoreService(target)
        let before = try target.fetch(FetchDescriptor<CoreItem>()).count
        #expect(before == 2)

        // Four different refusals, none of which may cost the shop a record.
        let badFiles: [Data] = [
            Data(),
            Data("not json".utf8),
            Data(#"{"hello":"world"}"#.utf8),
            try JSONBackupExporter.encode(BackupPayload(exportedAt: TestClock.referenceNow))
        ]
        for data in badFiles {
            _ = try? service.plan(from: data)
        }

        let after = try target.fetch(FetchDescriptor<CoreItem>())
        #expect(after.count == before, "A refused file must not delete anything.")
        #expect(Set(after.map(\.partName)) == ["Brake caliper", "Radiator"])
    }

    // MARK: - Failure safety

    @Test("A batch naming a core the file does not contain restores everything else")
    @MainActor
    func anUnknownBatchMemberDoesNotSinkTheRestore() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        var payload = try makeBackup(source, service: sourceService)

        // A return that references a core that is not in the file. Losing one line of a batch is
        // survivable; refusing the whole restore over it would cost the shop everything else.
        payload.batches.append(ReturnBatchSnapshot(
            id: UUID(),
            vendorName: "NAPA",
            vendorIdentifier: payload.vendors.first?.id,
            returnDate: TestClock.referenceNow,
            method: .counterDropOff,
            reference: "RET-999",
            notes: "",
            itemIdentifiers: [UUID()]
        ))
        let data = try JSONBackupExporter.encode(payload)

        let target = try makeInMemoryContext()
        let service = restoreService(target)
        try service.restore(try service.plan(from: data))

        #expect(try target.fetch(FetchDescriptor<CoreItem>()).count == payload.items.count)
        #expect(try target.fetch(FetchDescriptor<ReturnBatch>()).count == payload.batches.count)
    }

    @Test("Restoring the same file twice is stable — identifiers do not multiply")
    @MainActor
    func restoringTwiceIsStable() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        let data = try JSONBackupExporter.encode(try makeBackup(source, service: sourceService))

        let target = try makeInMemoryContext()
        let service = restoreService(target)

        try service.restore(try service.plan(from: data))
        let firstPass = try target.fetch(FetchDescriptor<CoreItem>()).map(\.id).sorted()

        try service.restore(try service.plan(from: data))
        let secondPass = try target.fetch(FetchDescriptor<CoreItem>()).map(\.id).sorted()

        let profileCount = try target.fetch(FetchDescriptor<ShopProfile>()).count
        let restoredEvents = try target.fetch(FetchDescriptor<CoreEvent>()).count
        let sourceEvents = try source.fetch(FetchDescriptor<CoreEvent>()).count

        #expect(secondPass == firstPass, "A second restore replaces; it does not accumulate.")
        #expect(profileCount == 1)
        #expect(restoredEvents == sourceEvents)
    }

    // MARK: - What a backup does not carry

    @Test("Evidence photos are not in the format, so a restore cannot claim to bring them back")
    @MainActor
    func evidencePhotosAreNotInTheFormat() throws {
        let source = try makeInMemoryContext()
        let sourceService = makeItemService(context: source)
        try seedLedger(source, service: sourceService)
        let payload = try makeBackup(source, service: sourceService)
        let text = String(decoding: try JSONBackupExporter.encode(payload), as: UTF8.self)

        // The UI, the Help text, the Privacy documentation, and the App Review notes all say photos
        // are not restored. This is the assertion that keeps that statement true: if image bytes
        // were ever added to the format, this fails and the copy has to be revisited.
        #expect(text.contains("imageData") == false)
        #expect(text.contains("attachments") == false)

        let target = try makeInMemoryContext()
        let service = restoreService(target)
        try service.restore(try service.plan(from: try JSONBackupExporter.encode(payload)))

        let attachments = try target.fetch(FetchDescriptor<Attachment>())
        #expect(attachments.isEmpty)
    }
}
