//
//  CoreCreditApp.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The app entry point.
///
/// It does four things and nothing else: build the `AppEnvironment` from the launch arguments,
/// put it in the SwiftUI environment, attach the SwiftData container when there is one, and hand
/// any incoming `corecredit://` URL to the deep-link router. Every decision about *what to show*
/// belongs to `RootView`, and every decision about what a link *means* belongs to `MainTabView`.
@main
struct CoreCreditApp: App {

    /// Owned here so it survives every view update for the life of the process.
    @State private var appEnvironment = AppEnvironment(launchOptions: LaunchOptions.parse())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
                .modelContainerIfAvailable(appEnvironment.container)
                // Recorded, never acted on here. On a cold start this fires while `RootView` is
                // still choosing between the store-failure screen, onboarding, and the shell, so
                // the router holds the link and `MainTabView` consumes it once there is somewhere
                // to go. A URL this app does not understand is ignored, which is what the
                // discarded `Bool` says.
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
