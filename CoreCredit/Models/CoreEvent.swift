import Foundation
import SwiftData

/// The kind of thing that happened to a core item. Used for the timeline icon and label.
enum CoreEventType: String, CaseIterable, Codable, Sendable, Identifiable {
    case created
    case edited
    case statusChanged
    case photoAdded
    case photoRemoved
    case addedToBatch
    case removedFromBatch
    case returned
    case creditRecorded
    case disputeOpened
    case writtenOff
    case reopened
    case reminderScheduled
    case reminderCancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .created: return "Created"
        case .edited: return "Edited"
        case .statusChanged: return "Status changed"
        case .photoAdded: return "Photo added"
        case .photoRemoved: return "Photo removed"
        case .addedToBatch: return "Added to return batch"
        case .removedFromBatch: return "Removed from return batch"
        case .returned: return "Returned to vendor"
        case .creditRecorded: return "Credit recorded"
        case .disputeOpened: return "Dispute opened"
        case .writtenOff: return "Written off"
        case .reopened: return "Reopened"
        case .reminderScheduled: return "Reminder scheduled"
        case .reminderCancelled: return "Reminder cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .created: return "plus.circle"
        case .edited: return "pencil"
        case .statusChanged: return "arrow.left.arrow.right"
        case .photoAdded: return "camera"
        case .photoRemoved: return "trash"
        case .addedToBatch: return "tray.and.arrow.down"
        case .removedFromBatch: return "tray.and.arrow.up"
        case .returned: return "arrow.uturn.left"
        case .creditRecorded: return "checkmark.seal"
        case .disputeOpened: return "exclamationmark.triangle"
        case .writtenOff: return "xmark.bin"
        case .reopened: return "arrow.counterclockwise"
        case .reminderScheduled: return "bell"
        case .reminderCancelled: return "bell.slash"
        }
    }

    /// Safe decoding for values written by a future version. Unknown -> `.edited`.
    static func decoded(fromRawValue rawValue: String) -> CoreEventType {
        CoreEventType(rawValue: rawValue) ?? .edited
    }
}

/// One entry in a core item's audit trail.
///
/// Append-only. Never mutate or delete an existing event except by cascade with its item —
/// the timeline is what an owner shows a vendor when a credit is disputed, so it must be
/// trustworthy. Only `CoreItemService` and `ReturnBatchService` create these.
@Model
final class CoreEvent {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var typeRawValue: String = CoreEventType.edited.rawValue
    var detail: String = ""
    var amountCents: Int64?
    var reference: String = ""
    var fromStatusRawValue: String?
    var toStatusRawValue: String?

    var coreItem: CoreItem?

    init(type: CoreEventType,
         detail: String,
         timestamp: Date,
         amount: Money? = nil,
         reference: String = "",
         from: CoreStatus? = nil,
         to: CoreStatus? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.typeRawValue = type.rawValue
        self.detail = detail
        self.amountCents = amount?.cents
        self.reference = reference
        self.fromStatusRawValue = from?.rawValue
        self.toStatusRawValue = to?.rawValue
        self.coreItem = nil
    }

    /// Typed view over `typeRawValue`. Unknown raw values decode to `.edited`.
    var type: CoreEventType {
        CoreEventType.decoded(fromRawValue: typeRawValue)
    }

    /// The money involved in this event, when there was any.
    var amount: Money? {
        guard let cents = amountCents else { return nil }
        return Money(cents: cents)
    }

    /// The status the item left, when this event was a status change.
    var fromStatus: CoreStatus? {
        guard let raw = fromStatusRawValue else { return nil }
        return CoreStatus.decoded(fromRawValue: raw)
    }

    /// The status the item entered, when this event was a status change.
    var toStatus: CoreStatus? {
        guard let raw = toStatusRawValue else { return nil }
        return CoreStatus.decoded(fromRawValue: raw)
    }

    /// Spoken timeline row, e.g. "Credit recorded. Vendor issued 86.50. 12 Mar 2026 at 9:15 AM".
    var accessibilityDescription: String {
        var parts: [String] = [type.displayName]

        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetail.isEmpty { parts.append(trimmedDetail) }

        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReference.isEmpty { parts.append("Reference " + trimmedReference) }

        parts.append(timestamp.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ". ")
    }
}
