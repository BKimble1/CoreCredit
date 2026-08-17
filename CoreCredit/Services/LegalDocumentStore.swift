//
//  LegalDocumentStore.swift
//  CoreCredit
//

import Foundation

/// Why a bundled legal document could not be read.
///
/// Named cases rather than a swallowed `nil`: a missing or malformed policy is a shipping defect,
/// and the screen has to be able to say which document failed instead of showing an empty page.
enum LegalDocumentLoadError: LocalizedError, Equatable {

    /// No `<name>.json` in the bundle. Almost always a resource that was not copied into the target.
    case resourceMissing(String)

    /// The file exists but is not a `LegalDocument` — malformed JSON, or a renamed field.
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "The " + name + " document is missing from this copy of the app."
        case .decodingFailed(let name):
            return "The " + name + " document in this copy of the app could not be read."
        }
    }
}

/// Reads the bundled legal documents.
///
/// There is no caching layer and no networking. Each document is a few kilobytes of JSON compiled
/// into the app, read once when a screen appears; a cache would buy nothing and would be one more
/// thing to invalidate.
enum LegalDocumentStore {

    /// Loads from the main bundle. `bundle` is injectable so tests can exercise the
    /// missing-resource path without shipping a broken app.
    ///
    /// Two lookups are attempted because Xcode is free to copy a synchronised folder's resources
    /// either flattened at the bundle root or under their own subdirectory. Trying both keeps the
    /// app working under either layout instead of depending on a build detail.
    static func load(_ id: LegalDocumentID, from bundle: Bundle = .main) throws -> LegalDocument {
        let flat = bundle.url(forResource: id.resourceName, withExtension: "json")
        let nested = bundle.url(
            forResource: id.resourceName,
            withExtension: "json",
            subdirectory: LegalDocumentStore.subdirectory
        )

        guard let url = flat ?? nested else {
            throw LegalDocumentLoadError.resourceMissing(id.resourceName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LegalDocumentLoadError.resourceMissing(id.resourceName)
        }

        do {
            return try JSONDecoder().decode(LegalDocument.self, from: data)
        } catch {
            throw LegalDocumentLoadError.decodingFailed(id.resourceName)
        }
    }

    /// Every document that could be read, in declaration order.
    ///
    /// Non-throwing on purpose: a hub listing three documents should still list the two that are
    /// fine. The screen for a document that failed reports the failure itself.
    static func loadAll(from bundle: Bundle = .main) -> [LegalDocument] {
        LegalDocumentID.allCases.compactMap { id in
            try? load(id, from: bundle)
        }
    }

    /// Folder the JSON documents live in inside the source tree.
    private static let subdirectory = "Legal"
}
