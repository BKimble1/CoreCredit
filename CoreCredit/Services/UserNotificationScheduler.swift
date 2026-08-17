//
//  UserNotificationScheduler.swift
//  CoreCredit
//
//  The only file in the app that imports UserNotifications.
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
/// turn is only called from the notification settings screen or the moment the user first opts
/// into reminders. Nothing here runs at app startup.
final class UserNotificationScheduler: NotificationScheduling {

    /// Groups every core reminder into one thread in Notification Centre so a shop with a dozen
    /// due cores sees one stack instead of a dozen separate banners.
    private static let threadIdentifier = "com.corecredit.reminders.core-return"

    /// `userInfo` key carrying the item's UUID string, so a tapped notification can deep-link.
    static let itemIDUserInfoKey = "coreItemID"

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
        content.userInfo = [UserNotificationScheduler.itemIDUserInfoKey: request.itemID.uuidString]

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

    func cancel(itemIDs: [UUID]) async {
        guard !itemIDs.isEmpty else { return }
        let identifiers = itemIDs.map { CoreReminderRequest.identifier(for: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Removes only CoreCredit's own pending reminders, leaving anything else this app might
    /// schedule in future untouched.
    func cancelAll() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let identifiers = pending
            .map { $0.identifier }
            .filter { $0.hasPrefix(CoreReminderRequest.identifierPrefix) }
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
