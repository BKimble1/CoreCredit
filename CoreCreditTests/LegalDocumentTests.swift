//
//  LegalDocumentTests.swift
//  CoreCreditTests
//
//  The privacy policy, the terms, and the local-data note ship *inside* the app: they are decoded
//  from bundled JSON and rendered natively, because a legal document that only exists on a web
//  server is one a shop cannot read at the parts counter with no signal.
//
//  Nothing here reads the wall clock; the only date handled is the `yyyy-MM-dd` text each document
//  carries, checked through a POSIX formatter pinned to `TestClock.calendar`.
//

import Foundation
import Testing
@testable import CoreCredit

/// Anchors `Bundle(for:)` on the **test** bundle, which ships none of the app's resources and is
/// therefore a genuine stand-in for a build where a document failed to be copied in.
private final class LegalTestBundleAnchor {}

@Suite("The bundled legal documents load offline, read as whole documents, and can be searched")
struct LegalDocumentTests {

    // MARK: - Fixtures

    /// The app bundle — the same one `LegalDocumentStore.load(_:)` reads by default.
    private var appBundle: Bundle { .main }

    /// A bundle with no legal documents in it at all.
    private var bundleWithoutDocuments: Bundle { Bundle(for: LegalTestBundleAnchor.self) }

    /// Parses the `yyyy-MM-dd` effective date without touching `Calendar.current` or `Date()`.
    private func effectiveDateIsWellFormed(_ text: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = TestClock.calendar
        formatter.timeZone = TestClock.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) != nil
    }

    /// A synthetic document, so the search assertions do not depend on the shipped wording.
    private func makeDocument() -> LegalDocument {
        LegalDocument(
            identifier: "test-document",
            title: "Test Document",
            version: "9.9",
            effectiveDate: "2026-01-02",
            summary: "A synthetic document used only by this suite.",
            sections: [
                LegalSection(heading: "Caf\u{E9} notes",
                             paragraphs: ["The na\u{EF}ve r\u{E9}sum\u{E9} is filed here."]),
                LegalSection(heading: "Storage",
                             paragraphs: ["Everything stays on the device.", "Nothing is uploaded."]),
                LegalSection(heading: "Contact",
                             paragraphs: ["Write to the shop owner."])
            ]
        )
    }

    // MARK: - Loading

    @Test("All three bundled documents load, and every one is a complete document")
    func allThreeBundledDocumentsLoadAndAreComplete() throws {
        #expect(LegalDocumentID.allCases.count == 3)

        for id in LegalDocumentID.allCases {
            let document = try LegalDocumentStore.load(id, from: appBundle)

            // The raw value is the file name, the identifier, and nothing has to be kept in sync.
            #expect(document.identifier == id.rawValue)
            #expect(document.identifier == id.resourceName)
            #expect(document.title.isEmpty == false)
            #expect(document.title == id.displayName)

            // Versioned and dated, so a shop can tell which wording it agreed to.
            #expect(document.version.isEmpty == false)
            #expect(document.effectiveDate.isEmpty == false)
            #expect(effectiveDateIsWellFormed(document.effectiveDate),
                    "The effective date must be yyyy-MM-dd: \(document.effectiveDate)")

            #expect(document.summary.isEmpty == false)

            // At least one section, and no section is an empty heading with nothing under it.
            #expect(document.sections.isEmpty == false)
            for section in document.sections {
                #expect(section.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                #expect(section.paragraphs.isEmpty == false,
                        "Section \(section.heading) of \(id.rawValue) has no paragraphs.")
                for paragraph in section.paragraphs {
                    #expect(paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                }
            }
        }
    }

    @Test("The hub lists every document that could be read, in declaration order")
    func theHubListsEveryDocumentInDeclarationOrder() {
        let documents = LegalDocumentStore.loadAll(from: appBundle)

        #expect(documents.count == LegalDocumentID.allCases.count)
        #expect(documents.map(\.identifier) == LegalDocumentID.allCases.map(\.rawValue))
        #expect(documents.map(\.identifier) == ["privacy-policy", "terms-of-use", "local-data-and-backup"])
    }

    @Test("A document missing from the bundle is reported, not crashed on")
    func aMissingDocumentIsReportedRatherThanCrashedOn() {
        for id in LegalDocumentID.allCases {
            #expect(throws: LegalDocumentLoadError.resourceMissing(id.resourceName)) {
                _ = try LegalDocumentStore.load(id, from: bundleWithoutDocuments)
            }
        }

        // The hub still renders: it simply lists nothing rather than failing as a whole.
        #expect(LegalDocumentStore.loadAll(from: bundleWithoutDocuments).isEmpty)

        // The failure is a sentence a shop owner can read, naming the document that is missing.
        let error = LegalDocumentLoadError.resourceMissing("privacy-policy")
        #expect(error.errorDescription == "The privacy-policy document is missing from this copy of the app.")
    }

    // MARK: - Plain text

    @Test("Plain text carries the whole document, heading by heading")
    func plainTextCarriesTheWholeDocument() throws {
        let document = makeDocument()
        let text = document.plainText

        #expect(text.hasPrefix("Test Document\nVersion 9.9, effective 2026-01-02\n"))
        #expect(text.contains("A synthetic document used only by this suite."))
        for section in document.sections {
            #expect(text.contains(section.heading))
            for paragraph in section.paragraphs {
                #expect(text.contains(paragraph))
            }
        }

        // The shipped documents export whole too — this is what the Share Sheet hands over.
        for id in LegalDocumentID.allCases {
            let bundled = try LegalDocumentStore.load(id, from: appBundle)
            let bundledText = bundled.plainText

            #expect(bundledText.contains(bundled.title))
            #expect(bundledText.contains("Version " + bundled.version + ", effective " + bundled.effectiveDate))
            for section in bundled.sections {
                #expect(bundledText.contains(section.heading),
                        "Plain text of \(id.rawValue) is missing the heading \(section.heading).")
            }
        }
    }

    // MARK: - Search

    @Test("Search ignores case and accents, and a blank query restores the whole document")
    func searchIgnoresCaseAndAccentsAndABlankQueryRestoresEverything() {
        let document = makeDocument()

        // Blank, or nothing but whitespace, means "show me all of it".
        #expect(document.sections(matching: "") == document.sections)
        #expect(document.sections(matching: "   ") == document.sections)
        #expect(document.sections(matching: "\n\t ") == document.sections)

        // Headings match without their accents, and in any case.
        #expect(document.sections(matching: "cafe").map(\.heading) == ["Caf\u{E9} notes"])
        #expect(document.sections(matching: "CAF\u{C9}").map(\.heading) == ["Caf\u{E9} notes"])
        #expect(document.sections(matching: "Cafe Notes").isEmpty == false)

        // So do paragraphs, which is what makes the search worth having.
        #expect(document.sections(matching: "RESUME").map(\.heading) == ["Caf\u{E9} notes"])
        #expect(document.sections(matching: "uploaded").map(\.heading) == ["Storage"])
        #expect(document.sections(matching: "device").map(\.heading) == ["Storage"])

        // A query that matches nothing returns nothing rather than everything.
        #expect(document.sections(matching: "zzz-no-such-text").isEmpty)
    }

    @Test("Search over a shipped document filters it without losing anything")
    func searchOverAShippedDocumentFiltersItWithoutLosingAnything() throws {
        let policy = try LegalDocumentStore.load(.privacyPolicy, from: appBundle)

        #expect(policy.sections(matching: "").count == policy.sections.count)
        #expect(policy.sections(matching: "  ") == policy.sections)

        let matches = policy.sections(matching: "THE SHORT VERSION")
        #expect(matches.isEmpty == false)
        #expect(matches.count <= policy.sections.count)
        #expect(matches.allSatisfy { section in policy.sections.contains(section) })

        #expect(policy.sections(matching: "zzz-no-such-text").isEmpty)
    }
}
