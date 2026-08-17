//
//  DeepLink.swift
//  CoreCredit
//
//  The vocabulary of everything outside the app that can ask it to go somewhere: a bin-tag QR
//  code, the Quick Scan widget, a Shortcut, the Action Button.
//

import Foundation

/// A place in the app that something outside it is allowed to ask for.
///
/// # Why this type is deliberately dull
///
/// It is pure `Foundation` — no SwiftUI, no SwiftData, no `AppEnvironment`. Parsing a URL is the
/// part of deep linking that is worth testing exhaustively (foreign schemes, junk hosts, half a
/// UUID), and it is only cheap to test while nothing here needs a view hierarchy or a store.
/// Deciding *what to show* belongs to the shell; deciding *what was asked for* belongs here.
///
/// # There is one item-URL parser in this app
///
/// `case item` delegates to `BinTagPayload.itemID(fromEncodedString:)`, which already had to parse
/// `corecredit://item/<uuid>` for the printed shelf label. A second copy of that rule would be a
/// second place for it to drift, and a bin tag taped to a shelf in 2026 has to keep working.
enum DeepLink: Equatable, Sendable {

    /// Open a brand-new core charge with the scanner already in front of it.
    case scan

    /// Open one existing core's detail screen.
    case item(UUID)

    /// URL host that means `.scan`. Mirrors `QuickScanLinks.scanURLString` in the widget target,
    /// which cannot import this module and therefore spells the same URL out by hand.
    static let scanHost = "scan"

    /// Parses `corecredit://scan` and `corecredit://item/<uuid>`.
    ///
    /// Accepts:
    /// - the app's own scheme, compared case-insensitively (`CoreCredit://SCAN` is the same link);
    /// - `scan` and `item` as hosts, likewise case-insensitively;
    /// - a trailing slash on either form;
    /// - a query string on `scan`, which is ignored — a widget is free to tag where a tap came
    ///   from without that changing what the app does.
    ///
    /// Returns `nil` for a foreign scheme, a missing or unknown host, extra path components after
    /// `scan`, a missing identifier, or anything `UUID(uuidString:)` will not accept. A scanner
    /// hands over vendor barcodes and shipping labels all day; `nil` is the ordinary answer and
    /// the caller is expected to shrug it off.
    static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard let scheme = components.scheme,
              scheme.caseInsensitiveCompare(AppConfiguration.urlScheme) == .orderedSame else {
            return nil
        }
        guard let host = components.host, !host.isEmpty else { return nil }

        if host.caseInsensitiveCompare(DeepLink.scanHost) == .orderedSame {
            // `corecredit://scan` and `corecredit://scan/` only. A path under `scan` means a link
            // this build does not understand, and guessing at it would be worse than declining.
            let remainder = components.path.trimmingCharacters(in: DeepLink.slashes)
            guard remainder.isEmpty else { return nil }
            return .scan
        }

        // Item links — including the host check and the UUID — belong to the bin tag's own parser.
        guard let identifier = BinTagPayload.itemID(fromEncodedString: url.absoluteString) else {
            return nil
        }
        return .item(identifier)
    }

    /// The separators trimmed from a path before it is inspected, so a trailing slash is tolerated.
    private static let slashes = CharacterSet(charactersIn: "/")
}
