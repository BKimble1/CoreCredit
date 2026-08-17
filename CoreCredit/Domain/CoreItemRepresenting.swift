//
//  CoreItemRepresenting.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// Everything the domain needs to know about a core item.
///
/// `CoreItem` (the SwiftData model) and `CoreItemExportSnapshot` (a plain `Codable` value) both
/// conform, so every calculator, filter, and exporter in this layer can be unit-tested with
/// hand-built fixtures — no `ModelContainer`, no rendering.
///
/// Intentionally **not** `Sendable`: `CoreItem` is a SwiftData `@Model` class bound to a context.
protocol CoreItemRepresenting {

    /// Stable identity. On `CoreItem` this maps to `id`.
    var identifier: UUID { get }

    var partName: String { get }
    var partNumber: String { get }
    var invoiceReference: String { get }
    var repairOrderReference: String { get }

    /// The vendor's credit memo number, filled in when the credit is recorded.
    var creditReference: String { get }

    var notes: String { get }

    /// `nil` when the core is not on a shelf yet, or the bin label is blank.
    var binLabel: String? { get }

    /// `nil` when no vendor is linked, or the vendor's name is blank.
    var vendorName: String? { get }

    var vendorIdentifier: UUID? { get }

    var status: CoreStatus { get }

    /// What the vendor charged for the core, i.e. what is owed back.
    var expectedCredit: Money { get }

    /// What the vendor actually credited. `nil` until a credit is recorded.
    var actualCredit: Money? { get }

    /// When the old core came off the vehicle / arrived in the shop.
    var receivedDate: Date { get }

    /// The vendor's return deadline. `nil` when no window applies.
    var dueDate: Date? { get }

    var returnedDate: Date? { get }
    var creditedDate: Date? { get }
    var createdAt: Date { get }
}
