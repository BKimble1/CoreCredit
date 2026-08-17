import Foundation
import SwiftData

/// The single shop-level record. Exactly one row is expected to exist; `CoreItemService.shopProfile()`
/// creates it lazily on first access so the rest of the app never has to deal with a missing profile.
///
/// Everything is stored non-optional (empty `String` rather than `nil`) so future lightweight
/// SwiftData migrations stay trivial.
@Model
final class ShopProfile {
    var id: UUID = UUID()
    var name: String = ""
    var phone: String = ""
    var email: String = ""
    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var region: String = ""
    var postalCode: String = ""
    var currencyCode: String = AppConfiguration.defaultCurrencyCode
    var reminderLeadDays: Int = AppConfiguration.defaultReminderLeadDays
    var reminderHour: Int = AppConfiguration.defaultReminderHour
    var reminderMinute: Int = AppConfiguration.defaultReminderMinute
    var remindersEnabled: Bool = true
    var hasCompletedOnboarding: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String = "",
         currencyCode: String = AppConfiguration.defaultCurrencyCode,
         now: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.phone = ""
        self.email = ""
        self.addressLine1 = ""
        self.addressLine2 = ""
        self.city = ""
        self.region = ""
        self.postalCode = ""
        self.currencyCode = currencyCode
        self.reminderLeadDays = AppConfiguration.defaultReminderLeadDays
        self.reminderHour = AppConfiguration.defaultReminderHour
        self.reminderMinute = AppConfiguration.defaultReminderMinute
        self.remindersEnabled = true
        self.hasCompletedOnboarding = false
        self.createdAt = now
        self.updatedAt = now
    }

    /// The shop name, or a neutral placeholder when the owner has not filled one in yet.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your shop" : trimmed
    }

    /// Multi-line postal address. Empty components are skipped entirely so there are never
    /// blank lines or dangling separators.
    var formattedAddress: String {
        var lines: [String] = []

        let street1 = addressLine1.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street1.isEmpty { lines.append(street1) }

        let street2 = addressLine2.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street2.isEmpty { lines.append(street2) }

        let cityValue = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let regionValue = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let postalValue = postalCode.trimmingCharacters(in: .whitespacesAndNewlines)

        var localityParts: [String] = []
        if !cityValue.isEmpty { localityParts.append(cityValue) }
        if !regionValue.isEmpty { localityParts.append(regionValue) }

        var locality = localityParts.joined(separator: ", ")
        if !postalValue.isEmpty {
            locality = locality.isEmpty ? postalValue : locality + " " + postalValue
        }
        if !locality.isEmpty { lines.append(locality) }

        return lines.joined(separator: "\n")
    }

    /// "phone • email", skipping whichever half is missing.
    var contactSummary: String {
        var parts: [String] = []

        let phoneValue = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneValue.isEmpty { parts.append(phoneValue) }

        let emailValue = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !emailValue.isEmpty { parts.append(emailValue) }

        return parts.joined(separator: " • ")
    }

    /// Stamps `updatedAt`. Always called from the mutation services so the clock stays injectable.
    func touch(_ now: Date) {
        updatedAt = now
    }
}
