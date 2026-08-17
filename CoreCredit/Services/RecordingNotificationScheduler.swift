//
//  RecordingNotificationScheduler.swift
//  CoreCredit
//
//  Deterministic stand-in for the real notification centre. Never touches UserNotifications.
//

import Foundation

/// Mutable state for `RecordingNotificationScheduler`, isolated behind a lock.
///
/// Keeping the state in its own `@unchecked Sendable` box lets the scheduler itself hold a single
/// `let`, so its `Sendable` conformance (inherited from `NotificationScheduling`) is satisfied
/// structurally rather than by an unchecked escape hatch on the public type.
private final class RecorderState: @unchecked Sendable {

    private let lock = NSLock()

    private var status: NotificationAuthorizationStatus
    private var requests: [CoreReminderRequest] = []
    private var cancelledIDs: [UUID] = []
    private var cancelAllCount = 0
    private var authorizationRequestCount = 0

    init(status: NotificationAuthorizationStatus) {
        self.status = status
    }

    private func synchronized<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var currentStatus: NotificationAuthorizationStatus {
        synchronized { status }
    }

    var currentRequests: [CoreReminderRequest] {
        synchronized { requests }
    }

    var currentCancelledIDs: [UUID] {
        synchronized { cancelledIDs }
    }

    var currentCancelAllCount: Int {
        synchronized { cancelAllCount }
    }

    var currentAuthorizationRequestCount: Int {
        synchronized { authorizationRequestCount }
    }

    func setStatus(_ newStatus: NotificationAuthorizationStatus) {
        synchronized { status = newStatus }
    }

    /// Mirrors the system prompt: an undetermined app becomes whatever `grant` says, an app that
    /// already has an answer keeps it (iOS only ever prompts once).
    func recordAuthorizationRequest(grant: NotificationAuthorizationStatus) -> NotificationAuthorizationStatus {
        synchronized {
            authorizationRequestCount += 1
            if status == .notDetermined {
                status = grant
            }
            return status
        }
    }

    /// Replaces any request with the same identifier, exactly like `UNUserNotificationCenter.add`.
    func store(_ request: CoreReminderRequest) {
        synchronized {
            requests.removeAll { $0.identifier == request.identifier }
            requests.append(request)
        }
    }

    func remove(itemIDs: [UUID]) {
        synchronized {
            cancelledIDs.append(contentsOf: itemIDs)
            let targets = Set(itemIDs)
            requests.removeAll { targets.contains($0.itemID) }
        }
    }

    func removeAll() {
        synchronized {
            cancelAllCount += 1
            requests.removeAll()
        }
    }

    func reset() {
        synchronized {
            requests.removeAll()
            cancelledIDs.removeAll()
            cancelAllCount = 0
            authorizationRequestCount = 0
        }
    }
}

/// Records every call and performs nothing.
///
/// Used by unit tests (assert on `scheduledRequests`), by UI tests launched with
/// `-uiTesting` (no permission prompt ever appears), and by SwiftUI previews.
///
/// Behaviour deliberately mirrors the real scheduler in the ways tests care about:
/// scheduling with an existing identifier replaces the previous request, and scheduling while
/// unauthorised throws `NotificationSchedulingError.notAuthorized`.
final class RecordingNotificationScheduler: NotificationScheduling {

    private let state: RecorderState

    /// The status `requestAuthorization()` grants when the recorder starts out `.notDetermined`.
    private let grantedStatusOnRequest: NotificationAuthorizationStatus

    /// - Parameter status: the permission the recorder reports. Defaults to `.authorized` so the
    ///   common test path schedules successfully without any extra setup.
    init(status: NotificationAuthorizationStatus = .authorized) {
        self.state = RecorderState(status: status)
        self.grantedStatusOnRequest = .authorized
    }

    // MARK: - Inspection

    /// Every request currently "pending", in the order it was scheduled.
    var scheduledRequests: [CoreReminderRequest] {
        state.currentRequests
    }

    /// Every item id passed to `cancel(itemIDs:)`, in call order, duplicates included.
    var cancelledIDs: [UUID] {
        state.currentCancelledIDs
    }

    /// How many times `cancelAll()` was called.
    var cancelAllCount: Int {
        state.currentCancelAllCount
    }

    /// How many times `requestAuthorization()` was called. Guards the "never prompt at launch"
    /// rule: a UI test can assert this is still zero after the app finishes bootstrapping.
    var authorizationRequestCount: Int {
        state.currentAuthorizationRequestCount
    }

    /// The reminder currently pending for an item, if any.
    func scheduledRequest(for itemID: UUID) -> CoreReminderRequest? {
        state.currentRequests.first { $0.itemID == itemID }
    }

    /// Changes the reported permission, so a test can walk denied -> authorized.
    func setAuthorizationStatus(_ status: NotificationAuthorizationStatus) {
        state.setStatus(status)
    }

    /// Clears the recorded calls without changing the reported permission.
    func reset() {
        state.reset()
    }

    // MARK: - NotificationScheduling

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        state.currentStatus
    }

    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus {
        state.recordAuthorizationRequest(grant: grantedStatusOnRequest)
    }

    func schedule(_ request: CoreReminderRequest) async throws {
        guard state.currentStatus.allowsScheduling else {
            throw NotificationSchedulingError.notAuthorized
        }
        state.store(request)
    }

    func cancel(itemIDs: [UUID]) async {
        guard !itemIDs.isEmpty else { return }
        state.remove(itemIDs: itemIDs)
    }

    func cancelAll() async {
        state.removeAll()
    }

    func pendingIdentifiers() async -> [String] {
        state.currentRequests.map { $0.identifier }.sorted()
    }
}
