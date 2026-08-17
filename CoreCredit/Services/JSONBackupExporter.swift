//
//  JSONBackupExporter.swift
//  CoreCredit
//
//  The documented, portable backup format. Pure Foundation — no file system, no UIKit.
//

import Foundation

/// Encodes and decodes `BackupPayload`, CoreCredit's whole-ledger backup file.
///
/// # Why these encoder settings
///
/// - `.iso8601` dates — unambiguous, time-zone explicit, and readable by every other tool.
/// - `.sortedKeys` — key order is stable, so two backups of the same ledger produce identical
///   bytes and a diff shows only what actually changed.
/// - `.prettyPrinted` — a shop owner (or a support engineer) can open the file in any text editor
///   and read it.
/// - `.withoutEscapingSlashes` — keeps URLs and references legible.
///
/// # Money is never floating point
///
/// `Money` encodes as `{"cents": 8650}`, an exact `Int64`. There is no `Double` anywhere in the
/// file, so a value survives any number of export/import round trips without drift.
///
/// # Version gate
///
/// `decode(_:)` refuses a file whose `formatVersion` is newer than
/// `BackupPayload.currentFormatVersion` rather than importing it partially. Older files are
/// accepted: fields added since simply take their defaults.
enum JSONBackupExporter {

    /// Serialises a backup.
    ///
    /// - Throws: `ExportError.renderingFailed` when the payload cannot be encoded.
    static func encode(_ payload: BackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            return try encoder.encode(payload)
        } catch {
            throw ExportError.renderingFailed(
                "The backup could not be written. " + error.localizedDescription
            )
        }
    }

    /// Reads a backup produced by this or an earlier build.
    ///
    /// - Throws: `ExportError.noData` for an empty file, and `ExportError.renderingFailed` with a
    ///   plain-language message when the file is not valid CoreCredit JSON or was written by a
    ///   newer version of the app.
    static func decode(_ data: Data) throws -> BackupPayload {
        guard !data.isEmpty else { throw ExportError.noData }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload: BackupPayload
        do {
            payload = try decoder.decode(BackupPayload.self, from: data)
        } catch {
            throw ExportError.renderingFailed(
                "This file is not a CoreCredit backup, or it is damaged. " + error.localizedDescription
            )
        }

        guard payload.formatVersion <= BackupPayload.currentFormatVersion else {
            throw ExportError.renderingFailed(
                "This backup was created by a newer version of "
                    + AppConfiguration.displayName
                    + " (format \(payload.formatVersion), this build reads \(BackupPayload.currentFormatVersion))."
                    + " Update the app, then try again."
            )
        }

        return payload
    }
}
