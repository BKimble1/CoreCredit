//
//  LegalDocument.swift
//  CoreCredit
//

import Foundation

/// One legal document, exactly as it ships inside the app bundle.
///
/// The documents are *offline*. They are decoded from JSON that is compiled into the app, rendered
/// natively, and never fetched: nothing in CoreCredit opens a network connection, and a legal
/// document that only exists on a web server is a legal document a shop cannot read at the parts
/// counter with no signal.
///
/// The shape is deliberately dumb — headings and paragraphs, no markup, no styling hints — so the
/// text can be rendered as SwiftUI views, spoken by VoiceOver, searched, and shared as plain text
/// without a parser standing in the middle.
struct LegalDocument: Codable, Equatable, Sendable, Identifiable {

    /// Stable machine name, matching the JSON file's name and `LegalDocumentID.rawValue`.
    var identifier: String

    /// Screen title, e.g. "Privacy Policy".
    var title: String

    /// Document version, independent of the app's version. Bumped whenever the wording changes.
    var version: String

    /// ISO-style `yyyy-MM-dd`. Kept as text so decoding can never fail on a date format, and so the
    /// value shown is exactly the value written by whoever edited the document.
    var effectiveDate: String

    /// One honest sentence describing the document, shown above the body.
    var summary: String

    var sections: [LegalSection]

    var id: String { identifier }

    /// Whole document as plain text, for Share Sheet export.
    ///
    /// Plain text rather than a file: it pastes into a mail body, a note, or a message without an
    /// attachment, which is what a shop owner sending a policy to their bookkeeper actually needs.
    var plainText: String {
        var lines: [String] = []
        lines.append(title)
        lines.append("Version " + version + ", effective " + effectiveDate)
        lines.append("")
        lines.append(summary)

        for section in sections {
            lines.append("")
            lines.append(section.heading)
            for paragraph in section.paragraphs {
                lines.append("")
                lines.append(paragraph)
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Case- and diacritic-insensitive section filter powering search.
    ///
    /// Blank or whitespace-only text matches everything, so clearing the field restores the whole
    /// document. A section matches when its heading or any of its paragraphs contains the text.
    func sections(matching query: String) -> [LegalSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return sections }

        return sections.filter { section in
            if LegalDocument.contains(section.heading, needle) { return true }
            return section.paragraphs.contains { LegalDocument.contains($0, needle) }
        }
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A heading and the paragraphs underneath it.
///
/// The heading doubles as the identity, so headings within one document must be unique. That is a
/// property of the shipped JSON rather than something enforced at runtime; duplicate headings would
/// only confuse a `ForEach`, never crash it.
struct LegalSection: Codable, Equatable, Sendable, Identifiable {

    var heading: String
    var paragraphs: [String]

    var id: String { heading }
}

/// The documents that ship with the app.
///
/// The raw value is both the JSON resource name and the document's `identifier`, so adding a
/// document is one case plus one file, with nothing to keep in sync by hand.
enum LegalDocumentID: String, CaseIterable, Sendable {

    case privacyPolicy = "privacy-policy"
    case termsOfUse = "terms-of-use"
    case localDataAndBackup = "local-data-and-backup"

    /// Bundle resource name, without the `.json` extension.
    var resourceName: String { rawValue }

    /// Title used in navigation and in list rows before the document has been read from the bundle.
    ///
    /// It duplicates the `title` inside each JSON file on purpose: a row must have something honest
    /// to show even when the resource is missing, which is exactly the case where the title is not
    /// available to read.
    var displayName: String {
        switch self {
        case .privacyPolicy:
            return "Privacy Policy"
        case .termsOfUse:
            return "Terms of Use"
        case .localDataAndBackup:
            return "Local Data and Backup"
        }
    }
}
