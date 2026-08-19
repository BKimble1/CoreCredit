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

        // The detector itself still has to work, or the guard it provides is gone. These are the
        // stand-ins this build no longer ships — it must still recognise them if one came back.
        #expect(AppConfiguration.isPlaceholder("https://example.com/corecredit/support"))
        #expect(AppConfiguration.isPlaceholder("support@example.com"))
        #expect(AppConfiguration.isPlaceholder(""))

        let email = AppConfiguration.configuredSupportEmail
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.supportEmail) == (email == nil))

        // And support is reachable only when at least one of the two is real.
        #expect(AppConfiguration.isSupportContactConfigured
                == (AppConfiguration.configuredSupportURL != nil
                    || AppConfiguration.configuredSupportEmail != nil))
    }

    @Test("This build ships real, reachable, owner-supplied values — the release gate")
    func thisBuildShipsTheOwnerSuppliedValues() throws {
        // This test used to assert the opposite: that the values were still unset, so that filling
        // them in would fail the suite and force the audit to be revisited. It has been revisited.
        // The values are supplied, the three pages were fetched over HTTPS and returned the
        // intended content anonymously, and the assertion is now the stronger one — that nothing
        // ever regresses to a stand-in.
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.supportURLString) == false)
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.privacyURLString) == false)
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.termsURLString) == false)
        #expect(AppConfiguration.isPlaceholder(AppConfiguration.supportEmail) == false)

        let support = try #require(AppConfiguration.configuredSupportURL)
        let privacy = try #require(AppConfiguration.configuredPrivacyURL)
        let terms = try #require(AppConfiguration.configuredTermsURL)
        let email = try #require(AppConfiguration.configuredSupportEmail)

        // App Review opens these. A non-HTTPS or malformed address is a rejection.
        for url in [support, privacy, terms] {
            #expect(url.scheme == "https", "\(url) must be served over HTTPS.")
            #expect((url.host ?? "").isEmpty == false)
        }

        #expect(email == "support@idlery.com")
        #expect(email.contains("@"))
        #expect(AppConfiguration.isSupportContactConfigured)

        // The exact published addresses, spelled out once. Comparing a value to itself through
        // `AppConfiguration` would pass even if the constants were wrong, which is the whole
        // failure mode a release gate exists to catch.
        #expect(support.absoluteString == "https://corecredit.idlery.com/support")
        #expect(privacy.absoluteString == "https://corecredit.idlery.com/privacy")
        #expect(terms.absoluteString == "https://corecredit.idlery.com/terms")

        // Every CoreCredit page is a path under the product's own host, and the company
        // site is separate. Asserted because the failure this catches is subtle: three
        // addresses that each resolve, on three different hosts, is a support experience
        // nobody can navigate.
        #expect(AppConfiguration.productURLString == "https://corecredit.idlery.com")
        #expect(AppConfiguration.companyURLString == "https://idlery.com")
        for address in [support, privacy, terms] {
            #expect(address.host == "corecredit.idlery.com",
                    "That address is not on CoreCredit's own host.")
        }
    }

    @Test("The support email opens a message addressed to support, with the version in it")
    func theSupportMailtoIsUsable() throws {
        let mailto = try #require(AppConfiguration.supportMailtoURL)

        #expect(mailto.scheme == "mailto")
        #expect(mailto.absoluteString.contains("support@idlery.com"))
        // The first question a support reply would otherwise have to ask.
        #expect(mailto.absoluteString.contains("subject="))
        #expect(mailto.absoluteString.contains(AppConfiguration.appVersion))
    }

    @Test("Nothing customer-facing points at a host CoreCredit does not control")
    func noStaleHostSurvives() {
        // The addresses moved from a project page on a code-hosting site to the product's
        // own subdomain. A build still pointing at the old one would send App Review, and
        // every customer, to a page nobody is maintaining.
        let addresses = [
            AppConfiguration.supportURLString,
            AppConfiguration.privacyURLString,
            AppConfiguration.termsURLString,
            AppConfiguration.productURLString,
            AppConfiguration.companyURLString,
        ]
        for address in addresses {
            #expect(address.hasPrefix("https://"), "Every public address must be HTTPS.")
            #expect(address.contains("github.io") == false)
            #expect(address.contains("netlify.app") == false)
            #expect(address.contains("localhost") == false)
        }
        #expect(AppConfiguration.supportEmail.hasSuffix("@idlery.com"))
    }

    @Test("The publisher is the company, never an individual")
    func thePublisherIsTheCompany() {
        #expect(AppConfiguration.companyName == "Idlery Services LLC")
        #expect(AppConfiguration.copyrightNotice
                == "© 2026 Idlery Services LLC. All rights reserved.")
        #expect(AppConfiguration.companyShortName == "Idlery")
        #expect(AppConfiguration.operatorStatement
                == "CoreCredit is operated by Idlery Services LLC.")
        #expect(AppConfiguration.distributionTerritory == "United States")

        // Nothing user-facing may carry the account holder's personal name. The bundle identifier
        // is deliberately excluded: it is a reverse-DNS identifier registered with Apple, it is
        // never displayed, and changing it would orphan the App Store Connect record and both
        // subscription products.
        let userFacing = [
            AppConfiguration.displayName,
            AppConfiguration.companyName,
            AppConfiguration.copyrightNotice,
            AppConfiguration.supportEmail,
            AppConfiguration.distributionTerritory
        ]
        for value in userFacing {
            let lowered = value.lowercased()
            #expect(lowered.contains("blake") == false, "\(value) names an individual.")
            #expect(lowered.contains("kimble") == false, "\(value) names an individual.")
        }
    }

    // MARK: - The bundled documents

    @Test("The bundled documents name the publisher, the contact, the venue, and the territory")
    func theBundledDocumentsCarryTheRealValues() throws {
        let documents = LegalDocumentStore.loadAll(from: .main)
        let all = documents.map(\.plainText).joined(separator: "\n")

        // Absence of a placeholder is not presence of the real thing. These are the clauses a
        // reviewer, and a court, would actually look for.
        #expect(all.contains(AppConfiguration.companyName))
        #expect(all.contains(AppConfiguration.supportEmail))
        #expect(all.contains("United States only"))

        let terms = try #require(documents.first { $0.identifier == "terms-of-use" })
        let termsText = terms.plainText
        #expect(termsText.contains("laws of the State of Ohio"))
        #expect(termsText.contains("Butler County, Ohio"))

        // No individual is named anywhere a reader can see.
        for document in documents {
            #expect(document.plainText.localizedCaseInsensitiveContains("Blake") == false,
                    "\(document.identifier) names an individual.")
        }
    }

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
