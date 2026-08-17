//
//  PlaceholderAuditTests.swift
//  CoreCreditTests
//
//  A pre-release gate. `AppConfiguration` still ships `example.com` stand-ins for the support page,
//  the published policy pages, and the support address. The app is written so a stand-in is never
//  printed to the screen — `isPlaceholder(_:)` decides that at runtime — and the tests below hold
//  that promise to it. They also hold the line on two claims the app makes about itself: that the
//  bundled legal documents name no placeholder address, and that the privacy manifest declares no
//  tracking and no collected data.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Nothing unfinished can reach a screen, a legal document, or the privacy manifest")
struct PlaceholderAuditTests {

    // MARK: - isPlaceholder

    @Test("A stand-in address is recognised however it is written, and a real one is not")
    func aStandInAddressIsRecognisedHoweverItIsWritten() {
        // The shipped stand-ins.
        #expect(AppConfiguration.isPlaceholder("https://example.com/corecredit/support"))
        #expect(AppConfiguration.isPlaceholder("https://example.com/corecredit/privacy"))
        #expect(AppConfiguration.isPlaceholder("https://example.com/corecredit/terms"))
        #expect(AppConfiguration.isPlaceholder("support@example.com"))

        // Case and surrounding whitespace do not hide one.
        #expect(AppConfiguration.isPlaceholder("HTTPS://EXAMPLE.COM/corecredit/support"))
        #expect(AppConfiguration.isPlaceholder("  https://Example.Com/support  "))
        #expect(AppConfiguration.isPlaceholder("mailto:Support@EXAMPLE.com"))

        // An unset value counts as unconfigured too, so no screen can print an empty contact row.
        #expect(AppConfiguration.isPlaceholder(""))
        #expect(AppConfiguration.isPlaceholder("   "))
        #expect(AppConfiguration.isPlaceholder("\n\t"))

        // Every domain RFC 2606 reserves for documentation counts, not only the one this build
        // happens to ship. `example.org` and `example.net` can never be registered by anyone, so
        // an address at either is a stand-in copied from a template — printing it would hand a
        // shop a support link that cannot ever resolve.
        #expect(AppConfiguration.isPlaceholder("https://example.org/support"))
        #expect(AppConfiguration.isPlaceholder("support@example.net"))

        // A real address is left alone.
        #expect(AppConfiguration.isPlaceholder("https://corecredit.app/support") == false)
        #expect(AppConfiguration.isPlaceholder("support@corecredit.app") == false)

        // Matching is on the whole host label, not a bare substring: `myexample.company` is a
        // registrable domain that merely contains the reserved one.
        #expect(AppConfiguration.isPlaceholder("https://myexample.company/support") == false)

        // The reserved `.example` top-level domain is deliberately NOT treated as a stand-in.
        // `isPlaceholder` matches reserved second-level hosts, and widening it to a TLD rule is a
        // separate decision — recorded here so the gap is a choice rather than an oversight.
        #expect(AppConfiguration.isPlaceholder("https://corecredit.example/support") == false)
    }

    @Test("A stand-in never becomes a configured value, and a real one always does")
    func aStandInNeverBecomesAConfiguredValue() {
        // The invariant that every "not configured yet" message in the app depends on.
        let urls: [(String, URL?)] = [
            (AppConfiguration.supportURLString, AppConfiguration.configuredSupportURL),
            (AppConfiguration.privacyURLString, AppConfiguration.configuredPrivacyURL),
            (AppConfiguration.termsURLString, AppConfiguration.configuredTermsURL)
        ]
        for (value, configured) in urls {
            #expect(AppConfiguration.isPlaceholder(value) == (configured == nil),
                    "A configured accessor must be nil for exactly the stand-in values: \(value)")
        }

        let email = AppConfiguration.configuredSupportEmail
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.supportEmail) == (email == nil))

        // And support is reachable only when at least one of the two is real.
        #expect(AppConfiguration.isSupportContactConfigured
                == (AppConfiguration.configuredSupportURL != nil
                    || AppConfiguration.configuredSupportEmail != nil))
    }

    @Test("This build still ships the owner-supplied values unset, so no screen shows one")
    func thisBuildStillShipsTheOwnerSuppliedValuesUnset() {
        // This is the release gate: when the owner fills these in, this test is what tells them the
        // audit needs updating. Until then, every accessor must hand back nothing.
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.supportURLString))
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.privacyURLString))
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.termsURLString))
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.supportEmail))

        #expect(AppConfiguration.configuredSupportURL == nil)
        #expect(AppConfiguration.configuredPrivacyURL == nil)
        #expect(AppConfiguration.configuredTermsURL == nil)
        #expect(AppConfiguration.configuredSupportEmail == nil)
        #expect(AppConfiguration.isSupportContactConfigured == false)
    }

    // MARK: - The bundled documents

    @Test("No bundled legal document contains a placeholder address")
    func noBundledLegalDocumentContainsAPlaceholderAddress() throws {
        let documents = LegalDocumentStore.loadAll(from: .main)
        #expect(documents.count == LegalDocumentID.allCases.count)

        for document in documents {
            let text = document.plainText
            #expect(text.isEmpty == false)

            // `isPlaceholder` is the same rule the rest of the app uses to hide an unset address.
            #expect(AppConfiguration.isPlaceholder(text) == false,
                    "The \(document.identifier) document contains a placeholder address.")
            #expect(text.localizedCaseInsensitiveContains("example.com") == false,
                    "The \(document.identifier) document names example.com.")

            // Belt and braces: the fields the reader actually sees, checked one at a time.
            #expect(document.title.localizedCaseInsensitiveContains("example.com") == false)
            #expect(document.summary.localizedCaseInsensitiveContains("example.com") == false)
            for section in document.sections {
                #expect(section.heading.localizedCaseInsensitiveContains("example.com") == false)
                for paragraph in section.paragraphs {
                    #expect(paragraph.localizedCaseInsensitiveContains("example.com") == false,
                            "A paragraph of \(document.identifier) names example.com.")
                }
            }
        }
    }

    // MARK: - The privacy manifest

    @Test("The privacy manifest declares no tracking and no collected data")
    func thePrivacyManifestDeclaresNoTrackingAndNoCollectedData() throws {
        let url = try privacyManifestURL()
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let manifest = try #require(parsed as? [String: Any],
                                    "PrivacyInfo.xcprivacy must decode as a dictionary.")

        // The app opens no network connection, so there is nothing to track with and nothing to send.
        let tracking = try #require(manifest["NSPrivacyTracking"] as? Bool,
                                    "NSPrivacyTracking must be declared.")
        #expect(tracking == false)

        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [Any],
                                     "NSPrivacyCollectedDataTypes must be declared.")
        #expect(collected.isEmpty)

        // No tracking means no tracking domains, which is what an analytics or ad SDK would add.
        let trackingDomains = try #require(manifest["NSPrivacyTrackingDomains"] as? [Any],
                                           "NSPrivacyTrackingDomains must be declared.")
        #expect(trackingDomains.isEmpty)

        // Only the required-reason APIs the shipped code actually reaches are declared.
        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
                                    "NSPrivacyAccessedAPITypes must be declared.")
        let categories = accessed.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        #expect(Set(categories) == [
            "NSPrivacyAccessedAPICategoryFileTimestamp",
            "NSPrivacyAccessedAPICategoryUserDefaults"
        ])
        #expect(categories.count == accessed.count)
        for entry in accessed {
            let reasons = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            #expect(reasons.isEmpty == false)
        }
    }

    // MARK: - Private

    /// The privacy manifest as copied into the app bundle. Two lookups, because Xcode is free to
    /// flatten a synchronised folder's resources or keep them under their own subdirectory — the
    /// same reason `LegalDocumentStore.load(_:from:)` tries both.
    private func privacyManifestURL() throws -> URL {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy", subdirectory: "Resources")
        ]
        let found = candidates.compactMap { $0 }.first
        return try #require(found, "PrivacyInfo.xcprivacy must be copied into the app bundle.")
    }
}
