import Foundation
import SwiftData

/// Builds the app's `ModelContainer` and provides the two seeded fixtures used by previews
/// and UI tests.
///
/// ## How `makeAppContainer` degrades
///
/// A shop opens this app standing at a parts counter, so a crash on launch is never an acceptable
/// outcome. `makeAppContainer(inMemory:)` walks a **bounded, non-blocking** ladder — three attempts,
/// no loop, no sleeping, nothing that can hang the main actor:
///
/// 1. Open the requested store (on disk unless the caller asked for memory).
/// 2. If that fails — corrupt file, unmigratable store, no disk space — record the reason in
///    `lastLoadFailureMessage` and open the **same full schema in memory**. The app is then fully
///    usable for the session; the app shell surfaces `lastLoadFailureMessage` as a warning banner
///    so the owner knows data is not being saved.
/// 3. If even that fails, try the barest possible store: a single model type, in memory, with a
///    default configuration.
/// 4. If all three fail, return `nil`.
///
/// A `nil` result is a real, presentable state rather than an impossibility: `RootView` renders
/// `StoreUnavailableView` with `lastLoadFailureMessage`, offering retry and — via
/// `destroyOnDiskStore()` — a reset that clears an unopenable store file. That is strictly better
/// than trapping or spinning, both of which leave the owner with no way forward.
enum ModelContainerFactory {

    /// Set whenever a store fails to open. `nil` means the requested store opened cleanly.
    @MainActor static private(set) var lastLoadFailureMessage: String?

    // MARK: - Container construction

    /// The full current schema (V3), migrated through `CoreCreditMigrationPlan`.
    ///
    /// A store written by an earlier build opens through the plan's lightweight V1 -> V2 and
    /// V2 -> V3 stages, which only add optional attributes and attributes carrying a default, and
    /// rewrite no data.
    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CoreCreditSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema,
                                  migrationPlan: CoreCreditMigrationPlan.self,
                                  configurations: configuration)
    }

    /// Never throws and never traps. Three bounded attempts, then `nil`.
    /// See the type-level documentation for the ladder and what `nil` means.
    @MainActor
    static func makeAppContainer(inMemory: Bool) -> ModelContainer? {
        // Collected in rung order. The first entry is the root cause and stays the headline
        // message even when a later rung succeeds — it is why data is not being saved.
        var failures: [String] = []

        // 1 — the store the caller actually asked for.
        do {
            let container = try makeContainer(inMemory: inMemory)
            lastLoadFailureMessage = nil
            return container
        } catch {
            failures.append(describeFailure(error, stage: "saved data file"))
            lastLoadFailureMessage = failures.first
        }

        // 2 — same schema, in memory. Everything works for this session, nothing is saved.
        do {
            let container = try makeContainer(inMemory: true)
            lastLoadFailureMessage = failures.first
            return container
        } catch {
            failures.append(describeFailure(error, stage: "temporary in-memory store"))
        }

        // 3 — barest possible store: one model type, in memory, default configuration.
        do {
            let container = try ModelContainer(
                for: ShopProfile.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            lastLoadFailureMessage = failures.first
            return container
        } catch {
            failures.append(describeFailure(error, stage: "minimal in-memory store"))
        }

        // 4 — nothing opened. Report every reason so StoreUnavailableView can show the full story.
        lastLoadFailureMessage = failures.joined(separator: " ")
        return nil
    }

    /// In-memory container pre-filled with the sample set, for SwiftUI previews.
    /// `nil` when even the in-memory store cannot open, so preview bodies can `if let`.
    @MainActor
    static func makePreviewContainer() -> ModelContainer? {
        guard let container = makeAppContainer(inMemory: true) else { return nil }
        seedSampleData(in: container.mainContext, now: Date())
        return container
    }

    /// Deletes the on-disk store files so the owner can recover from an unopenable/corrupt store.
    /// Safe to call when the files are already absent. Returns false when deletion failed.
    ///
    /// This is destructive and unrecoverable — only `StoreUnavailableView`'s explicit reset action
    /// and the Settings data screen should call it, always behind a confirmation.
    @MainActor
    static func destroyOnDiskStore() -> Bool {
        let fileManager = FileManager.default
        let directory = URL.applicationSupportDirectory
        let urls = [
            directory.appending(path: "default.store"),
            directory.appending(path: "default.store-wal"),
            directory.appending(path: "default.store-shm")
        ]

        var succeeded = true
        for url in urls {
            // Absent files are the expected case for -wal/-shm, not a failure.
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
                let reason = String(describing: error)
                lastLoadFailureMessage = "The saved data file could not be deleted. " + reason
            }
        }
        return succeeded
    }

    private static func describeFailure(_ error: any Error, stage: String) -> String {
        "The " + stage + " could not be opened. " + String(describing: error)
    }

    // MARK: - Sample data (previews and UI tests ONLY)

    /// One row of the demonstration ledger. Written out longhand rather than as a tuple literal
    /// so the type checker has nothing to infer.
    private struct SampleSpec {
        var partName: String
        var partNumber: String
        var cents: Int64
        var daysAgo: Int
        var status: CoreStatus
        var actualCents: Int64?
        var vendor: Vendor
        var bin: StorageBin
    }

    /// A small, obviously-fake demonstration ledger.
    ///
    /// **Never call this on a real first launch.** It exists so previews and UI tests have
    /// something to render; shipping it as production data would mean a new shop opens the app
    /// and sees six cores it never logged.
    @MainActor
    static func seedSampleData(in context: ModelContext, now: Date) {
        let calendar = Calendar.current

        let profile = ShopProfile(name: "Sample Auto Service", now: now)
        profile.phone = "555-0142"
        // Deliberately not an `example.com` address. This sample profile is rendered on screen
        // under `-uiTestSeed fiveUnresolved`, and a UI test asserts that no placeholder address
        // ever reaches the interface. `.invalid` is the reserved-by-RFC-2606 way to spell an
        // address that is obviously fake and can never resolve.
        profile.email = "counter@sample-auto-service.invalid"
        profile.addressLine1 = "18 Shop Lane"
        profile.city = "Columbus"
        profile.region = "OH"
        profile.postalCode = "43004"
        profile.hasCompletedOnboarding = true
        context.insert(profile)

        let napa = Vendor(name: "NAPA", defaultReturnWindowDays: 30, now: now)
        let oreilly = Vendor(name: "O'Reilly", defaultReturnWindowDays: 14, now: now)
        context.insert(napa)
        context.insert(oreilly)

        let shelfA3 = StorageBin(label: "A3", locationNote: "Back wall, top shelf", now: now)
        let cageB1 = StorageBin(label: "B1", locationNote: "Core cage by the roll-up door", now: now)
        context.insert(shelfA3)
        context.insert(cageB1)

        var specs: [SampleSpec] = []
        specs.append(SampleSpec(partName: "Alternator", partNumber: "03-1887", cents: 8_650,
                                daysAgo: 3, status: .awaitingCore, actualCents: nil,
                                vendor: napa, bin: shelfA3))
        specs.append(SampleSpec(partName: "Starter", partNumber: "17-4420", cents: 5_400,
                                daysAgo: 9, status: .readyToReturn, actualCents: nil,
                                vendor: napa, bin: shelfA3))
        specs.append(SampleSpec(partName: "Brake caliper, left front", partNumber: "CAL-118", cents: 4_200,
                                daysAgo: 21, status: .returnedAwaitingCredit, actualCents: nil,
                                vendor: oreilly, bin: cageB1))
        specs.append(SampleSpec(partName: "Water pump", partNumber: "WP-9021", cents: 3_150,
                                daysAgo: 44, status: .returnedAwaitingCredit, actualCents: nil,
                                vendor: napa, bin: cageB1))
        specs.append(SampleSpec(partName: "A/C compressor", partNumber: "AC-7714", cents: 12_500,
                                daysAgo: 58, status: .disputed, actualCents: 6_000,
                                vendor: oreilly, bin: cageB1))
        specs.append(SampleSpec(partName: "Steering rack", partNumber: "SR-2210", cents: 22_000,
                                daysAgo: 71, status: .credited, actualCents: 22_000,
                                vendor: napa, bin: shelfA3))

        for (index, spec) in specs.enumerated() {
            let received = calendar.date(byAdding: .day, value: -spec.daysAgo, to: now) ?? now
            let item = CoreItem(partName: spec.partName,
                                expectedCredit: Money(cents: spec.cents),
                                receivedDate: received,
                                vendor: spec.vendor,
                                bin: spec.bin,
                                now: received)
            item.partNumber = spec.partNumber
            item.invoiceReference = "INV-" + String(500 + index)
            item.repairOrderReference = String(1_000 + index)
            item.status = spec.status
            item.dueDate = DueDateCalculator.dueDate(receivedDate: received,
                                                     windowDays: spec.vendor.defaultReturnWindowDays,
                                                     calendar: calendar)

            switch spec.status {
            case .returnedAwaitingCredit:
                item.returnedDate = calendar.date(byAdding: .day, value: 2, to: received) ?? received
            case .disputed, .credited:
                let returned = calendar.date(byAdding: .day, value: 2, to: received) ?? received
                item.returnedDate = returned
                item.creditedDate = calendar.date(byAdding: .day, value: 12, to: received) ?? returned
                item.creditReference = "CM-" + String(900 + index)
                if let actual = spec.actualCents {
                    item.actualCredit = Money(cents: actual)
                }
            case .awaitingCore, .readyToReturn, .writtenOff:
                break
            }

            item.updatedAt = now
            context.insert(item)

            let created = CoreEvent(type: .created,
                                    detail: "Sample core logged.",
                                    timestamp: received,
                                    amount: Money(cents: spec.cents),
                                    reference: item.invoiceReference,
                                    from: nil,
                                    to: .awaitingCore)
            context.insert(created)
            created.coreItem = item
        }

        try? context.save()
    }

    /// The acceptance-walkthrough fixture: NAPA, a 30-day window, and one alternator core.
    ///
    /// Deliberately minimal and deterministic — the walkthrough script asserts on these exact
    /// values. No attachments are created here; image bytes come from the image helper owned by
    /// another layer, and the walkthrough adds its own photos through the UI.
    @MainActor
    static func seedAcceptanceWalkthrough(in context: ModelContext, now: Date) {
        let calendar = Calendar.current

        let profile = ShopProfile(name: "Acceptance Shop", now: now)
        profile.hasCompletedOnboarding = true
        context.insert(profile)

        let napa = Vendor(name: "NAPA", defaultReturnWindowDays: 30, now: now)
        context.insert(napa)

        let shelfA3 = StorageBin(label: "A3", locationNote: "Core shelf", now: now)
        context.insert(shelfA3)

        let expected = Money(cents: 8_650)
        let item = CoreItem(partName: "Alternator",
                            expectedCredit: expected,
                            receivedDate: now,
                            vendor: napa,
                            bin: shelfA3,
                            now: now)
        item.partNumber = "03-1887"
        item.repairOrderReference = "1024"
        item.invoiceReference = "INV-552"
        item.status = .awaitingCore
        item.usesCustomDueDate = false
        item.dueDate = DueDateCalculator.dueDate(receivedDate: now,
                                                 windowDays: napa.defaultReturnWindowDays,
                                                 calendar: calendar)
        context.insert(item)

        let created = CoreEvent(type: .created,
                                detail: "Core logged.",
                                timestamp: now,
                                amount: expected,
                                reference: item.invoiceReference,
                                from: nil,
                                to: .awaitingCore)
        context.insert(created)
        created.coreItem = item

        try? context.save()
    }

    // MARK: - Destructive reset

    /// Removes every persisted object.
    ///
    /// Order matters: children (events, attachments) go first, then the records that own them,
    /// then the lookup tables they point at. That keeps SwiftData from having to resolve a
    /// relationship to an object that has already been deleted.
    @MainActor
    static func deleteAllData(in context: ModelContext) throws {
        do {
            try deleteEvery(CoreEvent.self, in: context)
            try deleteEvery(Attachment.self, in: context)
            try deleteEvery(CoreItem.self, in: context)
            try deleteEvery(ReturnBatch.self, in: context)
            try deleteEvery(StorageBin.self, in: context)
            try deleteEvery(Vendor.self, in: context)
            try deleteEvery(ShopProfile.self, in: context)
            try context.save()
        } catch {
            throw DomainError.persistenceFailed(String(describing: error))
        }
    }

    @MainActor
    private static func deleteEvery<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        let objects = try context.fetch(FetchDescriptor<T>())
        for object in objects {
            context.delete(object)
        }
    }
}
