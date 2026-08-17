//
//  DeepLinkRouter.swift
//  CoreCredit
//

import Foundation
import Observation

/// Remembers where something outside the app asked to go, until the app is ready to go there.
///
/// # Why a link has to be *held*
///
/// On a cold start the URL arrives before there is a tab bar to switch or a sheet to present:
/// `onOpenURL` can fire while `RootView` is still deciding between the store-failure screen,
/// onboarding, and the shell. A router that tried to navigate on arrival would be navigating a
/// screen that does not exist yet, so this one only *records* the request. `MainTabView` consumes
/// it the moment it is on screen — which, for a shop that has not finished onboarding, may be
/// several taps later. That is the intended behaviour: the link waits rather than being dropped.
///
/// # It does not navigate
///
/// Nothing here knows about tabs, sheets, or SwiftData. One value in, one value out, and the shell
/// decides what that means. That keeps the "did the URL parse?" question separable from the "what
/// did the app do about it?" question.
@MainActor
@Observable
final class DeepLinkRouter {

    /// The link waiting to be acted on, or `nil` when there is nothing outstanding.
    ///
    /// `private(set)` because the only legal ways in are `handle(_:)` and the only ways out are
    /// `consume()` and `clear()` — a caller that could assign this directly could also silently
    /// overwrite a link the shell was about to read.
    private(set) var pending: DeepLink?

    init() {
        DeepLinkRouterRegistry.register(self)
    }

    /// Records an incoming URL.
    ///
    /// - Returns: `true` when the URL was one of this app's links and has been recorded, `false`
    ///   when it was not understood. A `false` leaves any link already pending untouched: a
    ///   passing barcode must never wipe out a request the shell has not read yet.
    func handle(_ url: URL) -> Bool {
        guard let link = DeepLink.parse(url) else { return false }
        handle(link)
        return true
    }

    /// Records an already-parsed link. This is the path an `AppIntent` takes, since a Shortcut
    /// carries an intention rather than a URL.
    ///
    /// A newer link replaces an older one on purpose: two requests arriving before the shell reads
    /// either means the second tap is the one the user is waiting on.
    func handle(_ link: DeepLink) {
        pending = link
    }

    /// Takes the pending link and clears it, so it is acted on exactly once.
    func consume() -> DeepLink? {
        guard let link = pending else { return nil }
        pending = nil
        return link
    }

    /// Drops the pending link without acting on it — what the shell does when a link names a core
    /// that is no longer in the ledger.
    func clear() {
        pending = nil
    }
}

/// Where the running app's `DeepLinkRouter` publishes itself for the code that cannot reach the
/// SwiftUI environment.
///
/// An `AppIntent` is instantiated by the system, not by the view tree: it has no
/// `@Environment(AppEnvironment.self)` to read, so it needs some other way to the one router the
/// app is using. This is that way, and it is deliberately as small as it can be — a weak reference
/// and a single held link.
///
/// # The held link is the point
///
/// `openAppWhenRun` launches the app and *then* runs `perform()`, so on a cold start the intent can
/// beat `AppEnvironment.init` to the punch. `deliver(_:)` therefore keeps the link when no router
/// exists yet, and `register(_:)` hands it over the instant one does. Without that, the first
/// "Scan a Core" after a reboot would open the app and do nothing.
///
/// Nothing here is shared between processes: no App Group, no shared container, no file. It is one
/// reference inside one running app.
@MainActor
enum DeepLinkRouterRegistry {

    /// The router belonging to the live `AppEnvironment`. Weak, so this never keeps a dead
    /// environment alive.
    private(set) static weak var current: DeepLinkRouter?

    /// A link that arrived before there was a router to give it to.
    private static var deferredLink: DeepLink?

    /// Called by `DeepLinkRouter.init`. Any link that arrived early is handed over immediately.
    static func register(_ router: DeepLinkRouter) {
        current = router
        guard let link = deferredLink else { return }
        deferredLink = nil
        router.handle(link)
    }

    /// Hands a link to the running router, or holds it until one registers.
    static func deliver(_ link: DeepLink) {
        guard let router = current else {
            deferredLink = link
            return
        }
        router.handle(link)
    }
}
