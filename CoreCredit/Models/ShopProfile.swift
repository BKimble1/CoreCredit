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

    /// The single lead the 1.0 build used. Kept because it is persisted in every existing store and
    /// because it is still the sensible seed when a shop clears every due-soon choice: see
    /// `reminderDueSoonLeadDays`.
    var reminderLeadDays: Int = AppConfiguration.defaultReminderLeadDays

    /// The due-soon leads, as a comma-separated list of whole days, longest first.
    ///
    /// Stored as text rather than `[Int]` so the schema step that introduced it stays a plain
    /// lightweight migration: a `String` with a default is exactly the kind of added attribute
    /// SwiftData can infer. Read and written through `reminderDueSoonLeadDays`.
    var reminderDueSoonLeadDaysRaw: String = ShopProfile.defaultDueSoonLeadDaysRaw

    var reminderHour: Int = AppConfiguration.defaultReminderHour
    var reminderMinute: Int = AppConfiguration.defaultReminderMinute
    var remindersEnabled: Bool = true

    /// Days after a core goes back to the vendor before CoreCredit asks where the credit is.
    var awaitingCreditReminderDelayDays: Int = ReminderPlanner.defaultAwaitingCreditDelayDays

    /// Days after a short credit is recorded before CoreCredit asks about the dispute.
    var disputeFollowUpReminderDelayDays: Int = ReminderPlanner.defaultDisputeFollowUpDelayDays

    /// The opt-in weekly digest of everything still open. Off by default: one more standing
    /// interruption has to be asked for, not assumed.
    var weeklySummaryEnabled: Bool = false

    /// Whether notification text may name the part, the amount, the vendor, and the bin.
    ///
    /// **Off by default, deliberately.** A banner is readable by whoever is near the phone, and a
    /// shop's vendor terms are its own business, so the default copy says only that a core needs
    /// attention. A shop that keeps the phone behind the counter can switch this on.
    var showsDetailInNotifications: Bool = false

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
        self.reminderDueSoonLeadDaysRaw = ShopProfile.defaultDueSoonLeadDaysRaw
        self.reminderHour = AppConfiguration.defaultReminderHour
        self.reminderMinute = AppConfiguration.defaultReminderMinute
        self.remindersEnabled = true
        self.awaitingCreditReminderDelayDays = ReminderPlanner.defaultAwaitingCreditDelayDays
        self.disputeFollowUpReminderDelayDays = ReminderPlanner.defaultDisputeFollowUpDelayDays
        self.weeklySummaryEnabled = false
        self.showsDetailInNotifications = false
        self.hasCompletedOnboarding = false
        self.createdAt = now
        self.updatedAt = now
    }

    /// The due-soon leads, sanitised: whole days only, inside `0...30`, no duplicates, longest
    /// first. Setting it rewrites `reminderDueSoonLeadDaysRaw` in the same normal form, so the
    /// stored text can never drift into something the planner has to guess at.
    ///
    /// An empty list is a real answer — it means "no advance warning, only the day itself" — so it
    /// is stored as an empty string rather than silently repopulated.
    var reminderDueSoonLeadDays: [Int] {
        get { ShopProfile.leadDays(fromRaw: reminderDueSoonLeadDaysRaw) }
        set { reminderDueSoonLeadDaysRaw = ShopProfile.raw(fromLeadDays: newValue) }
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

// MARK: - Reminder settings

/// The reminder limits and the lead-day encoding, kept in an extension so nothing type-level sits
/// inside the `@Model` body alongside the persisted attributes.
extension ShopProfile {

    /// The choices the notification settings screen offers for due-soon leads.
    static var dueSoonLeadDayChoices: [Int] { [7, 3, 1] }

    /// A zero-day lead is legitimate — "tell me on the morning it is due" — and is exactly what the
    /// due-today reminder is. The upper bound is the user-facing one: `ReminderPlanner` accepts up
    /// to a year, but a shop choosing a lead in this app should not be able to wander that far.
    static var minimumLeadDays: Int { 0 }
    static var maximumLeadDays: Int { 30 }

    /// Shortest and longest follow-up delays the settings screen offers.
    static var minimumDelayDays: Int { ReminderPlanner.minimumDelayDays }
    static var maximumDelayDays: Int { 60 }

    /// `"7,3,1"` — warn a week out, again three days out, again the day before.
    static var defaultDueSoonLeadDaysRaw: String { "7,3,1" }

    /// Parses the stored text. Anything unparseable is dropped rather than defaulted, so a store
    /// hand-edited into nonsense degrades to "no advance warning" instead of to a surprise.
    static func leadDays(fromRaw raw: String) -> [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []

        for piece in raw.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let value = Int(trimmed) else { continue }
            guard value >= minimumLeadDays, value <= maximumLeadDays else { continue }
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(value)
        }

        return result.sorted(by: >)
    }

    /// The inverse of `leadDays(fromRaw:)`, in the same normal form.
    static func raw(fromLeadDays leadDays: [Int]) -> String {
        var seen: Set<Int> = []
        var kept: [Int] = []

        for value in leadDays {
            guard value >= minimumLeadDays, value <= maximumLeadDays else { continue }
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            kept.append(value)
        }

        return kept.sorted(by: >).map { String($0) }.joined(separator: ",")
    }
}
