import Foundation
import SwiftData

/// Version 1.0.0 of the CoreCredit persistent schema — the shape shipped in the 1.0 App Store build.
///
/// Every model type the app persists must be listed in `models`; anything missing here simply will
/// not exist in the store, which manifests at runtime as a fetch that always returns zero rows.
enum CoreCreditSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ShopProfile.self, Vendor.self, StorageBin.self, CoreItem.self,
         ReturnBatch.self, Attachment.self, CoreEvent.self]
    }
}

/// Version 2.0.0 of the CoreCredit persistent schema.
///
/// The only difference from V1 is on `CoreItem`, which gained two **optional** attributes:
/// `scannedBarcodeValue` and `scannedBarcodeSymbology`. They hold the raw payload a scanner
/// reported, kept deliberately apart from the confirmed `partNumber`.
///
/// Nothing was renamed, retyped, made non-optional, or removed, and no model type was added or
/// dropped — so the same seven types are listed here as in V1.
enum CoreCreditSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ShopProfile.self, Vendor.self, StorageBin.self, CoreItem.self,
         ReturnBatch.self, Attachment.self, CoreEvent.self]
    }
}

/// Version 3.0.0 of the CoreCredit persistent schema.
///
/// The only difference from V2 is on `ShopProfile`, which gained five attributes for the expanded
/// reminder system — the due-soon lead list, the awaiting-credit delay, the dispute follow-up
/// delay, the weekly-digest switch, and the "show item details in notifications" switch.
///
/// **Every one of them has a default value in its declaration**, which is what keeps the V2 -> V3
/// step lightweight: SwiftData fills each existing row in from the default and rewrites nothing.
/// Nothing was renamed, retyped, made non-optional, or removed, and no model type was added or
/// dropped — so the same seven types are listed here as in V2.
enum CoreCreditSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ShopProfile.self, Vendor.self, StorageBin.self, CoreItem.self,
         ReturnBatch.self, Attachment.self, CoreEvent.self]
    }
}

/// Migration plan for the CoreCredit store.
///
/// ## V1 -> V2
///
/// V1 -> V2 **adds only optional attributes** (`CoreItem.scannedBarcodeValue` and
/// `CoreItem.scannedBarcodeSymbology`). An added optional attribute is exactly the kind of change
/// SwiftData can infer on its own, so a `.lightweight` stage is sufficient: **no data is rewritten**
/// and no row is touched. Every existing store — including the ones already on TestFlight devices —
/// opens in place, with the two new attributes reading back as `nil` for every previously saved row.
///
/// ## V2 -> V3
///
/// V2 -> V3 adds five `ShopProfile` attributes, **each with a default value in its declaration**
/// (`reminderDueSoonLeadDaysRaw`, `awaitingCreditReminderDelayDays`,
/// `disputeFollowUpReminderDelayDays`, `weeklySummaryEnabled`, `showsDetailInNotifications`). An
/// added attribute that has a default is inferrable, so this stage is `.lightweight` too: a store
/// written by the 1.0 or the scanning build — including the ones already on TestFlight devices —
/// opens in place, and its single profile row reads back with the new reminder defaults.
///
/// ## Adding a V4
///
/// 1. Copy the current model definitions into a new `enum CoreCreditSchemaV4: VersionedSchema`
///    with `versionIdentifier` `Schema.Version(4, 0, 0)`, then make the change (new property,
///    renamed property, new model type).
/// 2. Append it to `schemas` **in ascending version order**: `[CoreCreditSchemaV1.self,
///    CoreCreditSchemaV2.self, CoreCreditSchemaV3.self, CoreCreditSchemaV4.self]`. SwiftData walks
///    this list in order to find a migration path.
/// 3. Add the matching stage to `stages`, again in ascending order:
///
///    ```swift
///    static let migrateV3toV4 = MigrationStage.lightweight(
///        fromVersion: CoreCreditSchemaV3.self,
///        toVersion: CoreCreditSchemaV4.self
///    )
///    ```
///
/// A **lightweight** stage covers the changes SwiftData can infer on its own: adding a property
/// that has a default value, adding an optional property, adding a whole new model type, or
/// deleting a property. Every stored property in this schema either has a default in its
/// declaration or is optional, specifically so that each step can stay lightweight.
///
/// Anything that needs data to be rewritten — splitting one property into two, changing a
/// property's type, backfilling a value that has no sensible default — requires
/// `MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)` instead, where the
/// `didMigrate` closure fetches the migrated objects and fixes them up.
enum CoreCreditMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CoreCreditSchemaV1.self, CoreCreditSchemaV2.self, CoreCreditSchemaV3.self]
    }

    /// Additive only — optional attributes, or attributes carrying a default — so nothing here
    /// rewrites data and no stage can fail on a store that is already in the field.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: CoreCreditSchemaV1.self, toVersion: CoreCreditSchemaV2.self),
            .lightweight(fromVersion: CoreCreditSchemaV2.self, toVersion: CoreCreditSchemaV3.self)
        ]
    }
}
