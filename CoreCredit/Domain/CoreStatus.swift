//
//  CoreStatus.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// Where a single core sits in the return-and-credit cycle.
///
/// The raw values are persisted (SwiftData stores `statusRawValue`) and exported, so they must
/// never be renamed. Decoding is deliberately lenient: a store written by a newer build that adds
/// a case still opens on an older build, falling back to `.awaitingCore`.
enum CoreStatus: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case awaitingCore
    case readyToReturn
    case returnedAwaitingCredit
    case credited
    case disputed
    case writtenOff

    var id: String { rawValue }

    /// Full label used in pickers, detail headers, and error sentences.
    var displayName: String {
        switch self {
        case .awaitingCore: return "Awaiting old core"
        case .readyToReturn: return "Ready to return"
        case .returnedAwaitingCredit: return "Returned — awaiting credit"
        case .credited: return "Credited"
        case .disputed: return "Disputed"
        case .writtenOff: return "Written off"
        }
    }

    /// Compact label for badges and list rows where horizontal space is tight.
    var shortName: String {
        switch self {
        case .awaitingCore: return "Awaiting"
        case .readyToReturn: return "Ready"
        case .returnedAwaitingCredit: return "Returned"
        case .credited: return "Credited"
        case .disputed: return "Disputed"
        case .writtenOff: return "Written off"
        }
    }

    /// SF Symbol name. Fixed by the contract so icons stay consistent across every screen.
    var symbolName: String {
        switch self {
        case .awaitingCore: return "shippingbox"
        case .readyToReturn: return "arrow.uturn.left.circle"
        case .returnedAwaitingCredit: return "clock.arrow.circlepath"
        case .credited: return "checkmark.seal"
        case .disputed: return "exclamationmark.triangle"
        case .writtenOff: return "xmark.bin"
        }
    }

    /// True while the shop still has money or an obligation outstanding.
    ///
    /// `disputed` counts as unresolved: the vendor short-paid and somebody still has to chase it.
    var isUnresolved: Bool {
        switch self {
        case .awaitingCore, .readyToReturn, .returnedAwaitingCredit, .disputed:
            return true
        case .credited, .writtenOff:
            return false
        }
    }

    /// The exact inverse of `isUnresolved`; kept as its own name so call sites read naturally.
    var isClosed: Bool { !isUnresolved }

    /// Order used for status pickers, dashboard cards, and transition menus.
    var sortIndex: Int {
        switch self {
        case .awaitingCore: return 0
        case .readyToReturn: return 1
        case .returnedAwaitingCredit: return 2
        case .credited: return 3
        case .disputed: return 4
        case .writtenOff: return 5
        }
    }

    /// Extra spoken context for VoiceOver, read after the status name.
    var accessibilityHint: String {
        switch self {
        case .awaitingCore:
            return "The old core has not come off the vehicle yet."
        case .readyToReturn:
            return "The old core is on the shelf, ready to go back to the vendor."
        case .returnedAwaitingCredit:
            return "Returned to vendor, credit not yet received."
        case .credited:
            return "The vendor credit was received and matched to the core charge."
        case .disputed:
            return "The credit was short or never arrived. Follow up with the vendor."
        case .writtenOff:
            return "Closed with no credit expected."
        }
    }

    /// Statuses that still represent outstanding money, in display order.
    static var unresolvedCases: [CoreStatus] {
        allCases.filter { $0.isUnresolved }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Statuses that represent a finished core, in display order.
    static var closedCases: [CoreStatus] {
        allCases.filter { $0.isClosed }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Forward-compatible mapping from a persisted raw value. Unknown values become `.awaitingCore`
    /// so a store written by a future version never fails to open.
    static func decoded(fromRawValue rawValue: String) -> CoreStatus {
        CoreStatus(rawValue: rawValue) ?? .awaitingCore
    }

    /// Lenient `Decodable` conformance — a JSON backup carrying an unknown status decodes to
    /// `.awaitingCore` instead of throwing and losing the whole file.
    ///
    /// `encode(to:)` is left to the compiler, so encoding still round-trips the raw string.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CoreStatus.decoded(fromRawValue: rawValue)
    }
}
