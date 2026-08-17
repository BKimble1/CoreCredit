//
//  DomainError.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// Every error the domain and the mutation services can produce.
///
/// `errorDescription` is written in plain shop-floor English — it goes straight into an alert with
/// no rewriting — and `recoverySuggestion` always tells the user what to do next.
enum DomainError: LocalizedError, Equatable {

    /// A status change that the transition table does not allow.
    case invalidTransition(from: CoreStatus, to: CoreStatus)

    /// A draft failed validation; the payload is the full list of issues.
    case validationFailed([ValidationIssue])

    /// A return batch was given items belonging to more than one vendor.
    case mixedVendorBatch

    /// A return batch was created with no items.
    case emptyBatch

    /// A return batch was created without a vendor.
    case missingVendor

    /// The item is already on another open return batch. Payload is the item's display title.
    case itemAlreadyInBatch(String)

    /// The store refused a write. Payload is the underlying description, for diagnostics.
    case persistenceFailed(String)

    /// The record was deleted or never existed.
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "You can't move an item from \(from.displayName) to \(to.displayName)."

        case .validationFailed(let issues):
            if issues.isEmpty {
                return "Some details are still missing."
            }
            return issues.map { $0.message }.joined(separator: " ")

        case .mixedVendorBatch:
            return "A return can only hold cores going back to one vendor."

        case .emptyBatch:
            return "Add at least one core before you create a return."

        case .missingVendor:
            return "Choose the vendor this return is going back to."

        case .itemAlreadyInBatch(let title):
            return "\(title) is already on another return."

        case .persistenceFailed(let detail):
            return "That change couldn't be saved. \(detail)"

        case .notFound:
            return "That record is no longer in your ledger."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidTransition:
            return "Pick one of the statuses offered in the menu instead."

        case .validationFailed:
            return "Fix the highlighted fields and try again."

        case .mixedVendorBatch:
            return "Create a separate return for each vendor."

        case .emptyBatch:
            return "Select the cores you are sending back, then try again."

        case .missingVendor:
            return "Pick a vendor, or add one in Settings first."

        case .itemAlreadyInBatch:
            return "Remove it from the other return before adding it here."

        case .persistenceFailed:
            return "Try again. If it keeps happening, restart the app and export a backup."

        case .notFound:
            return "Go back to the list and pull down to refresh."
        }
    }
}
