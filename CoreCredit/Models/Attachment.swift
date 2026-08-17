import Foundation
import SwiftData

/// What a photograph is evidence of. Drives the icon and the VoiceOver description.
enum AttachmentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case part
    case box
    case invoice
    case receipt
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .part: return "Part"
        case .box: return "Box or label"
        case .invoice: return "Invoice"
        case .receipt: return "Return receipt"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .part: return "shippingbox"
        case .box: return "cube.box"
        case .invoice: return "doc.text"
        case .receipt: return "doc.plaintext"
        case .other: return "photo"
        }
    }

    /// Safe decoding for values written by a future version. Unknown -> `.other`.
    static func decoded(fromRawValue rawValue: String) -> AttachmentKind {
        AttachmentKind(rawValue: rawValue) ?? .other
    }
}

/// A photograph attached either to a core item (part / box / invoice) or to a return batch
/// (the signed return receipt). Exactly one of the two owners is set in practice.
///
/// Image bytes live in `.externalStorage` so the SQLite file stays small and the store keeps
/// loading quickly even with hundreds of photos.
@Model
final class Attachment {
    var id: UUID = UUID()
    var kindRawValue: String = AttachmentKind.other.rawValue
    @Attribute(.externalStorage) var imageData: Data = Data()
    var caption: String = ""
    var capturedAt: Date = Date()
    var byteCount: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0

    var coreItem: CoreItem?
    var returnBatch: ReturnBatch?

    init(kind: AttachmentKind,
         imageData: Data,
         pixelWidth: Int,
         pixelHeight: Int,
         caption: String = "",
         capturedAt: Date = Date()) {
        self.id = UUID()
        self.kindRawValue = kind.rawValue
        self.imageData = imageData
        self.caption = caption
        self.capturedAt = capturedAt
        self.byteCount = imageData.count
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.coreItem = nil
        self.returnBatch = nil
    }

    /// Typed view over `kindRawValue`. Unknown raw values decode to `.other`.
    var kind: AttachmentKind {
        get { AttachmentKind.decoded(fromRawValue: kindRawValue) }
        set { kindRawValue = newValue.rawValue }
    }

    /// Spoken description, e.g. "Invoice photo captured 12 March 2026. Front of the invoice."
    var accessibilityLabel: String {
        let dateText = capturedAt.formatted(date: .long, time: .omitted)
        var text = kind.displayName + " photo captured " + dateText
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            text += ". " + trimmedCaption
        }
        return text
    }
}
