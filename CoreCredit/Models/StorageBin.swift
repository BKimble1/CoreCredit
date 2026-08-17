import Foundation
import SwiftData

/// A physical shelf, cage, or tote where the old core physically sits while it waits to go back.
///
/// The relationship uses `.nullify`: retiring a bin must never delete the cores stored in it.
@Model
final class StorageBin {
    var id: UUID = UUID()
    var label: String = ""
    var locationNote: String = ""
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \CoreItem.bin)
    var coreItems: [CoreItem]? = []

    init(label: String, locationNote: String = "", now: Date = Date()) {
        self.id = UUID()
        self.label = label
        self.locationNote = locationNote
        self.isActive = true
        self.createdAt = now
        self.updatedAt = now
        self.coreItems = []
    }

    /// The bin label, or a neutral placeholder when it is blank.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unlabelled bin" : trimmed
    }

    /// Non-optional view of the to-many relationship so call sites never unwrap.
    var items: [CoreItem] {
        coreItems ?? []
    }

    /// Stamps `updatedAt`.
    func touch(_ now: Date) {
        updatedAt = now
    }
}
