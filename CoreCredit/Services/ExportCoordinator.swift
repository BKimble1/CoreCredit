//
//  ExportCoordinator.swift
//  CoreCredit
//
//  Drives every "Export" button: build, write, present, and — when something goes wrong — say so.
//

import Foundation
import Observation
import SwiftData
import UIKit

/// The single object a view talks to in order to produce a shareable file.
///
/// # Contract with the UI
///
/// No method throws. A view calls one of the `export…` methods inside a `Task`, watches `inFlight`
/// to show progress, and reacts to two published values:
/// - `presentedDocument` becomes non-`nil` when a file is ready — bind it to a `.sheet(item:)`
///   holding a `ShareLink`, then call `dismiss()` when the sheet closes.
/// - `lastError` becomes non-`nil` when the export failed — show it in an `ErrorBanner`.
///
/// # Housekeeping
///
/// Every export begins with `ExportFileStore.cleanUpOldExports()`, so files older than
/// `AppConfiguration.exportRetention` are swept out of the caches folder before a new one is
/// written. Exports are derivative data and are never stored in the documents directory.
///
/// # Where the work happens
///
/// Snapshotting reads SwiftData and therefore stays on the main actor. Everything after that runs
/// off it where the API allows: CSV assembly and JSON encoding are pure value work and are pushed
/// to a detached task. PDF rendering uses UIKit text layout and is `@MainActor` by contract, so it
/// stays here.
@MainActor
@Observable
final class ExportCoordinator {

    /// How many evidence photographs a dispute packet may carry. Enough to prove the case, few
    /// enough that a parts manager will actually read it and the file will still attach to an email.
    static let disputePacketImageLimit = 6

    private let dateProvider: any DateProvider

    /// True while an export is being built. Bind to a `LoadingOverlay` or a progress view.
    private(set) var inFlight: Bool = false

    /// The most recent failure, already phrased for a user. `nil` after a successful export.
    private(set) var lastError: String?

    /// The finished file waiting to be shared. Set `nil` (or call `dismiss()`) when the share sheet
    /// closes.
    var presentedDocument: ExportDocument?

    init(dateProvider: any DateProvider) {
        self.dateProvider = dateProvider
    }

    // MARK: - Exports

    /// Renders the multi-page dispute packet PDF for one core.
    func exportDisputePacket(for item: CoreItem, profile: ShopProfile) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        lastError = nil

        ExportFileStore.cleanUpOldExports()

        let snapshot = SnapshotBuilder.snapshot(item)
        let shop = SnapshotBuilder.snapshot(profile)
        let images = SnapshotBuilder.evidenceImages(
            for: item,
            limit: ExportCoordinator.disputePacketImageLimit
        )
        let generatedAt = dateProvider.now
        let name = ExportCoordinator.baseName(
            prefix: "CoreCredit-Dispute",
            detail: snapshot.displayTitle,
            date: generatedAt
        )

        do {
            let data = try DisputePacketBuilder.makePDFData(
                item: snapshot,
                shop: shop,
                images: images,
                generatedAt: generatedAt
            )
            presentedDocument = try ExportFileStore.write(data, baseName: name, kind: .pdf)
        } catch {
            lastError = ExportCoordinator.message(for: error)
        }
    }

    /// Writes the whole visible ledger as RFC 4180 CSV.
    ///
    /// Amounts go through `Money.plainDecimalString`, so the file contains exact cents and no
    /// locale grouping separators — it opens correctly in any spreadsheet, anywhere.
    func exportCSVLedger(items: [CoreItem], profile: ShopProfile) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        lastError = nil

        ExportFileStore.cleanUpOldExports()

        let snapshots = items.map { SnapshotBuilder.snapshot($0) }
        let currencyCode = profile.currencyCode
        let generatedAt = dateProvider.now
        let name = ExportCoordinator.baseName(
            prefix: "CoreCredit-Ledger",
            detail: profile.displayName,
            date: generatedAt
        )

        do {
            // Pure value work: safe and worthwhile to move off the main actor for a big ledger.
            let csv = await Task.detached(priority: .userInitiated) {
                CSVLedgerExporter.makeCSV(items: snapshots, currencyCode: currencyCode)
            }.value

            guard let data = csv.data(using: .utf8) else {
                throw ExportError.renderingFailed("The ledger could not be encoded as text.")
            }
            presentedDocument = try ExportFileStore.write(data, baseName: name, kind: .csv)
        } catch {
            lastError = ExportCoordinator.message(for: error)
        }
    }

    /// Renders the portfolio-level ledger report PDF: the `RiskSummary` totals, then one row per
    /// core.
    ///
    /// The summary is computed here rather than taken from a caller, so the printed page always
    /// agrees with the dashboard. "Overdue" and the aging buckets are judged against
    /// `dateProvider.now` on `dateProvider.calendar` — the same clock and calendar every other
    /// date-sensitive figure in the app is measured with, and the reason this is testable at all.
    ///
    /// Rendering stays on the main actor: `DisputePacketBuilder` is `@MainActor` by contract
    /// because it measures text with UIKit.
    func exportLedgerPDF(items: [CoreItem], profile: ShopProfile) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        lastError = nil

        ExportFileStore.cleanUpOldExports()

        let snapshots = items.map { SnapshotBuilder.snapshot($0) }
        let shop = SnapshotBuilder.snapshot(profile)
        let generatedAt = dateProvider.now
        let summary = RiskCalculator.summarize(
            snapshots,
            now: generatedAt,
            calendar: dateProvider.calendar
        )
        let name = ExportCoordinator.baseName(
            prefix: "CoreCredit-LedgerReport",
            detail: profile.displayName,
            date: generatedAt
        )

        do {
            let data = try DisputePacketBuilder.makeLedgerPDFData(
                items: snapshots,
                shop: shop,
                summary: summary,
                generatedAt: generatedAt
            )
            presentedDocument = try ExportFileStore.write(data, baseName: name, kind: .pdf)
        } catch {
            lastError = ExportCoordinator.message(for: error)
        }
    }

    /// Writes the complete portable backup as JSON. See `BackupPayload` for the documented shape.
    func exportJSONBackup(profile: ShopProfile,
                          vendors: [Vendor],
                          bins: [StorageBin],
                          items: [CoreItem],
                          batches: [ReturnBatch]) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        lastError = nil

        ExportFileStore.cleanUpOldExports()

        let generatedAt = dateProvider.now
        let payload = SnapshotBuilder.backup(
            profile: profile,
            vendors: vendors,
            bins: bins,
            items: items,
            batches: batches,
            appVersion: AppConfiguration.appVersion,
            exportedAt: generatedAt
        )
        let name = ExportCoordinator.baseName(
            prefix: "CoreCredit-Backup",
            detail: profile.displayName,
            date: generatedAt
        )

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try JSONBackupExporter.encode(payload)
            }.value
            presentedDocument = try ExportFileStore.write(data, baseName: name, kind: .json)
        } catch {
            lastError = ExportCoordinator.message(for: error)
        }
    }

    /// Renders the printable 4x6 bin tag, QR code included, so the core on the shelf can be
    /// scanned straight back to its record.
    func exportBinTag(for item: CoreItem, profile: ShopProfile) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        lastError = nil

        ExportFileStore.cleanUpOldExports()

        let snapshot = SnapshotBuilder.snapshot(item)
        let payload = BinTagPayload(item: snapshot)
        // A nil image is not an error: the renderer prints the tag without the code rather than
        // refusing to produce a label at all.
        let qrImage = QRCodeGenerator.image(for: payload.encodedString)
        let name = ExportCoordinator.baseName(
            prefix: "CoreCredit-BinTag",
            detail: snapshot.displayTitle,
            date: dateProvider.now
        )

        do {
            let data = try BinTagRenderer.makePDFData(
                item: snapshot,
                shopName: profile.displayName,
                currencyCode: profile.currencyCode,
                qrImage: qrImage
            )
            presentedDocument = try ExportFileStore.write(data, baseName: name, kind: .pdf)
        } catch {
            lastError = ExportCoordinator.message(for: error)
        }
    }

    // MARK: - Presentation

    /// Closes the share sheet. The file stays on disk until the retention sweep removes it, so a
    /// share extension that is still copying it does not fail.
    func dismiss() {
        presentedDocument = nil
    }

    /// Clears a surfaced failure once the user has dismissed the banner.
    func clearError() {
        lastError = nil
    }

    // MARK: - Private

    /// `"CoreCredit-Dispute-Alternator-2026-08-16-1412"`, sanitised downstream by
    /// `ExportFileStore.sanitizedFileName`.
    private static func baseName(prefix: String, detail: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        var parts = [prefix]
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetail.isEmpty {
            parts.append(trimmedDetail)
        }
        parts.append(formatter.string(from: date))
        return parts.joined(separator: "-")
    }

    /// Prefers a `LocalizedError`'s own sentence so the user reads "There is nothing to export yet."
    /// rather than a Cocoa error domain and code.
    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
