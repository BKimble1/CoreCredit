//
//  AgingBucket.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// How long an unresolved core has been sitting, grouped the way a shop owner thinks about it.
///
/// The boundaries are inclusive and exact: 7 days is still `.zeroToSeven`, 8 days is
/// `.eightToThirty`, 30 days is `.eightToThirty`, 31 days is `.thirtyOnePlus`.
enum AgingBucket: String, CaseIterable, Identifiable, Sendable, Hashable {
    case zeroToSeven
    case eightToThirty
    case thirtyOnePlus

    var id: String { rawValue }

    /// Full label, using an en dash for the range.
    var displayName: String {
        switch self {
        case .zeroToSeven: return "0–7 days"
        case .eightToThirty: return "8–30 days"
        case .thirtyOnePlus: return "31+ days"
        }
    }

    /// Compact label for chart axes and segmented controls.
    var shortName: String {
        switch self {
        case .zeroToSeven: return "0–7"
        case .eightToThirty: return "8–30"
        case .thirtyOnePlus: return "31+"
        }
    }

    /// First day that falls in this bucket.
    var lowerBoundDays: Int {
        switch self {
        case .zeroToSeven: return 0
        case .eightToThirty: return 8
        case .thirtyOnePlus: return 31
        }
    }

    /// Last day that falls in this bucket; `nil` for the open-ended oldest bucket.
    var upperBoundDays: Int? {
        switch self {
        case .zeroToSeven: return 7
        case .eightToThirty: return 30
        case .thirtyOnePlus: return nil
        }
    }

    /// Bucket for a whole-day age.
    ///
    /// A negative age (a received date in the future, e.g. a mistyped entry) clamps to
    /// `.zeroToSeven` rather than being treated as an error.
    static func bucket(forDays days: Int) -> AgingBucket {
        if days <= 7 { return .zeroToSeven }
        if days <= 30 { return .eightToThirty }
        return .thirtyOnePlus
    }
}
