//
//  CoreItemDraft.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// The editable, un-persisted form of a core item.
///
/// The editor screen binds to a draft rather than to a `CoreItem`, so an abandoned edit leaves the
/// store untouched and validation can run on plain text before anything is written. Amounts stay
/// as the user's raw text until they are parsed, so a half-typed "86." is never silently rounded.
struct CoreItemDraft: Equatable, Sendable {

    /// Set when editing an existing item; `nil` when creating a new one.
    var existingID: UUID?

    var partName: String
    var partNumber: String
    var vendorIdentifier: UUID?
    var binIdentifier: UUID?

    /// Raw text from the currency field, e.g. `"86.50"`.
    var expectedCreditText: String

    var invoiceReference: String
    var repairOrderReference: String
    var receivedDate: Date

    /// True when the user overrode the vendor's return window with a hand-picked date.
    var usesCustomDueDate: Bool

    var customDueDate: Date?
    var notes: String

    init(existingID: UUID? = nil,
         partName: String = "",
         partNumber: String = "",
         vendorIdentifier: UUID? = nil,
         binIdentifier: UUID? = nil,
         expectedCreditText: String = "",
         invoiceReference: String = "",
         repairOrderReference: String = "",
         receivedDate: Date = Date(),
         usesCustomDueDate: Bool = false,
         customDueDate: Date? = nil,
         notes: String = "") {
        self.existingID = existingID
        self.partName = partName
        self.partNumber = partNumber
        self.vendorIdentifier = vendorIdentifier
        self.binIdentifier = binIdentifier
        self.expectedCreditText = expectedCreditText
        self.invoiceReference = invoiceReference
        self.repairOrderReference = repairOrderReference
        self.receivedDate = receivedDate
        self.usesCustomDueDate = usesCustomDueDate
        self.customDueDate = customDueDate
        self.notes = notes
    }

    /// The parsed amount, or `nil` while the text is empty or unparseable.
    ///
    /// Uses the current locale, because this text came from the user's own keyboard.
    var expectedCredit: Money? {
        Money.parse(expectedCreditText)
    }

    var trimmedPartName: String {
        partName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The due date this draft would produce.
    ///
    /// A custom date wins when `usesCustomDueDate` is set (normalised to the start of that day);
    /// otherwise the vendor's return window is applied to `receivedDate`. If `usesCustomDueDate`
    /// is set but no date was picked, the vendor window is used, so the item is never left without
    /// a deadline.
    func resolvedDueDate(vendorWindowDays: Int, calendar: Calendar) -> Date {
        if usesCustomDueDate, let customDueDate = customDueDate {
            return calendar.startOfDay(for: customDueDate)
        }
        return DueDateCalculator.dueDate(
            receivedDate: receivedDate,
            windowDays: vendorWindowDays,
            calendar: calendar
        )
    }
}
