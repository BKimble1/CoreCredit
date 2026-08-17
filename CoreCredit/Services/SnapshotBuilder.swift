//
//  SnapshotBuilder.swift
//  CoreCredit
//
//  The one place SwiftData models become plain values. Everything downstream of here — CSV, JSON,
//  PDF — is pure and unit-testable.
//

import Foundation
import SwiftData

/// Maps `@Model` objects to the `Codable` snapshots the exporters consume.
///
/// `@MainActor` because it reads SwiftData relationships, which are bound to the model context.
/// Every function is a straight, side-effect-free read: nothing here mutates the store.
@MainActor
enum SnapshotBuilder {

    // MARK: - Core item

    /// Freezes one core item, including its timeline in chronological order and the reference and
    /// method of the batch it went back on.
    static func snapshot(_ item: CoreItem) -> CoreItemExportSnapshot {
        let batch = item.returnBatch

        return CoreItemExportSnapshot(
            identifier: item.id,
            partName: item.partName,
            partNumber: item.partNumber,
            invoiceReference: item.invoiceReference,
            repairOrderReference: item.repairOrderReference,
            creditReference: item.creditReference,
            notes: item.notes,
            binLabel: item.binLabel,
            vendorName: item.vendorName,
            vendorIdentifier: item.vendorIdentifier,
            status: item.status,
            expectedCredit: item.expectedCredit,
            actualCredit: item.actualCredit,
            receivedDate: item.receivedDate,
            dueDate: item.dueDate,
            returnedDate: item.returnedDate,
            creditedDate: item.creditedDate,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            returnBatchReference: nonEmpty(batch?.reference),
            returnMethod: batch?.method,
            // `timeline` is already sorted oldest-first, which is the order the dispute packet and
            // the backup file both want.
            events: item.timeline.map { snapshot($0) }
        )
    }

    /// Freezes one timeline entry.
    static func snapshot(_ event: CoreEvent) -> CoreEventSnapshot {
        CoreEventSnapshot(
            id: event.id,
            timestamp: event.timestamp,
            type: event.type,
            detail: event.detail,
            amount: event.amount,
            reference: event.reference,
            fromStatus: event.fromStatus,
            toStatus: event.toStatus
        )
    }

    // MARK: - Shop, vendors, bins, batches

    /// Freezes the shop letterhead. The postal address is split into non-empty lines here so the
    /// PDF renderer never has to deal with blank rows.
    static func snapshot(_ profile: ShopProfile) -> ShopProfileSnapshot {
        let addressLines = profile.formattedAddress
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ShopProfileSnapshot(
            name: profile.name,
            phone: profile.phone,
            email: profile.email,
            addressLines: addressLines,
            currencyCode: profile.currencyCode
        )
    }

    static func snapshot(_ vendor: Vendor) -> VendorSnapshot {
        VendorSnapshot(
            id: vendor.id,
            name: vendor.name,
            contactName: vendor.contactName,
            phone: vendor.phone,
            email: vendor.email,
            accountNumber: vendor.accountNumber,
            defaultReturnWindowDays: vendor.defaultReturnWindowDays,
            notes: vendor.notes,
            isActive: vendor.isActive
        )
    }

    static func snapshot(_ bin: StorageBin) -> StorageBinSnapshot {
        StorageBinSnapshot(
            id: bin.id,
            label: bin.label,
            locationNote: bin.locationNote,
            isActive: bin.isActive
        )
    }

    /// Freezes a return batch. Membership is recorded as identifiers only — the items themselves
    /// appear once, in `BackupPayload.items`.
    static func snapshot(_ batch: ReturnBatch) -> ReturnBatchSnapshot {
        ReturnBatchSnapshot(
            id: batch.id,
            vendorName: batch.vendor?.name ?? "",
            vendorIdentifier: batch.vendor?.id,
            returnDate: batch.returnDate,
            method: batch.method,
            reference: batch.reference,
            notes: batch.notes,
            itemIdentifiers: batch.coreItems.map { $0.id }
        )
    }

    // MARK: - Backup

    /// Builds the complete portable backup. See `BackupPayload` for the documented file shape.
    static func backup(profile: ShopProfile,
                       vendors: [Vendor],
                       bins: [StorageBin],
                       items: [CoreItem],
                       batches: [ReturnBatch],
                       appVersion: String,
                       exportedAt: Date) -> BackupPayload {
        BackupPayload(
            formatVersion: BackupPayload.currentFormatVersion,
            appVersion: appVersion,
            exportedAt: exportedAt,
            shop: snapshot(profile),
            vendors: vendors.map { snapshot($0) },
            bins: bins.map { snapshot($0) },
            items: items.map { snapshot($0) },
            batches: batches.map { snapshot($0) }
        )
    }

    // MARK: - Evidence

    /// The photographs that go into a dispute packet, in the order a vendor would want to see them.
    ///
    /// Pulls from **both** sides of the story: the core item's own attachments (the part, the box,
    /// the invoice) and the return batch's receipt attachments (proof the core physically went
    /// back). Item photos come first, then batch receipts; within each group, oldest first.
    ///
    /// Each caption states the kind of evidence and when it was taken — "Return receipt — 14 Mar
    /// 2026" — and appends the user's own caption when they wrote one. Attachments with no image
    /// bytes are skipped so the PDF never renders an empty frame.
    ///
    /// - Parameter limit: hard cap on the number of images, so a core with fifty photos still
    ///   produces a packet a vendor will actually read. Values below one return nothing.
    static func evidenceImages(for item: CoreItem, limit: Int) -> [(caption: String, data: Data)] {
        guard limit > 0 else { return [] }

        var results: [(caption: String, data: Data)] = []

        for attachment in item.photos {
            if results.count >= limit { break }
            guard !attachment.imageData.isEmpty else { continue }
            results.append((caption: caption(for: attachment), data: attachment.imageData))
        }

        if let receipts = item.returnBatch?.receipts {
            for attachment in receipts {
                if results.count >= limit { break }
                guard !attachment.imageData.isEmpty else { continue }
                results.append((caption: caption(for: attachment), data: attachment.imageData))
            }
        }

        return results
    }

    // MARK: - Private

    /// `"Invoice — 12 Mar 2026"`, plus the user's caption when present.
    private static func caption(for attachment: Attachment) -> String {
        let dateText = attachment.capturedAt.formatted(date: .abbreviated, time: .omitted)
        var text = attachment.kind.displayName + " — " + dateText

        let userCaption = attachment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userCaption.isEmpty {
            text += ". " + userCaption
        }
        return text
    }

    /// Maps a blank or whitespace-only string to `nil`, matching how the models treat empty text.
    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
