//
//  ReminderCoordinator.swift
//  CoreCredit
//
//  The app-facing front door for reminders: reads the permission, plans, schedules, and turns
//  every failure into presentable text instead of a crash.
//

import Foundation
import Observation
import SwiftData

/// Owns the reminder side effect for the whole app.
///
/// # Permission is asked for in context, never at launch
///
/// `requestAuthorizationIfNeeded()` is called from exactly two places:
/// the notification settings screen, and the moment the user first switches reminders on. It is
/// **never** called from an initialiser, from `AppEnvironment.bootstrap()`, or from any view's
/// `.task`/`onAppear` that runs at startup. A shop owner should see the system prompt because they
/// just asked for reminders — not because they opened the app.
///
/// # Rescheduling
///
/// Reminders are re-planned whenever an item changes (`reschedule(for:profile:)`) and whenever the
/// shop's reminder settings change (`rescheduleAll(items:profile:)`). Because
/// `NotificationScheduling.schedule` replaces any pending request with the same identifier, calling
/// this more often than strictly necessary is always safe and never produces duplicate alerts.
///
/// # Failure is a state, not a crash
///
/// Anything the notification centre refuses lands in `lastError` as a sentence the user can read.
/// One item failing never aborts the rest of a batch.
@MainActor
@Observable
final class ReminderCoordinator {

    private let scheduler: any NotificationScheduling
    private let dateProvider: any DateProvider

    /// Last known permission. Starts `.notDetermined` and is only refreshed on demand — reading it
    /// does not prompt.
    private(set) var authorization: NotificationAuthorizationStatus = .notDetermined

    /// The most recent scheduling failure, ready to show in an `ErrorBanner`. `nil` when the last
    /// operation succeeded.
    private(set) var lastError: String?

    init(scheduler: any NotificationScheduling, dateProvider: any DateProvider) {
        self.scheduler = scheduler
        self.dateProvider = dateProvider
    }

    // MARK: - Authorization

    /// Re-reads the system permission. Safe to call from anywhere, including app launch: it only
    /// reads, it never prompts.
    func refreshAuthorization() async {
        authorization = await scheduler.authorizationStatus()
    }

    /// Shows the system permission prompt, but only when the answer is still unknown.
    ///
    /// Call this from the notification settings screen or when the user opts into reminders —
    /// never on first launch. iOS only ever presents the prompt once, so spending it at launch,
    /// before the user understands what the reminders are for, permanently costs the feature.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> NotificationAuthorizationStatus {
        let current = await scheduler.authorizationStatus()
        authorization = current

        guard current == .notDetermined else { return current }

        let updated = await scheduler.requestAuthorization()
        authorization = updated
        return updated
    }

    // MARK: - Scheduling

    /// Re-plans the single reminder for one item.
    ///
    /// Cancels instead of scheduling when reminders are off, when the item no longer needs one
    /// (closed, no due date), or when the moment has already passed.
    func reschedule(for item: CoreItem, profile: ShopProfile) async {
        let itemID = item.id

        guard profile.remindersEnabled, let request = plan(for: item, profile: profile) else {
            await scheduler.cancel(itemIDs: [itemID])
            lastError = nil
            return
        }

        do {
            try await scheduler.schedule(request)
            lastError = nil
        } catch {
            lastError = ReminderCoordinator.message(for: error)
        }
    }

    /// Rebuilds the entire reminder queue from scratch.
    ///
    /// Cancels everything first so items that were deleted, credited, or written off outside this
    /// process cannot leave a stale alert behind. Resilient by design: a failure on one item is
    /// recorded and the loop carries on, so a single bad record never silently drops every other
    /// shop reminder.
    func rescheduleAll(items: [CoreItem], profile: ShopProfile) async {
        await scheduler.cancelAll()

        guard profile.remindersEnabled else {
            lastError = nil
            return
        }

        let requests = items.compactMap { plan(for: $0, profile: profile) }

        var firstError: String?
        for request in requests {
            do {
                try await scheduler.schedule(request)
            } catch {
                if firstError == nil {
                    firstError = ReminderCoordinator.message(for: error)
                }
            }
        }

        lastError = firstError
    }

    /// Drops the reminder for one item — used when it is credited, written off, or deleted.
    func cancel(for item: CoreItem) async {
        await scheduler.cancel(itemIDs: [item.id])
    }

    /// Drops every CoreCredit reminder — used when the shop turns reminders off, or when all data
    /// is erased from the data settings screen.
    func cancelAll() async {
        await scheduler.cancelAll()
        lastError = nil
    }

    /// Clears a surfaced failure once the user has dismissed the banner.
    func clearError() {
        lastError = nil
    }

    // MARK: - Private

    private func plan(for item: CoreItem, profile: ShopProfile) -> CoreReminderRequest? {
        ReminderPlanner.plan(
            for: item,
            leadDays: profile.reminderLeadDays,
            hour: profile.reminderHour,
            minute: profile.reminderMinute,
            now: dateProvider.now,
            calendar: dateProvider.calendar,
            currencyCode: profile.currencyCode
        )
    }

    /// Prefers a `LocalizedError`'s own sentence; falls back to the system description so the user
    /// always gets *something* readable rather than a silent no-op.
    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
