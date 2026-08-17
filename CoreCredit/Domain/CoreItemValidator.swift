//
//  CoreItemValidator.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// Every field the core editor can complain about.
///
/// Also used by the OCR layer to say which field a suggestion belongs to, and by the editor to
/// move focus to the first field with a problem.
enum CoreItemField: String, Hashable, Sendable, CaseIterable {
    case partName, partNumber, vendor, bin, expectedCredit, invoiceReference,
         repairOrderReference, receivedDate, dueDate, notes

    var displayName: String {
        switch self {
        case .partName: return "Part name"
        case .partNumber: return "Part number"
        case .vendor: return "Vendor"
        case .bin: return "Bin"
        case .expectedCredit: return "Expected credit"
        case .invoiceReference: return "Invoice"
        case .repairOrderReference: return "Repair order"
        case .receivedDate: return "Received"
        case .dueDate: return "Due date"
        case .notes: return "Notes"
        }
    }
}

/// One problem with a draft, tied to the field that owns it.
struct ValidationIssue: Equatable, Sendable, Identifiable {
    var field: CoreItemField
    var message: String

    /// Field plus message, so two issues on the same field stay distinct in a `ForEach`.
    var id: String { field.rawValue + "|" + message }

    init(field: CoreItemField, message: String) {
        self.field = field
        self.message = message
    }
}

/// Checks a draft before anything is written to the store.
///
/// Messages are written for a technician holding an oily part, not for a developer: they say what
/// to do next, never what rule was violated.
enum CoreItemValidator {

    /// Largest core charge accepted: 99,999,999 cents, i.e. $999,999.99.
    ///
    /// Above this the user almost certainly typed the part number into the amount field.
    static let maximumExpectedCreditCents: Int64 = 99_999_999

    /// Validates a draft, returning issues in field order: part name, expected credit, vendor,
    /// then due date. An empty array means the draft is safe to save.
    ///
    /// At most one issue is reported per field, so the editor can show a single line of red text
    /// under each control.
    static func validate(_ draft: CoreItemDraft, calendar: Calendar) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if draft.trimmedPartName.isEmpty {
            issues.append(ValidationIssue(
                field: .partName,
                message: "Enter a part name or description."
            ))
        }

        if let amount = draft.expectedCredit {
            if amount.cents <= 0 {
                issues.append(ValidationIssue(
                    field: .expectedCredit,
                    message: "The expected credit must be more than zero."
                ))
            } else if amount.cents > maximumExpectedCreditCents {
                issues.append(ValidationIssue(
                    field: .expectedCredit,
                    message: "That amount looks too large."
                ))
            }
        } else {
            issues.append(ValidationIssue(
                field: .expectedCredit,
                message: "Enter the core charge, for example 86.50."
            ))
        }

        if draft.vendorIdentifier == nil {
            issues.append(ValidationIssue(
                field: .vendor,
                message: "Choose the vendor this core goes back to."
            ))
        }

        if draft.usesCustomDueDate, let customDueDate = draft.customDueDate {
            let due = calendar.startOfDay(for: customDueDate)
            let received = calendar.startOfDay(for: draft.receivedDate)
            if due < received {
                issues.append(ValidationIssue(
                    field: .dueDate,
                    message: "The due date can't be before the received date."
                ))
            }
        }

        return issues
    }

    /// The first issue reported for a field, for inline error text under that control.
    static func firstIssue(_ issues: [ValidationIssue], for field: CoreItemField) -> ValidationIssue? {
        issues.first(where: { $0.field == field })
    }
}
