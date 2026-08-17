//
//  CreditReconciler.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// What the user typed on the "Record credit" sheet.
struct CreditReconciliation: Equatable, Sendable {

    /// The date printed on the vendor's credit memo.
    var creditDate: Date

    /// The credit memo number.
    var reference: String

    /// The amount the vendor actually credited.
    var amount: Money

    init(creditDate: Date, reference: String, amount: Money) {
        self.creditDate = creditDate
        self.reference = reference
        self.amount = amount
    }
}

/// How a recorded credit compares to the core charge that was expected.
enum CreditOutcome: Equatable, Sendable {

    /// The vendor credited exactly the expected amount.
    case exact

    /// The vendor credited less than expected. `difference` is always positive.
    case short(difference: Money)

    /// The vendor credited more than expected. `difference` is always positive.
    case over(difference: Money)

    /// True for anything the user should be told about, i.e. not `.exact`.
    var isDiscrepancy: Bool {
        switch self {
        case .exact: return false
        case .short, .over: return true
        }
    }

    /// The size of the gap, always positive. `.zero` for `.exact`.
    var difference: Money {
        switch self {
        case .exact:
            return .zero
        case .short(let difference):
            return difference
        case .over(let difference):
            return difference
        }
    }

    /// Sentence fragment for the UI.
    ///
    /// The `.short` and `.over` cases end with a trailing space on purpose: the caller appends the
    /// formatted money, e.g. `outcome.summaryText + difference.formatted(currencyCode: code)`.
    var summaryText: String {
        switch self {
        case .exact: return "Credited in full"
        case .short: return "Short by "
        case .over: return "Over by "
        }
    }
}

/// Compares an expected core charge against the credit that actually arrived.
enum CreditReconciler {

    /// Classifies the credit. Equal amounts are `.exact`; anything else reports a positive gap.
    static func outcome(expected: Money, actual: Money) -> CreditOutcome {
        if actual == expected { return .exact }
        if actual < expected { return .short(difference: expected - actual) }
        return .over(difference: actual - expected)
    }

    /// Where the item lands after the credit is recorded.
    ///
    /// A short credit opens a dispute; an exact or generous credit closes the item as credited.
    /// An over-credit is deliberately *not* a dispute — the shop came out ahead.
    static func resultingStatus(for outcome: CreditOutcome) -> CoreStatus {
        switch outcome {
        case .exact, .over:
            return .credited
        case .short:
            return .disputed
        }
    }
}
