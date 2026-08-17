//
//  NotificationScheduling.swift
//  CoreCredit
//
//  The abstraction the rest of the app schedules reminders through. Foundation only — the
//  UserNotifications framework is confined to `UserNotificationScheduler`, so every caller
//  (and every test) can work against a recorder instead of the real notification centre.
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

// MARK: - Request

/// One scheduled "this core is due back soon" alert.
///
/// The identifier is derived from the item, not generated fresh, so re-scheduling a reminder for
/// an item that already has one **replaces** it instead of stacking a duplicate. That is the whole
/// reason the identifier is deterministic: an item can be edited any number of times and the user
/// still only ever gets one alert per core.
struct CoreReminderRequest: Equatable, Sendable {

    /// The core item this reminder is about.
    var itemID: UUID

    /// Notification title, e.g. `"Core return due Friday"`.
    var title: String

    /// Notification body, e.g. `"Alternator (03-1887) — $86.50 to NAPA. Bin A3."`
    var body: String

    /// The absolute instant the alert should fire.
    var fireDate: Date

    init(itemID: UUID, title: String, body: String, fireDate: Date) {
        self.itemID = itemID
        self.title = title
        self.body = body
        self.fireDate = fireDate
    }

    /// `"core-reminder-<uuid>"` — stable for the lifetime of the item.
    var identifier: String {
        CoreReminderRequest.identifier(for: itemID)
    }

    /// The identifier a reminder for `itemID` would use, without needing a full request.
    ///
    /// Cancellation paths need this: they know the item but have no title, body, or fire date.
    static func identifier(for itemID: UUID) -> String {
        identifierPrefix + itemID.uuidString
    }

    /// Only requests carrying this prefix belong to CoreCredit's reminder system.
    static let identifierPrefix = "core-reminder-"
}

// MARK: - Protocol

/// Everything the app needs from the notification system.
///
/// `schedule(_:)` **replaces** any pending request that shares the new request's identifier, so
/// callers can re-schedule freely whenever an item changes without first cancelling.
///
/// Nothing in this protocol asks for permission implicitly. Authorization is requested only by
/// `requestAuthorization()`, which is called in context — from the notification settings screen or
/// the first time the user opts into reminders — and never at app startup.
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

    /// Removes the pending reminders belonging to these items. Unknown items are ignored.
    func cancel(itemIDs: [UUID]) async

    /// Removes every pending CoreCredit reminder.
    func cancelAll() async

    /// Identifiers of the reminders the system currently has queued. Used by tests and by the
    /// notification settings screen's "scheduled reminders" count.
    func pendingIdentifiers() async -> [String]
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
