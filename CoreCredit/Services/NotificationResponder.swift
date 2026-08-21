//
//  NotificationResponder.swift
//  CoreCredit
//
//  What happens *after* a reminder is delivered: how it is presented while the app is open, and
//  what each of its actions does. One of only two files that import UserNotifications.
//

import Foundation
import UserNotifications

/// The lock-guarded state behind `NotificationResponder`.
///
/// The notification centre calls its delegate from its own context, and the app shell sets the
/// handler from the main actor, so the two pieces of mutable state are kept behind a lock rather
/// than assumed to be main-actor-only. Same pattern as `RecordingNotificationScheduler`.
private final class ResponderState: @unchecked Sendable {

    private let lock = NSLock()

    private var handler: ((URL) -> Void)?
    private var bufferedURL: URL?
    private var snoozeFailure: String?

    private func synchronized<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Installs the handler and hands back a URL that arrived before it existed, if there was one.
    func setHandler(_ newHandler: ((URL) -> Void)?) -> URL? {
        synchronized { () -> URL? in
            handler = newHandler
            guard newHandler != nil else { return nil }
            let pending = bufferedURL
            bufferedURL = nil
            return pending
        }
    }

    /// Returns the handler when one is installed, otherwise buffers the URL for whenever one is.
    func handlerOrBuffer(_ url: URL) -> ((URL) -> Void)? {
        synchronized { () -> ((URL) -> Void)? in
            if let handler = handler { return handler }
            bufferedURL = url
            return nil
        }
    }

    func takeBufferedURL() -> URL? {
        synchronized { () -> URL? in
            let pending = bufferedURL
            bufferedURL = nil
            return pending
        }
    }

    var currentSnoozeFailure: String? {
        synchronized { snoozeFailure }
    }

    func setSnoozeFailure(_ message: String?) {
        synchronized { snoozeFailure = message }
    }
}

/// The app's `UNUserNotificationCenterDelegate`.
///
/// # Presentation while the app is open
///
/// `willPresent` returns `[.banner, .sound]`, and CoreCredit deliberately shows **no in-app toast**
/// for the same notification. Two announcements of one fact is noise, and the banner is the one the
/// owner can act on from the Lock Screen as well.
///
/// # Actions can never move money
///
/// The registered actions are View Item, Scan Core, and Snooze 1 Day. The first two only open a
/// screen; the third only moves a local alert forward a day. **No action records a credit, changes
/// a status, or writes anything to the ledger** — a core's custody and its money are only ever
/// changed inside the app, through `CoreItemService`, where the change gets a timeline entry.
///
/// # Routing
///
/// A tapped notification produces a URL — `corecredit://item/<uuid>` or `corecredit://scan` — which
/// is handed to `onOpenURL`. This type does no routing of its own: the app shell owns
/// `DeepLinkRouter` and decides what a link means. A URL that arrives before the shell has set the
/// handler is buffered, so a tap that cold-launches the app is not lost; `takePendingURL()` drains
/// it.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {

    /// How far a snooze moves a reminder.
    static let snoozeInterval: TimeInterval = 24 * 60 * 60

    private let state = ResponderState()

    override init() {
        super.init()
    }

    // MARK: - Installation

    /// Builds the responder, registers the notification categories, and makes it the delegate.
    ///
    /// - Parameters:
    ///   - isEnabled: `false` under `-uiTesting`, where the recording scheduler stands in for the
    ///     notification centre and nothing should be registered with the real system. The responder
    ///     is still returned, so the caller never has to deal with an optional.
    ///   - onOpenURL: where a tapped reminder's deep link should go. Can be replaced later.
    ///
    /// `UNUserNotificationCenter.delegate` is a weak reference, so the caller must hold on to the
    /// returned object for the life of the process — `AppEnvironment` stores it in a `let`.
    @MainActor
    @discardableResult
    static func installed(isEnabled: Bool,
                          onOpenURL: ((URL) -> Void)? = nil) -> NotificationResponder {
        let responder = NotificationResponder()
        responder.onOpenURL = onOpenURL

        guard isEnabled else { return responder }

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(NotificationResponder.categories())
        center.delegate = responder
        return responder
    }

    /// The categories `UserNotificationScheduler` stamps onto its content.
    static func categories() -> Set<UNNotificationCategory> {
        let view = UNNotificationAction(
            identifier: ReminderNotificationAction.viewItem,
            title: "View Item",
            options: [.foreground]
        )
        let scan = UNNotificationAction(
            identifier: ReminderNotificationAction.scanCore,
            title: "Scan Core",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: ReminderNotificationAction.snoozeOneDay,
            title: "Snooze 1 Day",
            options: []
        )

        let itemReminder = UNNotificationCategory(
            identifier: ReminderNotificationCategory.itemReminder,
            actions: [view, scan, snooze],
            intentIdentifiers: [],
            options: []
        )

        // The weekly digest and the test alert are about no single core, so an item action would
        // have nothing to open. They keep the plain tap-to-open behaviour.
        let summary = UNNotificationCategory(
            identifier: ReminderNotificationCategory.summary,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        return [itemReminder, summary]
    }

    // MARK: - Routing

    /// Called with the deep link a tapped notification resolves to.
    ///
    /// Set this from the app shell, which passes the URL to `DeepLinkRouter`. Setting it also
    /// drains any URL that arrived earlier.
    var onOpenURL: ((URL) -> Void)? {
        didSet {
            guard let pending = state.setHandler(onOpenURL), let handler = onOpenURL else { return }
            handler(pending)
        }
    }

    /// A URL from a tap that arrived before `onOpenURL` was set, cleared as it is returned.
    /// The app shell can call this once it is ready, instead of relying on the setter's drain.
    func takePendingURL() -> URL? {
        state.takeBufferedURL()
    }

    /// Why the last snooze could not be re-queued, if it failed. `nil` after a successful snooze.
    var lastSnoozeFailure: String? {
        state.currentSnoozeFailure
    }

    // MARK: - UNUserNotificationCenterDelegate
    //
    // Both callbacks are written in their **completion-handler** form, not the `async` form Swift
    // also offers for them. The two are not equivalent, and the difference is a crash.
    //
    // An `async` delegate method is compiled into an `@objc` entry point that starts a task, runs
    // the body, and then calls UserNotifications' completion handler from wherever that task
    // happened to finish — the cooperative pool, not the main thread. UIKit does real work inside
    // that handler on the way in from a tap: it updates the window scene's snapshot and its
    // state-restoration archive, and that work asserts it is on the main thread. Build 38 died
    // there, 391ms into a launch from a tapped notification, in
    // `-[UIApplication _updateSnapshotAndStateRestorationWithAction:windowScene:]` on
    // `com.apple.root.user-initiated-qos.cooperative`.
    //
    // Owning the completion handler puts that back under this file's control: the work below and
    // the handler call that ends it both run on the main actor, whichever thread the notification
    // centre calls the delegate on. `verify_repository.py` fails the build if either method goes
    // back to the `async` spelling.

    /// Shows the banner and plays the sound even while CoreCredit is in the foreground.
    ///
    /// A shop leaves this app open on a counter iPad all day. Suppressing the banner would mean the
    /// reminder that fires at 8am is never seen. Nothing else in the app shows a toast for the same
    /// notification, so there is exactly one announcement per alert.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            completionHandler([.banner, .sound])
        }
    }

    /// Handles a tap or an action.
    ///
    /// Every branch either opens a screen or moves a local alert. None of them writes to the store.
    ///
    /// The route is read here, before the hop, so only a `String?` has to cross onto the main
    /// actor for the two branches that open a screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let action = response.actionIdentifier
        let itemRoute = route(in: request)

        Task { @MainActor in
            if action == ReminderNotificationAction.snoozeOneDay {
                await self.snooze(request)
            } else if action == ReminderNotificationAction.scanCore {
                self.deliver(ReminderRoute.scan)
            } else if action == ReminderNotificationAction.viewItem
                || action == UNNotificationDefaultActionIdentifier {
                self.deliver(itemRoute)
            }

            // `UNNotificationDismissActionIdentifier` and anything a future iOS adds fall straight
            // through to the completion handler: a dismissal is not a request to open anything.
            completionHandler()
        }
    }

    // MARK: - Private

    /// The route string the scheduler put in `userInfo`, if any.
    private func route(in request: UNNotificationRequest) -> String? {
        request.content.userInfo[ReminderUserInfoKey.route] as? String
    }

    /// Hands the URL to the app shell, or buffers it until a handler exists.
    ///
    /// Main-actor isolated so the handler — which ends up touching the router and, through it, the
    /// view tree — is only ever run there. The delegate callback hops onto the main actor before
    /// calling this, and only a `String?` crosses the boundary.
    @MainActor
    private func deliver(_ urlString: String?) {
        guard let urlString = urlString else { return }
        guard let url = URL(string: urlString) else { return }
        guard let handler = state.handlerOrBuffer(url) else { return }
        handler(url)
    }

    /// Re-queues the same reminder one day later, keeping its identifier so it replaces rather than
    /// stacks. Nothing about the core itself changes.
    private func snooze(_ request: UNNotificationRequest) async {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            state.setSnoozeFailure("The reminder could not be copied, so it was not snoozed.")
            return
        }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: NotificationResponder.snoozeInterval,
            repeats: false
        )
        let snoozed = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(snoozed)
            state.setSnoozeFailure(nil)
        } catch {
            // Recorded rather than swallowed: the next full refresh will re-plan this core anyway,
            // and `lastSnoozeFailure` is here so a failure is inspectable instead of invisible.
            state.setSnoozeFailure(error.localizedDescription)
        }
    }
}
