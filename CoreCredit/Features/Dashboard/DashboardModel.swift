//
//  DashboardModel.swift
//  CoreCredit
//

import Foundation
import Observation

/// View state and derived figures for `DashboardView`.
///
/// The model owns nothing persistent. The item list arrives from the view's `@Query`, and every
/// number on the screen is derived here by handing that list to `RiskCalculator` — the dashboard
/// never adds up money itself. The clock arrives as a `DateProvider` for the same reason: an
/// injected clock is the only way "overdue" means the same thing in the app, in a unit test, and in
/// a UI test running against a seeded store.
@MainActor
@Observable
final class DashboardModel {

    /// How many urgent cores are listed inline before the "See all" row takes over. Kept small on
    /// purpose: the dashboard is a summary, and a long list here would bury the total above it.
    ///
    /// `nonisolated` because it is used as a default argument of `urgentItems(from:dateProvider:limit:)`,
    /// and default arguments are evaluated in the caller's context rather than the callee's. Under
    /// the Swift 6 language mode reading a main-actor-isolated static from there is an error, not a
    /// warning. An immutable `Int` is safe to read from anywhere.
    nonisolated static let urgentItemLimit = 5

    /// The modal the dashboard currently has open. `nil` means the dashboard itself is in front.
    ///
    /// One enum, presented by a single `.sheet(item:)`, rather than a flag plus an optional: two
    /// `.sheet` modifiers attached to the *same* view can shadow one another, so only one of them
    /// would ever present. Each case carries its own `id`, so swapping between them re-presents.
    enum Route: Identifiable {

        /// `CoreEditorView(mode: .create)`.
        case editor

        /// The same editor, opened straight into the scanner. Deliberately *not* a second screen:
        /// it is one intake form with a capture sheet already in front of it, so cancelling the
        /// camera leaves the user on the form rather than nowhere.
        case scanCore

        /// Shown *instead of* the editor when the free tier blocks another open core.
        case paywall(PaywallTrigger)

        var id: String {
            switch self {
            case .editor:
                return "editor"
            case .scanCore:
                return "scanCore"
            case .paywall(let trigger):
                return "paywall." + trigger.id
            }
        }
    }

    /// Which sheet is presented, if any.
    var route: Route?

    /// Surfaced in an `ErrorBanner` at the top of the screen.
    var errorMessage: String?

    init() { }

    // MARK: - Derived figures

    /// The single roll-up every figure on the dashboard is read from.
    func summary(for items: [CoreItem], dateProvider: any DateProvider) -> RiskSummary {
        RiskCalculator.summarize(items, now: dateProvider.now, calendar: dateProvider.calendar)
    }

    /// The cores that most deserve a tap right now.
    ///
    /// Overdue items come first, oldest deadline first. If there are fewer overdue items than the
    /// limit, the list is topped up with the open cores whose deadlines land soonest, so the
    /// section is still useful on a healthy ledger. Both passes go through `CoreItemQuery`, so the
    /// matching rules are identical to the ones the Cores screen uses.
    func urgentItems(from items: [CoreItem],
                     dateProvider: any DateProvider,
                     limit: Int = DashboardModel.urgentItemLimit) -> [CoreItem] {
        guard limit > 0 else { return [] }

        let now = dateProvider.now
        let calendar = dateProvider.calendar

        let overdue = CoreItemQuery.filterAndSort(
            items,
            filter: CoreItemFilter(onlyOverdue: true),
            sort: .dueDateAscending,
            now: now,
            calendar: calendar
        )
        if overdue.count >= limit {
            return Array(overdue.prefix(limit))
        }

        let open = CoreItemQuery.filterAndSort(
            items,
            filter: CoreItemFilter(statuses: Set(CoreStatus.unresolvedCases)),
            sort: .dueDateAscending,
            now: now,
            calendar: calendar
        )

        var result = overdue
        var seen = Set(overdue.map { $0.id })
        for item in open where result.count < limit {
            if seen.contains(item.id) { continue }
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }

    // MARK: - Actions

    /// Free tier check before opening the editor.
    ///
    /// The limit counts **unresolved** items only, so settling a core frees a slot, and nothing
    /// already logged is ever hidden or locked — see `EntitlementPolicy`.
    func requestAddCore(items: [CoreItem], tier: SubscriptionTier) {
        route = blockingRoute(items: items, tier: tier) ?? .editor
    }

    /// The same check, for the scanner shortcut.
    ///
    /// Scanning is a faster way into the *same* new record, so it is gated by exactly the same
    /// limit. Letting the camera route around the paywall would make the limit meaningless.
    func requestScanCore(items: [CoreItem], tier: SubscriptionTier) {
        route = blockingRoute(items: items, tier: tier) ?? .scanCore
    }

    /// Quick scan from a widget, a Shortcut, or the Action Button.
    ///
    /// Deliberately does **not** pre-gate on the paywall: a technician who taps "Scan a Core"
    /// should get a viewfinder, not a purchase screen. `CoreEditorModel.save` still runs the
    /// free-limit check before anything is written, so the limit is enforced where it matters.
    ///
    /// The difference from `requestScanCore(items:tier:)` above is the difference between the two
    /// journeys, not a hole in the rule. Tapping "Scan core" *inside* the app is a decision already
    /// made in front of the ledger, and answering it with the paywall costs nothing. Raising a
    /// phone at a parts counter is a reflex; answering *that* with a purchase screen loses the
    /// scan, the counter, and the customer's patience. Either way the record cannot be saved past
    /// the free limit, because `save` asks the same `EntitlementPolicy` question again.
    ///
    /// Idempotent: `.scanCore` carries a fixed `Route.id`, so a second quick scan while the editor
    /// is already open re-presents nothing and leaves the unsaved draft exactly as it was.
    func beginQuickScan() {
        route = .scanCore
    }

    /// The paywall route when the free limit blocks another open core, `nil` when it does not.
    private func blockingRoute(items: [CoreItem], tier: SubscriptionTier) -> Route? {
        let unresolved = RiskCalculator.unresolvedCount(items)
        guard let trigger = EntitlementPolicy.blockingTrigger(unresolvedCount: unresolved,
                                                              tier: tier) else {
            return nil
        }
        return .paywall(trigger)
    }

    // MARK: - Errors

    /// Turns any thrown error into one sentence the owner can act on.
    func present(_ error: any Error) {
        errorMessage = DashboardModel.message(for: error)
    }

    func clearError() {
        errorMessage = nil
    }

    /// `DomainError` already writes shop-floor English and pairs it with a recovery suggestion, so
    /// both halves are shown. Anything else falls back to its localized description rather than
    /// being swallowed.
    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
                return description + " " + suggestion
            }
            return description
        }
        return error.localizedDescription
    }
}
