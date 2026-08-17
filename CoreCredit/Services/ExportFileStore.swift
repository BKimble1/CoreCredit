//
//  ExportFileStore.swift
//  CoreCredit
//
//  Where generated files live between "Export" and the share sheet.
//

import Foundation

// MARK: - Kind

/// The three things CoreCredit can produce.
enum ExportKind: String, Codable, Sendable {
    case pdf
    case csv
    case json

    /// File extension, without the dot.
    var fileExtension: String { rawValue }

    /// Uniform Type Identifier, used when handing the file to `UIActivityViewController` /
    /// `ShareLink` so receiving apps know what they are getting.
    var utTypeIdentifier: String {
        switch self {
        case .pdf: return "com.adobe.pdf"
        case .csv: return "public.comma-separated-values-text"
        case .json: return "public.json"
        }
    }
}

// MARK: - Document

/// A file that has been written and is ready to share.
struct ExportDocument: Identifiable, Equatable, Sendable {

    var id: UUID

    /// Location on disk, inside the app's own caches directory.
    var url: URL

    /// The file name to offer in the share sheet, e.g. `"CoreCredit-Dispute-Alternator-2026-08-16.pdf"`.
    var suggestedName: String

    var kind: ExportKind

    init(id: UUID = UUID(), url: URL, suggestedName: String, kind: ExportKind) {
        self.id = id
        self.url = url
        self.suggestedName = suggestedName
        self.kind = kind
    }
}

// MARK: - Errors

/// Why an export did not produce a shareable file.
enum ExportError: LocalizedError, Equatable {

    /// The renderer (PDF, JSON encoder, CSV encoder) could not produce bytes.
    case renderingFailed(String)

    /// The bytes existed but could not be written to disk.
    case writeFailed(String)

    /// There was nothing to export.
    case noData

    var errorDescription: String? {
        switch self {
        case .renderingFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "The file could not be created."
            }
            return trimmed
        case .writeFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "The file could not be saved to this device."
            }
            return "The file could not be saved to this device. " + trimmed
        case .noData:
            return "There is nothing to export yet."
        }
    }
}

// MARK: - Store

/// Owns the app-controlled temporary location every export is written to.
///
/// Exports are **not** written to the documents directory: they are derivative, regenerable
/// artefacts, so they live in `Caches/CoreCreditExports`. The system may reclaim that folder under
/// storage pressure, and `cleanUpOldExports()` sweeps it on every export anyway, so a shop that
/// exports a packet every day never accumulates a year of stale PDFs.
enum ExportFileStore {

    /// Folder name inside `Caches`. Namespaced so a sweep can never touch another framework's
    /// cached files.
    static let directoryName = "CoreCreditExports"

    /// Longest base name (before the extension) a generated file may have.
    static let maximumBaseNameLength = 80

    /// Fallback when a caller supplies a name that sanitises down to nothing.
    static let fallbackBaseName = "CoreCredit-Export"

    /// `Caches/CoreCreditExports`, created on first use.
    ///
    /// - Throws: `ExportError.writeFailed` when the folder cannot be created.
    static func directory() throws -> URL {
        let manager = FileManager.default
        do {
            let caches = try manager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let folder = caches.appendingPathComponent(directoryName, isDirectory: true)
            if !manager.fileExists(atPath: folder.path) {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            return folder
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Writes `data` into the exports folder and describes the result.
    ///
    /// The name is sanitised first, then de-duplicated: exporting the same packet twice in one
    /// session yields `…-2.pdf` rather than overwriting a file the share sheet may still be
    /// holding open.
    ///
    /// - Throws: `ExportError.noData` for empty data, `ExportError.writeFailed` for any I/O failure.
    @discardableResult
    static func write(_ data: Data, baseName: String, kind: ExportKind) throws -> ExportDocument {
        guard !data.isEmpty else { throw ExportError.noData }

        let folder = try directory()
        let safeBase = sanitizedFileName(baseName)
        let url = uniqueURL(in: folder, baseName: safeBase, fileExtension: kind.fileExtension)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }

        return ExportDocument(
            id: UUID(),
            url: url,
            suggestedName: url.lastPathComponent,
            kind: kind
        )
    }

    /// Deletes generated files older than `interval`.
    ///
    /// Deliberately non-throwing: housekeeping must never be the reason an export fails, so every
    /// step is best-effort. Called at the start of each export by `ExportCoordinator`.
    static func cleanUpOldExports(olderThan interval: TimeInterval = AppConfiguration.exportRetention) {
        let manager = FileManager.default
        guard let folder = try? directory() else { return }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return
        }

        let retention = interval > 0 ? interval : 0
        let cutoff = Date().addingTimeInterval(-retention)

        for fileURL in contents {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            guard let modified = values.contentModificationDate else { continue }
            if modified < cutoff {
                try? manager.removeItem(at: fileURL)
            }
        }
    }

    /// Turns arbitrary text — a shop name, a part name — into something safe to put in a path.
    ///
    /// Replaces path separators, reserved characters, and whitespace with hyphens, collapses runs,
    /// strips leading and trailing punctuation, and caps the length. Never returns an empty string.
    static func sanitizedFileName(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")

        var result = ""
        var lastWasSeparator = false

        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                // Any run of disallowed characters — spaces, slashes, colons, emoji — collapses
                // into a single hyphen.
                result.append("-")
                lastWasSeparator = true
            }
        }

        while let first = result.first, first == "-" || first == "." || first == "_" {
            result.removeFirst()
        }
        while let last = result.last, last == "-" || last == "." || last == "_" {
            result.removeLast()
        }

        if result.count > maximumBaseNameLength {
            result = String(result.prefix(maximumBaseNameLength))
            while let last = result.last, last == "-" || last == "." || last == "_" {
                result.removeLast()
            }
        }

        return result.isEmpty ? fallbackBaseName : result
    }

    // MARK: - Private

    /// First free `base.ext`, `base-2.ext`, `base-3.ext`… falling back to a UUID suffix so this
    /// can never loop unbounded.
    private static func uniqueURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        let manager = FileManager.default
        let firstCandidate = folder.appendingPathComponent(baseName + "." + fileExtension, isDirectory: false)
        if !manager.fileExists(atPath: firstCandidate.path) {
            return firstCandidate
        }

        var suffix = 2
        while suffix <= 50 {
            let candidate = folder.appendingPathComponent(
                baseName + "-" + String(suffix) + "." + fileExtension,
                isDirectory: false
            )
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }

        let unique = baseName + "-" + UUID().uuidString + "." + fileExtension
        return folder.appendingPathComponent(unique, isDirectory: false)
    }
}
