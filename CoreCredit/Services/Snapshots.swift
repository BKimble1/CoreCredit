//
//  Snapshots.swift
//  CoreCredit
//
//  Plain `Codable` value types that mirror the SwiftData models.
//
//  Every exporter in this layer works against these, never against `@Model` classes, so a CSV,
//  a JSON backup, and a dispute packet can each be unit-tested from hand-built fixtures with no
//  `ModelContainer` in sight. Mapping from the models lives in `SnapshotBuilder`.
//
//  Money is carried as `Money`, which is `Codable` over `Int64` cents — no export path anywhere in
//  the app ever touches `Double` or `Float`.
//

import Foundation

// MARK: - Core item

/// A frozen copy of one core item, complete enough to render a dispute packet from.
///
/// Conforms to `CoreItemRepresenting`, so `RiskCalculator`, `CoreItemQuery`, and `BinTagPayload`
/// all accept a snapshot exactly as they accept a live `CoreItem`.
struct CoreItemExportSnapshot: Codable, Equatable, Sendable, Identifiable, CoreItemRepresenting {

    var identifier: UUID
    var partName: String
    var partNumber: String
    var invoiceReference: String
    var repairOrderReference: String
    var creditReference: String
    var notes: String
    var binLabel: String?
    var vendorName: String?
    var vendorIdentifier: UUID?
    var status: CoreStatus
    var expectedCredit: Money
    var actualCredit: Money?
    var receivedDate: Date
    var dueDate: Date?
    var returnedDate: Date?
    var creditedDate: Date?
    var createdAt: Date
    var updatedAt: Date

    /// The vendor-facing reference of the batch this core went back on, when it was batched.
    var returnBatchReference: String?

    /// How the batch physically left the shop, when it was batched.
    var returnMethod: ReturnMethod?

    /// The item's audit trail, oldest first.
    var events: [CoreEventSnapshot]

    var id: UUID { identifier }

    /// Memberwise initialiser with defaults, so a test fixture only has to state what it cares
    /// about. Parameter order matches the property order above.
    init(identifier: UUID = UUID(),
         partName: String = "",
         partNumber: String = "",
         invoiceReference: String = "",
         repairOrderReference: String = "",
         creditReference: String = "",
         notes: String = "",
         binLabel: String? = nil,
         vendorName: String? = nil,
         vendorIdentifier: UUID? = nil,
         status: CoreStatus = .awaitingCore,
         expectedCredit: Money = .zero,
         actualCredit: Money? = nil,
         receivedDate: Date = Date(),
         dueDate: Date? = nil,
         returnedDate: Date? = nil,
         creditedDate: Date? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         returnBatchReference: String? = nil,
         returnMethod: ReturnMethod? = nil,
         events: [CoreEventSnapshot] = []) {
        self.identifier = identifier
        self.partName = partName
        self.partNumber = partNumber
        self.invoiceReference = invoiceReference
        self.repairOrderReference = repairOrderReference
        self.creditReference = creditReference
        self.notes = notes
        self.binLabel = binLabel
        self.vendorName = vendorName
        self.vendorIdentifier = vendorIdentifier
        self.status = status
        self.expectedCredit = expectedCredit
        self.actualCredit = actualCredit
        self.receivedDate = receivedDate
        self.dueDate = dueDate
        self.returnedDate = returnedDate
        self.creditedDate = creditedDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.returnBatchReference = returnBatchReference
        self.returnMethod = returnMethod
        self.events = events
    }

    /// The part name, or a neutral placeholder — mirrors `CoreItem.displayTitle` so the PDF and
    /// the on-screen detail view never disagree.
    var displayTitle: String {
        let trimmed = partName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled core" : trimmed
    }
}

// MARK: - Event

/// One frozen entry from a core item's timeline.
struct CoreEventSnapshot: Codable, Equatable, Sendable, Identifiable {

    var id: UUID
    var timestamp: Date
    var type: CoreEventType
    var detail: String
    var amount: Money?
    var reference: String
    var fromStatus: CoreStatus?
    var toStatus: CoreStatus?

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         type: CoreEventType = .edited,
         detail: String = "",
         amount: Money? = nil,
         reference: String = "",
         fromStatus: CoreStatus? = nil,
         toStatus: CoreStatus? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.detail = detail
        self.amount = amount
        self.reference = reference
        self.fromStatus = fromStatus
        self.toStatus = toStatus
    }
}

// MARK: - Shop

/// The shop's letterhead: what appears at the top of every dispute packet.
struct ShopProfileSnapshot: Codable, Equatable, Sendable {

    var name: String
    var phone: String
    var email: String

    /// Already-split postal address lines. Empty components were dropped upstream, so this array
    /// never contains a blank string.
    var addressLines: [String]

    var currencyCode: String

    init(name: String = "",
         phone: String = "",
         email: String = "",
         addressLines: [String] = [],
         currencyCode: String = AppConfiguration.defaultCurrencyCode) {
        self.name = name
        self.phone = phone
        self.email = email
        self.addressLines = addressLines
        self.currencyCode = currencyCode
    }

    /// Used by previews and by any export taken before the owner has filled in the shop profile.
    static let placeholder = ShopProfileSnapshot(
        name: "Your shop",
        phone: "",
        email: "",
        addressLines: [],
        currencyCode: AppConfiguration.defaultCurrencyCode
    )

    /// The shop name, or the placeholder name when it is blank.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your shop" : trimmed
    }

    /// `"phone • email"`, skipping whichever half is missing.
    var contactSummary: String {
        var parts: [String] = []
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPhone.isEmpty { parts.append(trimmedPhone) }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmail.isEmpty { parts.append(trimmedEmail) }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Supporting records

/// A frozen vendor record.
struct VendorSnapshot: Codable, Equatable, Sendable, Identifiable {

    var id: UUID
    var name: String
    var contactName: String
    var phone: String
    var email: String
    var accountNumber: String
    var defaultReturnWindowDays: Int
    var notes: String
    var isActive: Bool

    init(id: UUID = UUID(),
         name: String = "",
         contactName: String = "",
         phone: String = "",
         email: String = "",
         accountNumber: String = "",
         defaultReturnWindowDays: Int = AppConfiguration.defaultVendorReturnWindowDays,
         notes: String = "",
         isActive: Bool = true) {
        self.id = id
        self.name = name
        self.contactName = contactName
        self.phone = phone
        self.email = email
        self.accountNumber = accountNumber
        self.defaultReturnWindowDays = defaultReturnWindowDays
        self.notes = notes
        self.isActive = isActive
    }
}

/// A frozen storage-bin record.
struct StorageBinSnapshot: Codable, Equatable, Sendable, Identifiable {

    var id: UUID
    var label: String
    var locationNote: String
    var isActive: Bool

    init(id: UUID = UUID(),
         label: String = "",
         locationNote: String = "",
         isActive: Bool = true) {
        self.id = id
        self.label = label
        self.locationNote = locationNote
        self.isActive = isActive
    }
}

/// A frozen return batch. Membership is stored as item identifiers so the backup file has no
/// duplicated item bodies and no circular references.
struct ReturnBatchSnapshot: Codable, Equatable, Sendable, Identifiable {

    var id: UUID
    var vendorName: String
    var vendorIdentifier: UUID?
    var returnDate: Date
    var method: ReturnMethod
    var reference: String
    var notes: String
    var itemIdentifiers: [UUID]

    init(id: UUID = UUID(),
         vendorName: String = "",
         vendorIdentifier: UUID? = nil,
         returnDate: Date = Date(),
         method: ReturnMethod = .counterDropOff,
         reference: String = "",
         notes: String = "",
         itemIdentifiers: [UUID] = []) {
        self.id = id
        self.vendorName = vendorName
        self.vendorIdentifier = vendorIdentifier
        self.returnDate = returnDate
        self.method = method
        self.reference = reference
        self.notes = notes
        self.itemIdentifiers = itemIdentifiers
    }
}

// MARK: - Backup

/// The complete, portable CoreCredit backup.
///
/// # File shape
///
/// A single JSON object, written by `JSONBackupExporter.encode(_:)` with ISO-8601 dates, sorted
/// keys, and pretty printing, so two backups of the same ledger diff cleanly:
///
/// ```json
/// {
///   "appVersion" : "1.0",
///   "batches" : [ { "id" : "…", "itemIdentifiers" : [ "…" ], "method" : "counterDropOff", … } ],
///   "bins" : [ { "id" : "…", "isActive" : true, "label" : "A3", … } ],
///   "exportedAt" : "2026-08-16T14:22:05Z",
///   "formatVersion" : 1,
///   "items" : [ {
///       "createdAt" : "2026-03-12T09:00:00Z",
///       "events" : [ { "detail" : "…", "type" : "created", … } ],
///       "expectedCredit" : { "cents" : 8650 },
///       "identifier" : "…",
///       "partName" : "Alternator",
///       "status" : "readyToReturn"
///   } ],
///   "shop" : { "addressLines" : [ "…" ], "currencyCode" : "USD", "name" : "…" },
///   "vendors" : [ { "id" : "…", "name" : "NAPA", … } ]
/// }
/// ```
///
/// # Money
///
/// Every amount is an object of the form `{"cents": 8650}` — an exact `Int64`. There is no
/// floating-point number anywhere in the file, so `$86.50` survives any number of round trips.
///
/// # Versioning
///
/// `formatVersion` is checked on the way in. A file written by a newer build than the one reading
/// it is refused with a clear message rather than being partially imported; a file written by an
/// older build is accepted, because every field added since gets its default.
struct BackupPayload: Codable, Equatable, Sendable {

    /// The shape of this file. Bump only when the layout changes incompatibly.
    var formatVersion: Int

    /// The marketing version of the app that produced the file, for support triage.
    var appVersion: String

    var exportedAt: Date
    var shop: ShopProfileSnapshot
    var vendors: [VendorSnapshot]
    var bins: [StorageBinSnapshot]
    var items: [CoreItemExportSnapshot]
    var batches: [ReturnBatchSnapshot]

    /// The newest format this build can read and write.
    static let currentFormatVersion = 1

    init(formatVersion: Int = BackupPayload.currentFormatVersion,
         appVersion: String = AppConfiguration.appVersion,
         exportedAt: Date = Date(),
         shop: ShopProfileSnapshot = .placeholder,
         vendors: [VendorSnapshot] = [],
         bins: [StorageBinSnapshot] = [],
         items: [CoreItemExportSnapshot] = [],
         batches: [ReturnBatchSnapshot] = []) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.shop = shop
        self.vendors = vendors
        self.bins = bins
        self.items = items
        self.batches = batches
    }
}
