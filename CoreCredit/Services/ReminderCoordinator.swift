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

/// What the last rebuild of the reminder queue actually did.
///
/// Exists so the notification settings screen can say a true sentence. In particular `droppedCount`
/// is never hidden: iOS keeps a fixed number of pending local notifications, and a shop with
/// hundreds of open cores has a right to know that only the nearest ones are queued.
struct ReminderRefreshReport: Equatable, Sendable {

    /// Reminders the notification centre accepted.
    var scheduledCount: Int

    /// Reminders the planner had to leave out because the queue is capped.
    var droppedCount: Int

    /// Reminders the notification centre refused. `lastError` carries the first reason.
    var failedCount: Int

    /// When the rebuild ran, from the injected clock.
    var refreshedAt: Date

    init(scheduledCount: Int, droppedCount: Int, failedCount: Int, refreshedAt: Date) {
        self.scheduledCount = scheduledCount
        self.droppedCount = droppedCount
        self.failedCount = failedCount
        self.refreshedAt = refreshedAt
    }

    /// One plain sentence for the settings screen.
    var summary: String {
        if scheduledCount == 0 && droppedCount == 0 {
            return "No reminders are queued."
        }

        var text = scheduledCount == 1 ? "1 reminder is queued" : String(scheduledCount) + " reminders are queued"

        if droppedCount > 0 {
            text += ", and " + String(droppedCount)
            text += droppedCount == 1 ? " further reminder was left out" : " further reminders were left out"
            text += " because this device holds a limited number at a time. The soonest and most "
            text += "urgent are the ones kept."
            return text + "."
        }

        return text + "."
    }
}

/// Owns the reminder side effect for the whole app.
///
/// # Permission is asked for in context, never at launch
///
/// `requestAuthorizationIfNeeded()` is called from exactly one place: the notification settings
/// screen. It is **never** called from an initialiser, from `AppEnvironment.bootstrap()`, or from
/// any view's `.task`/`onAppear` that runs at startup. A shop owner should see the system prompt
/// because they just asked for reminders — not because they opened the app.
///
/// # The whole queue is rebuilt, every time
///
/// There is no per-item scheduling path. iOS keeps a limited number of pending local notifications,
/// so which reminders are worth a slot is a decision about the **whole ledger** — a single item
/// cannot know whether it outranks the fifty-seventh alert. `refreshAll(items:profile:)` therefore
/// cancels everything and re-plans from scratch, which also means an item deleted, credited, or
/// written off outside this process can never leave a stale alert behind.
///
/// # Rescheduling is wired into the write path
///
/// `CoreItemService` announces every successful save through `CoreItemChangeRelay`, and this
/// coordinator subscribes to it in `init`. Creating, editing, transitioning, crediting, clearing a
/// credit, writing off, and deleting a core all refresh the queue, as do changes to the shop's
/// notification settings. Successive writes inside one run loop turn collapse into a single
/// rebuild. The app shell calls `refreshAll(items:profile:)` (or `refreshFromStore(_:)`) at launch
/// and whenever the scene becomes active.
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

    /// What the last rebuild did. `nil` until one has run.
    private(set) var lastRefresh: ReminderRefreshReport?

    /// The in-flight rebuild, cancelled and replaced by the next request so a burst of writes
    /// produces one rebuild rather than one per write.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// How far out the settings screen's test notification fires.
    static let testNotificationDelay: TimeInterval = 5

    /// - Parameter observesItemChanges: when `true` (the default) this coordinator becomes the
    ///   listener on `CoreItemChangeRelay.shared`, which is what wires reminders into the write
    ///   path. The app builds exactly one coordinator; a test that wants the relay left alone can
    ///   pass `false`.
    init(scheduler: any NotificationScheduling,
         dateProvider: any DateProvider,
         observesItemChanges: Bool = true) {
        self.scheduler = scheduler
        self.dateProvider = dateProvider

        if observesItemChanges {
            startObservingItemChanges()
        }
    }

    // MARK: - Authorization

    /// Re-reads the system permission. Safe to call from anywhere, including app launch: it only
    /// reads, it never prompts.
    func refreshAuthorization() async {
        authorization = await scheduler.authorizationStatus()
    }

    /// Shows the system permission prompt, but only when the answer is still unknown.
    ///
    /// Call this from the notification settings screen — never on first launch. iOS only ever
    /// presents the prompt once, so spending it at launch, before the user understands what the
    /// reminders are for, permanently costs the feature.
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

    /// Rebuilds the entire reminder queue from scratch.
    ///
    /// Cancels everything first, plans every kind for every item, trims to the queue cap, and
    /// schedules what is left. Resilient by design: a failure on one item is recorded and the loop
    /// carries on, so a single bad record never silently drops every other shop reminder.
    func refreshAll(items: [CoreItem], profile: ShopProfile) async {
        await scheduler.cancelAll()

        let now = dateProvider.now

        guard profile.remindersEnabled else {
            lastError = nil
            lastRefresh = ReminderRefreshReport(scheduledCount: 0,
                                                droppedCount: 0,
                                                failedCount: 0,
                                                refreshedAt: now)
            return
        }

        let plan = ReminderPlanner.queuePlan(for: items,
                                             options: planningOptions(for: profile),
                                             now: now,
                                             calendar: dateProvider.calendar)

        var scheduledCount = 0
        var failedCount = 0
        var firstError: String?

        for request in plan.scheduled {
            // A superseded pass stops here rather than finishing: the pass that replaced it is
            // about to cancel and rebuild the whole queue, and carrying on would re-add reminders
            // that newer pass has already decided against. `lastRefresh` is left describing the
            // pass that actually finished.
            if Task.isCancelled { return }

            do {
                try await scheduler.schedule(request)
                scheduledCount += 1
            } catch {
                failedCount += 1
                if firstError == nil {
                    firstError = ReminderCoordinator.message(for: error)
                }
            }
        }

        lastError = firstError
        lastRefresh = ReminderRefreshReport(scheduledCount: scheduledCount,
                                            droppedCount: plan.droppedCount,
                                            failedCount: failedCount,
                                            refreshedAt: now)
    }

    /// Reads the shop profile and every core out of `context`, then rebuilds the queue.
    ///
    /// The app shell uses this at launch and on scene activation; the write-path hook uses it after
    /// a save. Does nothing when no shop profile exists yet — there are no settings to schedule
    /// from, and creating one here would be a write from the reminder layer.
    func refreshFromStore(_ context: ModelContext) async {
        let profileDescriptor = FetchDescriptor<ShopProfile>(
            sortBy: [SortDescriptor(\ShopProfile.createdAt, order: .forward)]
        )

        let profile: ShopProfile
        let items: [CoreItem]
        do {
            guard let stored = try context.fetch(profileDescriptor).first else { return }
            profile = stored
            items = try context.fetch(FetchDescriptor<CoreItem>())
        } catch {
            lastError = "Reminders could not be refreshed because the ledger could not be read. "
                + ReminderCoordinator.message(for: error)
            return
        }

        await refreshAll(items: items, profile: profile)
    }

    /// Asks for a rebuild without waiting for one.
    ///
    /// Deliberately coalescing: `CoreItemService` announces a change once per save, and a single
    /// user action — creating a return batch of twelve cores — produces a run of saves. Cancelling
    /// the previous task means the whole run collapses into one rebuild, on the next turn of the
    /// run loop, by which point every one of those saves has landed.
    func requestRefresh(context: ModelContext) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // Yield first so writes still on the stack finish and are folded into this one pass.
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            await self.refreshFromStore(context)
        }
    }

    /// Drops every CoreCredit reminder — used when the shop turns reminders off, or when all data
    /// is erased from the data settings screen.
    func cancelAll() async {
        await scheduler.cancelAll()
        lastError = nil
        lastRefresh = ReminderRefreshReport(scheduledCount: 0,
                                            droppedCount: 0,
                                            failedCount: 0,
                                            refreshedAt: dateProvider.now)
    }

    /// Fires one throwaway alert a few seconds out so the owner can see what arrives on this
    /// device. Returns `false` — and fills `lastError` — when the system refused.
    @discardableResult
    func sendTestNotification() async -> Bool {
        do {
            try await scheduler.scheduleTestNotification(after: ReminderCoordinator.testNotificationDelay)
            lastError = nil
            return true
        } catch {
            lastError = ReminderCoordinator.message(for: error)
            return false
        }
    }

    /// Clears a surfaced failure once the user has dismissed the banner.
    func clearError() {
        lastError = nil
    }

    // MARK: - Write-path observation

    /// Makes this coordinator the listener on `CoreItemChangeRelay.shared`.
    ///
    /// The relay holds one listener. The app creates one coordinator, so that is unambiguous; a
    /// second coordinator (a test, a preview) takes the slot over, and `stopObservingItemChanges()`
    /// gives it back.
    func startObservingItemChanges() {
        CoreItemChangeRelay.shared.setObserver { [weak self] context in
            self?.requestRefresh(context: context)
        }
    }

    /// Stops listening, leaving the relay with no observer.
    func stopObservingItemChanges() {
        CoreItemChangeRelay.shared.removeObserver()
    }

    // MARK: - Settings

    /// The shop's stored settings, in the shape the pure planner wants.
    func planningOptions(for profile: ShopProfile) -> ReminderPlanningOptions {
        ReminderPlanningOptions(
            dueSoonLeadDays: profile.reminderDueSoonLeadDays,
            hour: profile.reminderHour,
            minute: profile.reminderMinute,
            awaitingCreditDelayDays: profile.awaitingCreditReminderDelayDays,
            disputeFollowUpDelayDays: profile.disputeFollowUpReminderDelayDays,
            includesWeeklySummary: profile.weeklySummaryEnabled,
            weeklySummaryWeekday: ReminderPlanner.defaultWeeklySummaryWeekday,
            showsDetail: profile.showsDetailInNotifications,
            currencyCode: profile.currencyCode
        )
    }

    // MARK: - Private

    /// Prefers a `LocalizedError`'s own sentence; falls back to the system description so the user
    /// always gets *something* readable rather than a silent no-op.
    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
