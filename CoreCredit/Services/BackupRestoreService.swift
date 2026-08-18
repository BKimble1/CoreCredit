//
//  BackupRestoreService.swift
//  CoreCredit
//
//  Reading a backup file back in — the other half of a workflow that has only ever had an export.
//
//  ## The one rule
//
//  **Nothing is deleted until the whole replacement has been validated and built.** A restore that
//  fails halfway is the worst possible outcome for a ledger: the shop loses the records it had and
//  does not gain the ones it wanted. So the work is split in two, and the split is the safety:
//
//  1. `plan(from:)` reads the file, decodes it, checks it, and returns a `BackupRestorePlan`
//     describing exactly what would happen. It touches no `ModelContext` and cannot change
//     anything. Every rejection happens here, before the ledger is at risk.
//  2. `restore(_:)` deletes and rebuilds inside a **single unsaved transaction**, and saves once at
//     the very end. Anything thrown along the way triggers `context.rollback()`, which discards the
//     deletions along with the half-built replacement, and the existing ledger is exactly as it was.
//
//  ## Replace, not merge
//
//  Version 1 restores by replacement. A merge has to answer "this core exists in both, which one
//  wins?" for every record, and getting that wrong silently is worse than not offering it — a
//  duplicated core is money counted twice. The confirmation says "replace" in those words.
//
//  ## What a backup does not carry
//
//  `BackupPayload` is a text file of records. Two things are genuinely not in it, and the UI says
//  so rather than letting a shop find out afterwards:
//
//  - **Evidence photographs.** Image bytes are not exported, so they cannot be restored. Device
//    backups do carry them.
//  - **Reminder preferences and onboarding state.** `ShopProfileSnapshot` carries the shop's name,
//    phone, email, address, and currency — not the notification schedule. Rather than resetting
//    those to defaults on the strength of a file that never mentioned them, the settings already on
//    this device are carried across the restore. They belong to the device, not to the ledger.
//
//  The postal address is stored in the backup as formatted lines rather than as separate city,
//  region, and postal-code fields, so it comes back as address lines. No character is lost; the
//  split between the fields is.
//

import Foundation
import SwiftData

// MARK: - What the user is told before anything happens

/// A validated description of a restore that has **not** run yet.
///
/// Holding the decoded payload alongside the summary means the file is parsed exactly once: the
/// numbers on the confirmation screen and the records that get written come from the same decode,
/// so they cannot disagree.
struct BackupRestorePlan: Sendable {

    /// The decoded file. Already validated.
    let payload: BackupPayload

    /// What the user is shown before confirming.
    let summary: BackupRestoreSummary
}

/// The preflight figures, for the screen that asks "are you sure".
struct BackupRestoreSummary: Equatable, Sendable {

    var formatVersion: Int
    var appVersion: String
    var exportedAt: Date

    var shopName: String
    var vendorCount: Int
    var binCount: Int
    var itemCount: Int
    var batchCount: Int
    var eventCount: Int

    /// Cores in the file that would still count against money at risk.
    var unresolvedCount: Int

    /// What the file says is still owed, computed the same way the Dashboard computes it.
    var moneyAtRisk: Money

    /// What is on this device right now and would be replaced. The number that makes the
    /// confirmation mean something.
    var existingItemCount: Int
}

// MARK: - Why a restore was refused

/// Every way a restore can be declined, phrased for a shop owner rather than a developer.
enum BackupRestoreError: LocalizedError, Equatable {

    /// The file could not be read off disk at all.
    case unreadableFile(String)

    /// Not JSON.
    case notJSON

    /// Valid JSON, but not a CoreCredit backup.
    case notACoreCreditBackup

    /// Written by a newer version of CoreCredit than this one can read.
    case newerFormat(found: Int, supported: Int)

    /// A CoreCredit backup with nothing in it.
    case empty

    /// The same identifier appears twice. Restoring it would produce two records that are supposed
    /// to be one.
    case duplicateIdentifiers(kind: String)

    /// The write failed. The ledger was rolled back.
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "That file couldn't be opened."
        case .notJSON:
            return "That file isn't a CoreCredit backup."
        case .notACoreCreditBackup:
            return "That file is readable, but it isn't a CoreCredit backup."
        case .newerFormat(let found, let supported):
            return "That backup was written by a newer version of CoreCredit (format "
                + String(found) + "; this version reads format " + String(supported) + ")."
        case .empty:
            return "That backup is empty — there is nothing in it to restore."
        case .duplicateIdentifiers(let kind):
            return "That backup lists the same " + kind + " twice, so it can't be restored safely."
        case .restoreFailed:
            return "The restore didn't finish."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unreadableFile:
            return "Check the file is still where you chose it from, then try again."
        case .notJSON, .notACoreCreditBackup:
            return "Choose a .json file that CoreCredit itself wrote from Data & export."
        case .newerFormat:
            return "Update CoreCredit on this device, then restore again."
        case .empty:
            return "Choose a different backup file."
        case .duplicateIdentifiers:
            return "The file is damaged. Use another backup if you have one."
        case .restoreFailed:
            return "Nothing was changed — your existing records are exactly as they were. Try "
                + "again, or restart the app and try once more."
        }
    }
}

// MARK: - Service

/// Validates a backup file and, on a second explicit call, replaces the ledger with it.
@MainActor
final class BackupRestoreService {

    private let context: ModelContext
    private let dateProvider: any DateProvider

    init(context: ModelContext, dateProvider: any DateProvider) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: Preflight

    /// Decodes and checks a file, and reports what restoring it would do.
    ///
    /// Reads the store to count what is currently there, and writes nothing. Every rejection this
    /// service is capable of happens here, while the existing ledger is still untouched.
    func plan(from data: Data) throws -> BackupRestorePlan {
        guard data.isEmpty == false else { throw BackupRestoreError.notJSON }

        // Two-step decode so the message can tell the difference between "not JSON at all" and
        // "JSON, but somebody else's". A shop owner who picked the wrong file needs to know which.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw BackupRestoreError.notJSON
        }

        let payload: BackupPayload
        do {
            payload = try JSONBackupExporter.decode(data)
        } catch {
            throw BackupRestoreError.notACoreCreditBackup
        }

        guard payload.formatVersion <= BackupPayload.currentFormatVersion else {
            throw BackupRestoreError.newerFormat(found: payload.formatVersion,
                                                 supported: BackupPayload.currentFormatVersion)
        }
        guard payload.formatVersion >= 1 else {
            throw BackupRestoreError.notACoreCreditBackup
        }

        let isEmpty = payload.items.isEmpty
            && payload.vendors.isEmpty
            && payload.bins.isEmpty
            && payload.batches.isEmpty
        guard isEmpty == false else { throw BackupRestoreError.empty }

        try assertNoDuplicates(payload)

        let now = dateProvider.now
        let calendar = dateProvider.calendar
        let risk = RiskCalculator.summarize(payload.items, now: now, calendar: calendar)

        let summary = BackupRestoreSummary(
            formatVersion: payload.formatVersion,
            appVersion: payload.appVersion,
            exportedAt: payload.exportedAt,
            shopName: payload.shop.displayName,
            vendorCount: payload.vendors.count,
            binCount: payload.bins.count,
            itemCount: payload.items.count,
            batchCount: payload.batches.count,
            eventCount: payload.items.reduce(0) { $0 + $1.events.count },
            unresolvedCount: risk.unresolvedCount,
            moneyAtRisk: risk.moneyAtRisk,
            existingItemCount: (try? context.fetch(FetchDescriptor<CoreItem>()).count) ?? 0
        )

        return BackupRestorePlan(payload: payload, summary: summary)
    }

    /// A repeated identifier means two records that are meant to be one. Caught before any delete.
    private func assertNoDuplicates(_ payload: BackupPayload) throws {
        func hasDuplicates(_ identifiers: [UUID]) -> Bool {
            Set(identifiers).count != identifiers.count
        }
        if hasDuplicates(payload.vendors.map(\.id)) {
            throw BackupRestoreError.duplicateIdentifiers(kind: "vendor")
        }
        if hasDuplicates(payload.bins.map(\.id)) {
            throw BackupRestoreError.duplicateIdentifiers(kind: "storage bin")
        }
        if hasDuplicates(payload.items.map(\.identifier)) {
            throw BackupRestoreError.duplicateIdentifiers(kind: "core")
        }
        if hasDuplicates(payload.batches.map(\.id)) {
            throw BackupRestoreError.duplicateIdentifiers(kind: "return")
        }
        for item in payload.items where hasDuplicates(item.events.map(\.id)) {
            throw BackupRestoreError.duplicateIdentifiers(kind: "history entry")
        }
    }

    // MARK: Restore

    /// Replaces everything on this device with the contents of an already-validated plan.
    ///
    /// One transaction. The delete is deliberately **not** saved on its own — if it were, a failure
    /// during the rebuild would leave the shop with nothing at all. Every path out of here either
    /// saves the complete replacement or rolls the whole thing back.
    func restore(_ plan: BackupRestorePlan) throws {
        let payload = plan.payload
        let now = dateProvider.now
        let calendar = dateProvider.calendar

        // Device settings the backup does not carry. Read before the delete, applied after the
        // rebuild, so a restore never silently switches somebody's reminders off.
        let carriedSettings = currentDeviceSettings()

        do {
            try deleteEverythingWithoutSaving()

            // --- shop profile -------------------------------------------------------------
            let profile = ShopProfile(name: payload.shop.name,
                                      currencyCode: payload.shop.currencyCode,
                                      now: now)
            profile.phone = payload.shop.phone
            profile.email = payload.shop.email
            // The backup stores the address as formatted lines, not as separate city/region/postal
            // fields, so it comes back as lines. No character is lost; the split is.
            profile.addressLine1 = payload.shop.addressLines.first ?? ""
            profile.addressLine2 = payload.shop.addressLines.dropFirst().joined(separator: ", ")
            carriedSettings.apply(to: profile)
            profile.updatedAt = now
            context.insert(profile)

            // --- vendors and bins ---------------------------------------------------------
            var vendorsByID: [UUID: Vendor] = [:]
            for snapshot in payload.vendors {
                let vendor = Vendor(name: snapshot.name,
                                    defaultReturnWindowDays: snapshot.defaultReturnWindowDays,
                                    now: now)
                vendor.id = snapshot.id
                vendor.contactName = snapshot.contactName
                vendor.phone = snapshot.phone
                vendor.email = snapshot.email
                vendor.accountNumber = snapshot.accountNumber
                vendor.notes = snapshot.notes
                vendor.isActive = snapshot.isActive
                context.insert(vendor)
                vendorsByID[snapshot.id] = vendor
            }

            var binsByLabel: [String: StorageBin] = [:]
            for snapshot in payload.bins {
                let bin = StorageBin(label: snapshot.label,
                                     locationNote: snapshot.locationNote,
                                     now: now)
                bin.id = snapshot.id
                bin.isActive = snapshot.isActive
                context.insert(bin)
                binsByLabel[snapshot.label] = bin
            }

            // --- cores and their history --------------------------------------------------
            var itemsByID: [UUID: CoreItem] = [:]
            for snapshot in payload.items {
                let vendor = snapshot.vendorIdentifier.flatMap { vendorsByID[$0] }
                let bin = snapshot.binLabel.flatMap { binsByLabel[$0] }

                let item = CoreItem(partName: snapshot.partName,
                                    expectedCredit: snapshot.expectedCredit,
                                    receivedDate: snapshot.receivedDate,
                                    vendor: vendor,
                                    bin: bin,
                                    now: now)
                item.id = snapshot.identifier
                item.partNumber = snapshot.partNumber
                item.invoiceReference = snapshot.invoiceReference
                item.repairOrderReference = snapshot.repairOrderReference
                item.creditReference = snapshot.creditReference
                item.notes = snapshot.notes
                item.status = snapshot.status
                item.actualCreditCents = snapshot.actualCredit?.cents
                item.dueDate = snapshot.dueDate
                item.returnedDate = snapshot.returnedDate
                item.creditedDate = snapshot.creditedDate
                item.createdAt = snapshot.createdAt
                item.updatedAt = snapshot.updatedAt
                item.usesCustomDueDate = BackupRestoreService.wasCustomDueDate(
                    snapshot: snapshot, vendor: vendor, calendar: calendar
                )
                context.insert(item)
                itemsByID[snapshot.identifier] = item

                for eventSnapshot in snapshot.events {
                    let event = CoreEvent(type: eventSnapshot.type,
                                          detail: eventSnapshot.detail,
                                          timestamp: eventSnapshot.timestamp,
                                          amount: eventSnapshot.amount,
                                          reference: eventSnapshot.reference,
                                          from: eventSnapshot.fromStatus,
                                          to: eventSnapshot.toStatus)
                    event.id = eventSnapshot.id
                    context.insert(event)
                    event.coreItem = item
                }
            }

            // --- returns ------------------------------------------------------------------
            for snapshot in payload.batches {
                let vendor = snapshot.vendorIdentifier.flatMap { vendorsByID[$0] }
                let batch = ReturnBatch(vendor: vendor,
                                        returnDate: snapshot.returnDate,
                                        method: snapshot.method,
                                        reference: snapshot.reference,
                                        now: now)
                batch.id = snapshot.id
                batch.notes = snapshot.notes
                context.insert(batch)

                // Membership is rebuilt from the identifiers the file recorded. An identifier that
                // names no core is skipped rather than fatal: a batch missing one line is still a
                // batch, and refusing the whole restore over it would cost the shop everything else.
                for identifier in snapshot.itemIdentifiers {
                    if let item = itemsByID[identifier] {
                        item.returnBatch = batch
                    }
                }
            }

            try context.save()
        } catch {
            // The deletions and the half-built replacement go together. This is the line that makes
            // "a failed restore leaves the ledger unchanged" true rather than aspirational.
            context.rollback()
            throw BackupRestoreError.restoreFailed(String(describing: error))
        }
    }

    // MARK: Private

    /// The reminder and onboarding settings currently on this device.
    private func currentDeviceSettings() -> CarriedDeviceSettings {
        let descriptor = FetchDescriptor<ShopProfile>(
            sortBy: [SortDescriptor(\ShopProfile.createdAt, order: .forward)]
        )
        guard let profile = try? context.fetch(descriptor).first else {
            return CarriedDeviceSettings()
        }
        return CarriedDeviceSettings(profile)
    }

    /// Deletes every record **without saving**, so the whole restore is one transaction.
    ///
    /// Children first, then the records that own them, then the lookup tables they point at — the
    /// same order `ModelContainerFactory.deleteAllData` uses, minus its save.
    private func deleteEverythingWithoutSaving() throws {
        try deleteEvery(CoreEvent.self)
        try deleteEvery(Attachment.self)
        try deleteEvery(CoreItem.self)
        try deleteEvery(ReturnBatch.self)
        try deleteEvery(StorageBin.self)
        try deleteEvery(Vendor.self)
        try deleteEvery(ShopProfile.self)
    }

    private func deleteEvery<T: PersistentModel>(_ type: T.Type) throws {
        for object in try context.fetch(FetchDescriptor<T>()) {
            context.delete(object)
        }
    }

    /// Whether a restored core's deadline was set by hand.
    ///
    /// The backup records the due date but not whether it was overridden. Recomputing what the
    /// vendor's window would have produced and comparing tells us: if they differ, somebody set it
    /// deliberately, and marking it custom is what stops a later edit quietly moving a deadline the
    /// shop is relying on.
    private static func wasCustomDueDate(snapshot: CoreItemExportSnapshot,
                                         vendor: Vendor?,
                                         calendar: Calendar) -> Bool {
        guard let stored = snapshot.dueDate else { return false }
        let windowDays = vendor?.defaultReturnWindowDays
            ?? AppConfiguration.defaultVendorReturnWindowDays
        let computed = DueDateCalculator.dueDate(receivedDate: snapshot.receivedDate,
                                                 windowDays: windowDays,
                                                 calendar: calendar)
        return calendar.startOfDay(for: stored) != calendar.startOfDay(for: computed)
    }
}

// MARK: - Settings the backup does not carry

/// Notification preferences and onboarding state, carried across a restore.
///
/// These describe *this device*, not the ledger: which alerts this phone shows, and at what time.
/// The backup has never contained them. Resetting them to defaults on the strength of a file that
/// does not mention them would silently switch somebody's deadline reminders off on the very day
/// they restored a ledger full of deadlines.
struct CarriedDeviceSettings: Sendable {

    var remindersEnabled: Bool = true
    var reminderLeadDays: Int = AppConfiguration.defaultReminderLeadDays
    var reminderDueSoonLeadDaysRaw: String = ShopProfile.defaultDueSoonLeadDaysRaw
    var reminderHour: Int = AppConfiguration.defaultReminderHour
    var reminderMinute: Int = AppConfiguration.defaultReminderMinute
    var awaitingCreditReminderDelayDays: Int = ReminderPlanner.defaultAwaitingCreditDelayDays
    var disputeFollowUpReminderDelayDays: Int = ReminderPlanner.defaultDisputeFollowUpDelayDays
    var weeklySummaryEnabled: Bool = false
    var showsDetailInNotifications: Bool = false

    /// Onboarding is not repeated after a restore: a shop that has a backup has plainly been
    /// through it.
    var hasCompletedOnboarding: Bool = true

    init() { }

    @MainActor
    init(_ profile: ShopProfile) {
        remindersEnabled = profile.remindersEnabled
        reminderLeadDays = profile.reminderLeadDays
        reminderDueSoonLeadDaysRaw = profile.reminderDueSoonLeadDaysRaw
        reminderHour = profile.reminderHour
        reminderMinute = profile.reminderMinute
        awaitingCreditReminderDelayDays = profile.awaitingCreditReminderDelayDays
        disputeFollowUpReminderDelayDays = profile.disputeFollowUpReminderDelayDays
        weeklySummaryEnabled = profile.weeklySummaryEnabled
        showsDetailInNotifications = profile.showsDetailInNotifications
        hasCompletedOnboarding = true
    }

    @MainActor
    func apply(to profile: ShopProfile) {
        profile.remindersEnabled = remindersEnabled
        profile.reminderLeadDays = reminderLeadDays
        profile.reminderDueSoonLeadDaysRaw = reminderDueSoonLeadDaysRaw
        profile.reminderHour = reminderHour
        profile.reminderMinute = reminderMinute
        profile.awaitingCreditReminderDelayDays = awaitingCreditReminderDelayDays
        profile.disputeFollowUpReminderDelayDays = disputeFollowUpReminderDelayDays
        profile.weeklySummaryEnabled = weeklySummaryEnabled
        profile.showsDetailInNotifications = showsDetailInNotifications
        profile.hasCompletedOnboarding = hasCompletedOnboarding
    }
}
