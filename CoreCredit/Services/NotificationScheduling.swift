//
//  NotificationScheduling.swift
//  CoreCredit
//
//  The abstraction the rest of the app schedules reminders through. Foundation only — the
//  UserNotifications framework is confined to `UserNotificationScheduler` and
//  `NotificationResponder`, so every caller (and every test) can work against a recorder instead
//  of the real notification centre.
//

import Foundation

// MARK: - Authorization

/// CoreCredit's own view of the notification permission, mapped from `UNAuthorizationStatus`.
///
/// A dedicated enum keeps `UserNotifications` out of the domain, the view models, and the tests,
/// and gives us a stable `.unknown` case for any status a future iOS adds.
enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    /// True only when the system will actually accept a new request.
    ///
    /// `.notDetermined` is deliberately `false`: permission must be asked for **in context** first
    /// (see `ReminderCoordinator.requestAuthorizationIfNeeded()`), never implicitly as a side
    /// effect of scheduling.
    var allowsScheduling: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }

    /// One plain sentence for the notification settings screen. No jargon — the reader is a
    /// service manager, not an iOS developer.
    var explanation: String {
        switch self {
        case .notDetermined:
            return "CoreCredit has not asked for permission to send reminders yet."
        case .denied:
            return "Reminders are turned off for CoreCredit. Turn them on in the Settings app to get an alert before a core return is due."
        case .authorized:
            return "Reminders are on. CoreCredit will alert you before a core return is due."
        case .provisional:
            return "Reminders are delivered quietly to Notification Centre. Allow them from a notification to get a normal alert."
        case .ephemeral:
            return "Reminders work for as long as this session lasts."
        case .unknown:
            return "CoreCredit could not read this device's notification permission."
        }
    }
}

// MARK: - Reminder kinds

/// The distinct reasons CoreCredit has for interrupting somebody.
///
/// One core can legitimately be the subject of several of these at once — a core that went back to
/// the vendor three weeks ago and was never credited is both "awaiting credit" and, if its return
/// window has closed, "overdue". Each kind therefore gets its own scheduled request and its own
/// identifier, which is why the identifier format carries the kind (see
/// `CoreReminderRequest.identifier(for:kind:leadDays:)`).
///
/// The raw values appear inside notification identifiers that survive an app relaunch, so they must
/// not be renamed: a renamed case would orphan every reminder already queued on the device.
enum ReminderKind: String, CaseIterable, Codable, Sendable {

    /// A configurable number of days before the return window closes. Default leads are 7, 3, 1.
    case dueSoon

    /// The morning of the deadline itself.
    case dueToday

    /// The window has already closed and the core is still open.
    case overdue

    /// Returned to the vendor, no credit recorded, and the agreed grace period has elapsed.
    case awaitingCredit

    /// The credit came up short and nobody has chased it since.
    case disputeFollowUp

    /// A single weekly digest of everything still open. Opt-in, off by default.
    case weeklySummary

    /// Ranking used when the queue has to be trimmed: **lower wins**.
    ///
    /// Money already late outranks money about to be late, which outranks a courtesy heads-up.
    /// The weekly digest is last because losing it costs the least — every core it mentions still
    /// has its own reminders.
    var priority: Int {
        switch self {
        case .overdue: return 0
        case .dueToday: return 1
        case .dueSoon: return 2
        case .awaitingCredit: return 3
        case .disputeFollowUp: return 4
        case .weeklySummary: return 5
        }
    }

    /// True when the reminder is about one specific core, and therefore carries an item identifier
    /// and an item deep link.
    var isAboutOneItem: Bool {
        switch self {
        case .dueSoon, .dueToday, .overdue, .awaitingCredit, .disputeFollowUp:
            return true
        case .weeklySummary:
            return false
        }
    }
}

// MARK: - Categories, actions, and routes

/// `UNNotificationCategory` identifiers. Registered by `NotificationResponder`, stamped onto
/// content by `UserNotificationScheduler`.
enum ReminderNotificationCategory {

    /// Carries View Item, Scan Core, and Snooze 1 Day.
    static let itemReminder = "corecredit.reminder.item"

    /// The weekly digest and the test notification: no custom actions, because there is no single
    /// core for them to act on.
    static let summary = "corecredit.reminder.summary"
}

/// `UNNotificationAction` identifiers.
///
/// **None of these change a financial value or a custody status.** View and Scan only open a
/// screen; Snooze only moves a local alert. A vendor credit, a write-off, or a status change is
/// never one tap away from the Lock Screen.
enum ReminderNotificationAction {
    static let viewItem = "corecredit.action.viewItem"
    static let scanCore = "corecredit.action.scanCore"
    static let snoozeOneDay = "corecredit.action.snoozeOneDay"
}

/// The only two keys a CoreCredit notification's `userInfo` ever carries.
///
/// Deliberately minimal: an item identifier and a deep link. No amount, no vendor, no part
/// description. `userInfo` is readable by anything that can read the notification, and a shop's
/// vendor relationships are its own business.
enum ReminderUserInfoKey {
    static let itemID = "coreItemID"
    static let route = "route"
}

/// The deep links a reminder can point at.
///
/// These are the app's **existing** links — the same `corecredit://item/<uuid>` a printed bin tag
/// QR code carries (`BinTagPayload.encodedString`). Nothing here parses or dispatches a URL; that
/// belongs to the app shell's router.
enum ReminderRoute {

    /// `"corecredit://item/<uuid>"`
    static func item(_ itemID: UUID) -> String {
        AppConfiguration.urlScheme + "://item/" + itemID.uuidString
    }

    /// `"corecredit://scan"`
    static let scan = AppConfiguration.urlScheme + "://scan"
}

// MARK: - Request

/// One scheduled alert.
///
/// The identifier is derived from the item **and the kind**, not generated fresh, so re-scheduling
/// an item's reminders replaces them instead of stacking duplicates. That is the whole reason the
/// identifier is deterministic: an item can be edited any number of times and the shop still only
/// ever gets one alert per reason.
struct CoreReminderRequest: Equatable, Sendable {

    /// The core item this reminder is about. `nil` for `.weeklySummary`, which is about the whole
    /// ledger rather than any one core.
    var itemID: UUID?

    /// Why this alert exists.
    var kind: ReminderKind

    /// For `.dueSoon`, how many days before the deadline this particular request fires. `nil` for
    /// every other kind. It is part of the identifier, so a shop configured for 7/3/1 gets three
    /// separate alerts rather than three collisions on one.
    var leadDays: Int?

    /// Notification title, e.g. `"Core return due soon"`.
    var title: String

    /// Notification body. Generic by default; detailed only when the shop has switched
    /// `ShopProfile.showsDetailInNotifications` on.
    var body: String

    /// The absolute instant the alert should fire.
    var fireDate: Date

    /// Deep link opened when the notification (or its View Item action) is tapped. `nil` means
    /// "just bring the app forward".
    var route: String?

    init(itemID: UUID?,
         kind: ReminderKind,
         leadDays: Int? = nil,
         title: String,
         body: String,
         fireDate: Date,
         route: String? = nil) {
        self.itemID = itemID
        self.kind = kind
        self.leadDays = leadDays
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.route = route
    }

    /// `"core-reminder-<kind>-<uuid>"`, or `"core-reminder-dueSoon7-<uuid>"` for a due-soon lead.
    /// Stable for the lifetime of the item and the setting.
    var identifier: String {
        CoreReminderRequest.identifier(for: itemID, kind: kind, leadDays: leadDays)
    }

    /// The identifier a reminder would use, without needing a full request.
    ///
    /// The item's UUID is always the **suffix**, which is what makes
    /// `identifier(_:belongsTo:)` able to find every reminder for one core without having to know
    /// which leads that shop has configured.
    static func identifier(for itemID: UUID?, kind: ReminderKind, leadDays: Int? = nil) -> String {
        var text = identifierPrefix + kind.rawValue

        // Only due-soon carries a lead. A lead is what distinguishes "7 days out" from "1 day out"
        // for the same core, so leaving it off would collapse the two into one alert.
        if kind == .dueSoon, let leadDays = leadDays, leadDays >= 0 {
            text += String(leadDays)
        }

        if let itemID = itemID {
            text += "-" + itemID.uuidString
        }
        return text
    }

    /// Only requests carrying this prefix belong to CoreCredit's reminder system.
    static let identifierPrefix = "core-reminder-"

    /// The identifier used by the settings screen's "send me one now" button.
    static let testIdentifier = identifierPrefix + "test"

    /// True when `identifier` is one of CoreCredit's reminders **for this exact item**, whatever
    /// kind or lead produced it. This is how cancellation stays exact.
    static func identifier(_ identifier: String, belongsTo itemID: UUID) -> Bool {
        identifier.hasPrefix(identifierPrefix) && identifier.hasSuffix("-" + itemID.uuidString)
    }

    /// Narrows a list of pending identifiers down to the ones belonging to `itemIDs`.
    ///
    /// Used by the real scheduler's cancellation path: it reads what is actually queued rather
    /// than guessing at which kinds and leads were used when the alerts were created, so a setting
    /// that changed in between cannot leave an orphan behind.
    static func identifiers(_ identifiers: [String], belongingTo itemIDs: [UUID]) -> [String] {
        guard !itemIDs.isEmpty else { return [] }
        return identifiers.filter { candidate in
            itemIDs.contains { CoreReminderRequest.identifier(candidate, belongsTo: $0) }
        }
    }
}

// MARK: - Protocol

/// Everything the app needs from the notification system.
///
/// `schedule(_:)` **replaces** any pending request that shares the new request's identifier, so
/// callers can re-schedule freely whenever an item changes without first cancelling.
///
/// Nothing in this protocol asks for permission implicitly. Authorization is requested only by
/// `requestAuthorization()`, which is called in context — from the notification settings screen —
/// and never at app startup.
protocol NotificationScheduling: AnyObject, Sendable {

    /// The current permission, read fresh from the system each time.
    func authorizationStatus() async -> NotificationAuthorizationStatus

    /// Presents the system permission prompt when the status is still undetermined, then reports
    /// the resulting status. Never throws: a refusal is an answer, not an error.
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus

    /// Schedules (or replaces) one reminder.
    ///
    /// - Throws: `NotificationSchedulingError.notAuthorized` when the app may not post
    ///   notifications, `.fireDateInPast` when the moment has already passed, and
    ///   `.systemError` for anything the notification centre itself reports.
    func schedule(_ request: CoreReminderRequest) async throws

    /// Removes the pending reminders belonging to these items, of every kind. Unknown items are
    /// ignored.
    func cancel(itemIDs: [UUID]) async

    /// Removes every pending CoreCredit reminder.
    func cancelAll() async

    /// Identifiers of the reminders the system currently has queued. Used by tests and by the
    /// notification settings screen's "scheduled reminders" count.
    func pendingIdentifiers() async -> [String]

    /// Fires one throwaway alert a few seconds from now, so the owner can see what a reminder
    /// looks like on this device without waiting for a real deadline.
    ///
    /// Carries no item, no route, and no ledger detail — it exists to prove delivery works.
    func scheduleTestNotification(after seconds: TimeInterval) async throws
}

// MARK: - Errors

/// Why a reminder could not be scheduled.
///
/// Failure is a real, surfaced state — `ReminderCoordinator.lastError` shows these to the user.
/// Reminders are never allowed to fail silently, and never allowed to crash the app.
enum NotificationSchedulingError: LocalizedError, Equatable {

    /// The app has no permission to post notifications.
    case notAuthorized

    /// The requested moment is already behind us.
    case fireDateInPast

    /// The notification centre rejected the request for its own reason.
    case systemError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "CoreCredit is not allowed to send notifications, so the reminder was not set. Turn notifications on in the Settings app."
        case .fireDateInPast:
            return "That reminder time has already passed, so no alert was set."
        case .systemError(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "The reminder could not be scheduled."
            }
            return "The reminder could not be scheduled. " + trimmed
        }
    }
}
