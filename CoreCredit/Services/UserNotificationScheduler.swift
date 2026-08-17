//
//  UserNotificationScheduler.swift
//  CoreCredit
//
//  One of only two files in the app that import UserNotifications. The other is
//  `NotificationResponder`, which handles what happens *after* an alert is delivered.
//

import Foundation
import UserNotifications

/// Production `NotificationScheduling`, backed by `UNUserNotificationCenter.current()`.
///
/// The type holds no state at all — every call reads the notification centre fresh — which is what
/// makes it safely usable from any actor.
///
/// **Permission is never requested implicitly.** `requestAuthorization()` shows the system prompt,
/// and it is only ever called from `ReminderCoordinator.requestAuthorizationIfNeeded()`, which in
/// turn is only called from the notification settings screen. Nothing here runs at app startup.
///
/// # What goes on the wire
///
/// The content carries the title and body the planner composed — generic unless the shop opted into
/// detail — and a `userInfo` of exactly two keys: the item's UUID and a deep-link route string.
/// No amount, no vendor, no part description is ever put in `userInfo`.
final class UserNotificationScheduler: NotificationScheduling {

    /// Groups every core reminder into one thread in Notification Centre so a shop with a dozen
    /// due cores sees one stack instead of a dozen separate banners.
    private static let threadIdentifier = "com.corecredit.reminders.core-return"

    init() {}

    // MARK: - Authorization

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return UserNotificationScheduler.mapped(settings.authorizationStatus)
    }

    /// Shows the system permission sheet when the status is undetermined, then re-reads the real
    /// status rather than trusting the returned `Bool` — the user can also change the answer in
    /// Settings while the sheet is up.
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A thrown error here means the prompt could not be presented. The authoritative
            // answer is still whatever the settings say, so fall through and read them.
        }
        return await authorizationStatus()
    }

    // MARK: - Scheduling

    /// Schedules one reminder, replacing any pending request with the same identifier.
    ///
    /// `UNUserNotificationCenter.add(_:)` is documented to replace a pending request that shares an
    /// identifier, which is exactly the behaviour the reschedule-on-every-edit rule depends on.
    func schedule(_ request: CoreReminderRequest) async throws {
        let status = await authorizationStatus()
        guard status.allowsScheduling else {
            throw NotificationSchedulingError.notAuthorized
        }

        // The only place in this layer that reads the wall clock: turning "is this moment still in
        // the future?" into an answer needs the real now. The planner stays pure.
        guard request.fireDate > Date() else {
            throw NotificationSchedulingError.fireDateInPast
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = UNNotificationSound.default
        content.threadIdentifier = UserNotificationScheduler.threadIdentifier
        content.categoryIdentifier = request.kind.isAboutOneItem
            ? ReminderNotificationCategory.itemReminder
            : ReminderNotificationCategory.summary
        content.userInfo = UserNotificationScheduler.userInfo(for: request)

        // A calendar trigger (rather than a time-interval one) keeps the alert pinned to the
        // shop's local wall-clock time even if the device travels across a time zone.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: request.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let notificationRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            throw NotificationSchedulingError.systemError(error.localizedDescription)
        }
    }

    /// Fires one throwaway alert `seconds` from now so the owner can confirm delivery works.
    ///
    /// Deliberately not a `CoreReminderRequest`: it names no core, carries no route, and is not
    /// part of the planned queue. It reuses the reminder identifier prefix so `cancelAll()` sweeps
    /// it away with everything else.
    func scheduleTestNotification(after seconds: TimeInterval) async throws {
        let status = await authorizationStatus()
        guard status.allowsScheduling else {
            throw NotificationSchedulingError.notAuthorized
        }

        // `UNTimeIntervalNotificationTrigger` rejects an interval below one second.
        let delay = seconds < 1 ? 1 : seconds

        let content = UNMutableNotificationContent()
        content.title = "Test reminder"
        content.body = "This is what a " + AppConfiguration.displayName
            + " reminder looks like. Nothing in the ledger was changed."
        content.sound = UNNotificationSound.default
        content.threadIdentifier = UserNotificationScheduler.threadIdentifier
        content.categoryIdentifier = ReminderNotificationCategory.summary

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let notificationRequest = UNNotificationRequest(
            identifier: CoreReminderRequest.testIdentifier,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            throw NotificationSchedulingError.systemError(error.localizedDescription)
        }
    }

    /// Removes every pending reminder belonging to these items, of every kind and every lead.
    ///
    /// Reads what is actually queued and matches on the item's UUID suffix rather than
    /// reconstructing identifiers from the current settings. A shop that changed its lead days
    /// between scheduling and cancelling would otherwise leave orphaned alerts behind.
    func cancel(itemIDs: [UUID]) async {
        guard !itemIDs.isEmpty else { return }
        let pending = await pendingIdentifiers()
        let identifiers = CoreReminderRequest.identifiers(pending, belongingTo: itemIDs)
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Removes only CoreCredit's own pending reminders, leaving anything else this app might
    /// schedule in future untouched.
    func cancelAll() async {
        let identifiers = await pendingIdentifiers()
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingIdentifiers() async -> [String] {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending
            .map { $0.identifier }
            .filter { $0.hasPrefix(CoreReminderRequest.identifierPrefix) }
            .sorted()
    }

    // MARK: - Payload

    /// The item identifier and the deep link, and nothing else.
    ///
    /// Typed as the dictionary `UNMutableNotificationContent.userInfo` actually takes, so nothing
    /// has to be bridged at the assignment.
    private static func userInfo(for request: CoreReminderRequest) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [:]
        if let itemID = request.itemID {
            payload[ReminderUserInfoKey.itemID] = itemID.uuidString
        }
        if let route = request.route {
            payload[ReminderUserInfoKey.route] = route
        }
        return payload
    }

    // MARK: - Mapping

    /// Exhaustive mapping, including `@unknown default` so a status added by a future iOS becomes
    /// `.unknown` instead of failing to compile or silently reading as "authorized".
    private static func mapped(_ status: UNAuthorizationStatus) -> NotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }
}
