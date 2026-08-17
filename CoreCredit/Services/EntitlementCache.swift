//
//  EntitlementCache.swift
//  CoreCredit
//

import Foundation

/// The last entitlement StoreKit confirmed, kept in `UserDefaults` so the app can answer
/// "is this shop on Pro?" before the network does.
///
/// # Why this exists
///
/// A parts department is often a metal building with no signal. If Pro access waited on a live
/// answer, a paying shop would be told it had hit the free limit every time it opened the app in
/// the back room. So the controller reads this cache first and shows Pro immediately, then
/// reconciles against StoreKit in the background.
///
/// # The one rule
///
/// Only an *authoritative* StoreKit answer may downgrade what is stored here. A load failure, a
/// network error, or a failed restore must never call `clear(_:)` or write a free entitlement —
/// those are "we don't know", not "you don't have it". `SubscriptionController` is the only caller
/// and enforces that rule.
///
/// The payload is a plain `Codable` `Entitlement`, which is trivially small and carries no
/// personal data — no account identifier, no receipt, no transaction ID.
enum EntitlementCache {

    /// The single defaults key. Versioned so a future entitlement shape can be introduced without
    /// having to decode an older one.
    private static let storageKey = AppConfiguration.bundleIdentifier + ".entitlement.v1"

    /// The cached entitlement, or `.free` when nothing usable is stored.
    ///
    /// A decode failure is treated as "no cache" rather than as an error: the controller will
    /// replace it with a real answer within a second of launch, and there is nothing a shop could
    /// usefully do about a corrupt cache entry.
    static func load(from defaults: UserDefaults = .standard) -> Entitlement {
        guard let data = defaults.data(forKey: storageKey) else { return Entitlement.free }
        guard let decoded = try? JSONDecoder().decode(Entitlement.self, from: data) else {
            return Entitlement.free
        }
        return decoded
    }

    /// Stores the entitlement. Silently does nothing if it cannot be encoded, which would mean the
    /// value itself is broken — worth neither an alert nor a crash.
    static func save(_ entitlement: Entitlement, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entitlement) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Removes the cached entitlement.
    ///
    /// Reserved for an explicit "reset all data" action. Never call this to recover from a failed
    /// refresh — see the rule in this type's documentation.
    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
