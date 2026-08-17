import Foundation
import SwiftData

/// A parts supplier that cores are returned to. The vendor owns the default return window
/// used to compute each core item's due date.
///
/// Both relationships use `.nullify`: deleting a vendor must never destroy the ledger history,
/// it only detaches the vendor from its items and batches.
@Model
final class Vendor {
    var id: UUID = UUID()
    var name: String = ""
    var contactName: String = ""
    var phone: String = ""
    var email: String = ""
    var accountNumber: String = ""
    var defaultReturnWindowDays: Int = AppConfiguration.defaultVendorReturnWindowDays
    var notes: String = ""
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \CoreItem.vendor)
    var coreItems: [CoreItem]? = []

    @Relationship(deleteRule: .nullify, inverse: \ReturnBatch.vendor)
    var returnBatches: [ReturnBatch]? = []

    init(name: String,
         defaultReturnWindowDays: Int = AppConfiguration.defaultVendorReturnWindowDays,
         now: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.contactName = ""
        self.phone = ""
        self.email = ""
        self.accountNumber = ""
        self.defaultReturnWindowDays = defaultReturnWindowDays
        self.notes = ""
        self.isActive = true
        self.createdAt = now
        self.updatedAt = now
        self.coreItems = []
        self.returnBatches = []
    }

    /// The vendor name, or a neutral placeholder when it is blank.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed vendor" : trimmed
    }

    /// Non-optional view of the to-many relationship so call sites never unwrap.
    var items: [CoreItem] {
        coreItems ?? []
    }

    /// Non-optional view of the to-many relationship so call sites never unwrap.
    var batches: [ReturnBatch] {
        returnBatches ?? []
    }

    /// Stamps `updatedAt`.
    func touch(_ now: Date) {
        updatedAt = now
    }
}
