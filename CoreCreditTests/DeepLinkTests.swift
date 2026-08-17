//
//  DeepLinkTests.swift
//  CoreCreditTests
//
//  The vocabulary of everything outside the app that can ask it to go somewhere: the Quick Scan
//  widget's `corecredit://scan`, and the `corecredit://item/<uuid>` a printed bin tag's QR code
//  carries. Parsing is the part worth testing exhaustively, because a scanner hands the app vendor
//  barcodes and shipping labels all day and `nil` has to be the ordinary, quiet answer.
//
//  Nothing here reads the wall clock: `DeepLink` and `DeepLinkRouter` are pure Foundation.
//

import Foundation
import Testing
@testable import CoreCredit

@Suite("Deep links parse exactly, and the router holds one until the shell is ready for it")
struct DeepLinkTests {

    // MARK: - Fixtures

    /// A fixed identifier, so every expectation below can be written out in full.
    private func makeItemID() throws -> UUID {
        try #require(UUID(uuidString: "6F2E4A10-0000-4000-8000-00000000ABCD"),
                     "The literal under test must be a well-formed UUID.")
    }

    private func makeURL(_ string: String) throws -> URL {
        try #require(URL(string: string), "The literal under test must be a URL: \(string)")
    }

    /// Parses a URL written as a literal, the way the system hands one to `onOpenURL`.
    private func parse(_ string: String) throws -> DeepLink? {
        DeepLink.parse(try makeURL(string))
    }

    /// A synthetic core. No real vendor, part number, or repair order appears in this suite.
    private func makeItem(id: UUID) -> TestItem {
        var item = TestItem()
        item.identifier = id
        item.partName = "Widget core"
        item.partNumber = "ZX-0042"
        item.vendorName = "Vendor Alpha"
        item.binLabel = "B7"
        item.expectedCredit = Money(cents: 12_345)
        return item
    }

    // MARK: - Scan

    @Test("corecredit://scan is the quick-scan link")
    func theScanURLParsesToTheScanLink() throws {
        #expect(try parse("corecredit://scan") == DeepLink.scan)
        #expect(DeepLink.scanHost == "scan")

        // The widget target cannot import this module and spells the same URL out by hand.
        #expect(try parse(ReminderRoute.scan) == DeepLink.scan)
        #expect(ReminderRoute.scan == "corecredit://scan")
    }

    @Test("A query string on the scan link is ignored, so a widget may tag where a tap came from")
    func aQueryStringOnTheScanLinkIsIgnored() throws {
        #expect(try parse("corecredit://scan?source=widget") == DeepLink.scan)
    }

    // MARK: - Item

    @Test("corecredit://item/<uuid> parses to that core, and round-trips through a bin tag payload")
    func theItemURLParsesAndRoundTripsThroughTheBinTagPayload() throws {
        let itemID = try makeItemID()
        let payload = BinTagPayload(item: makeItem(id: itemID))

        // The QR carries only the deep link — this is the exact string printed on a shelf label.
        #expect(payload.encodedString == "corecredit://item/" + itemID.uuidString)
        #expect(payload.itemID == itemID)

        #expect(try parse(payload.encodedString) == DeepLink.item(itemID))

        // The bin tag's own parser and the deep-link parser must agree; there is one item-URL rule.
        #expect(BinTagPayload.itemID(fromEncodedString: payload.encodedString) == itemID)
    }

    // MARK: - Tolerated spellings

    @Test("Scheme and host are compared case-insensitively, and a trailing slash is tolerated")
    func schemeAndHostAreCaseInsensitiveAndATrailingSlashIsTolerated() throws {
        let itemID = try makeItemID()

        #expect(try parse("CoreCredit://SCAN") == DeepLink.scan)
        #expect(try parse("CORECREDIT://Scan") == DeepLink.scan)
        #expect(try parse("corecredit://scan/") == DeepLink.scan)
        #expect(try parse("CoreCredit://SCAN/") == DeepLink.scan)

        #expect(try parse("CORECREDIT://ITEM/" + itemID.uuidString) == DeepLink.item(itemID))
        #expect(try parse("corecredit://item/" + itemID.uuidString + "/") == DeepLink.item(itemID))
        #expect(try parse("corecredit://item/" + itemID.uuidString.lowercased()) == DeepLink.item(itemID))
    }

    // MARK: - Rejected

    @Test("A foreign scheme, an unknown host, an empty host, a bad UUID, and a path under scan are all declined")
    func junkIsDeclinedRatherThanGuessedAt() throws {
        let itemID = try makeItemID()

        // Somebody else's link.
        #expect(try parse("https://corecredit.app/scan") == nil)
        #expect(try parse("otherapp://item/" + itemID.uuidString) == nil)

        // A host this build does not understand.
        #expect(try parse("corecredit://vendor/" + itemID.uuidString) == nil)
        #expect(try parse("corecredit://scanner") == nil)

        // No host at all — an empty authority is not a request to go anywhere.
        #expect(try parse("corecredit:///scan") == nil)
        #expect(try parse("corecredit:///item/" + itemID.uuidString) == nil)

        // An identifier that is not a UUID, or is missing entirely.
        #expect(try parse("corecredit://item/not-a-uuid") == nil)
        #expect(try parse("corecredit://item/6F2E4A10-0000-4000-8000") == nil)
        #expect(try parse("corecredit://item") == nil)
        #expect(try parse("corecredit://item/") == nil)

        // Extra path under `scan` means a link a later build defines; guessing would be worse.
        #expect(try parse("corecredit://scan/item") == nil)
        #expect(try parse("corecredit://scan/" + itemID.uuidString) == nil)

        // A vendor barcode, which is what the scanner hands over most of the time.
        #expect(BinTagPayload.itemID(fromEncodedString: "0123456789012") == nil)
        #expect(BinTagPayload.itemID(fromEncodedString: "   ") == nil)
        #expect(BinTagPayload.itemID(fromEncodedString: "") == nil)
    }

    // MARK: - The router

    @Test("A link that arrives before the shell exists is held, then consumed exactly once")
    @MainActor
    func aColdStartLinkIsHeldAndConsumedExactlyOnce() throws {
        let itemID = try makeItemID()
        let url = try makeURL("corecredit://item/" + itemID.uuidString)
        let router = DeepLinkRouter()

        // Cold start: the URL lands while `RootView` is still deciding what to show.
        #expect(router.pending == nil)
        #expect(router.handle(url))

        // The link waits rather than being dropped — it may be several taps until the shell reads it.
        #expect(router.pending == DeepLink.item(itemID))
        #expect(router.pending == DeepLink.item(itemID))

        #expect(router.consume() == DeepLink.item(itemID))
        #expect(router.consume() == nil)
        #expect(router.pending == nil)
    }

    @Test("While the app is already running a link is consumed immediately and leaves nothing behind")
    @MainActor
    func anAlreadyRunningAppConsumesTheLinkImmediately() throws {
        let url = try makeURL("corecredit://scan")
        let router = DeepLinkRouter()

        #expect(router.handle(url))
        #expect(router.consume() == DeepLink.scan)
        #expect(router.pending == nil)
        #expect(router.consume() == nil)
    }

    @Test("An unrecognised URL is refused and never wipes out a link the shell has not read yet")
    @MainActor
    func anUnrecognisedURLIsRefusedAndLeavesThePendingLinkAlone() throws {
        let itemID = try makeItemID()
        let itemURL = try makeURL("corecredit://item/" + itemID.uuidString)
        let foreignURL = try makeURL("https://corecredit.app/scan")
        let router = DeepLinkRouter()

        #expect(router.handle(itemURL))
        #expect(router.handle(foreignURL) == false)
        #expect(router.pending == DeepLink.item(itemID))

        // A newer understood link replaces an older one: the second tap is the one being waited on.
        router.handle(DeepLink.scan)
        #expect(router.pending == DeepLink.scan)
    }

    @Test("clear discards the pending link without consuming it")
    @MainActor
    func clearDiscardsWithoutConsuming() throws {
        let itemID = try makeItemID()
        let router = DeepLinkRouter()

        router.handle(DeepLink.item(itemID))
        #expect(router.pending == DeepLink.item(itemID))

        router.clear()

        #expect(router.pending == nil)
        #expect(router.consume() == nil)
    }
}
