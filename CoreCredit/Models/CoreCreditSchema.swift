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

/// Migration plan for the CoreCredit store.
///
/// V1 is the initial schema, so `stages` is empty — there is nothing to migrate *from*.
///
/// ## Adding a V2
///
/// 1. Copy the current model definitions into a new `enum CoreCreditSchemaV2: VersionedSchema`
///    with `versionIdentifier` `Schema.Version(2, 0, 0)`, then make the change (new property,
///    renamed property, new model type).
/// 2. Append it to `schemas` **in ascending version order**: `[CoreCreditSchemaV1.self,
///    CoreCreditSchemaV2.self]`. SwiftData walks this list in order to find a migration path.
/// 3. Add the matching stage to `stages`, again in ascending order:
///
///    ```swift
///    static let migrateV1toV2 = MigrationStage.lightweight(
///        fromVersion: CoreCreditSchemaV1.self,
///        toVersion: CoreCreditSchemaV2.self
///    )
///    static var stages: [MigrationStage] { [migrateV1toV2] }
///    ```
///
/// A **lightweight** stage covers the changes SwiftData can infer on its own: adding a property
/// that has a default value, adding an optional property, adding a whole new model type, or
/// deleting a property. Every stored property in this schema either has a default in its
/// declaration or is optional, specifically so that V1 -> V2 can stay lightweight.
///
/// Anything that needs data to be rewritten — splitting one property into two, changing a
/// property's type, backfilling a value that has no sensible default — requires
/// `MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)` instead, where the
/// `didMigrate` closure fetches the migrated objects and fixes them up.
enum CoreCreditMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CoreCreditSchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}
