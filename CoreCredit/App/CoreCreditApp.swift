//
//  CoreCreditApp.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The app entry point.
///
/// It does five things and nothing else: build the `AppEnvironment` from the launch arguments, put
/// it in the SwiftUI environment, attach the SwiftData container when there is one, hand any
/// incoming `corecredit://` URL to the deep-link router, and hold the load-in screen over the
/// whole thing until the first frame is ready to be looked at. Every decision about *what to show*
/// belongs to `RootView`, and every decision about what a link *means* belongs to `MainTabView`.
///
/// # The load-in screen
///
/// `LaunchSplashHost` is an overlay, so the app is built and laid out underneath it from the first
/// moment and nothing waits on it — including a deep link, which `MainTabView` consumes on appear
/// behind the splash exactly as it would have without one. It is skipped entirely under
/// `-uiTesting`. See `LaunchSplashView.swift` for how it hands over from the static launch screen.
@main
struct CoreCreditApp: App {

    /// Owned here so it survives every view update for the life of the process.
    @State private var appEnvironment = AppEnvironment(launchOptions: LaunchOptions.parse())

    /// Whether the load-in screen should be on screen right now.
    ///
    /// Read live rather than decided once: a real cold-start `corecredit://` URL arrives through
    /// `onOpenURL` *after* this scene exists, and somebody who tapped the Quick Scan widget wants
    /// a viewfinder rather than a logo. `LaunchSplashHost` latches the answer once it turns false,
    /// so consuming the link cannot bring the splash back.
    private var showsLaunchSplash: Bool {
        appEnvironment.launchOptions.disableAnimations == false
            && appEnvironment.deepLinks.pending == nil
    }

    var body: some Scene {
        WindowGroup {
            LaunchSplashHost(isEnabled: showsLaunchSplash) {
                RootView()
            }
            .environment(appEnvironment)
            .modelContainerIfAvailable(appEnvironment.container)
            // Recorded, never acted on here. On a cold start this fires while `RootView` is still
            // choosing between the store-failure screen, onboarding, and the shell, so the router
            // holds the link and `MainTabView` consumes it once there is somewhere to go — behind
            // the load-in screen, which delays nothing. A URL this app does not understand is
            // ignored, which is what the discarded `Bool` says.
            .onOpenURL { url in
                _ = appEnvironment.deepLinks.handle(url)
            }
        }
    }
}

private extension View {

    /// Attaches the SwiftData container only when one could be opened.
    ///
    /// `.modelContainer(_:)` takes a non-optional container, and there is no "empty" container to
    /// pass: when the store cannot be opened at all, the right answer is to install nothing and
    /// let `RootView` render `StoreUnavailableView`, which touches no `@Query` and no
    /// `ModelContext`.
    @ViewBuilder
    func modelContainerIfAvailable(_ container: ModelContainer?) -> some View {
        if let container = container {
            self.modelContainer(container)
        } else {
            self
        }
    }
}
