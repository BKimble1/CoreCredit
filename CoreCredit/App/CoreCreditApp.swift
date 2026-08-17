//
//  CoreCreditApp.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The app entry point.
///
/// It does three things and nothing else: build the `AppEnvironment` from the launch arguments,
/// put it in the SwiftUI environment, and attach the SwiftData container when there is one.
/// Every decision about *what to show* belongs to `RootView`.
@main
struct CoreCreditApp: App {

    /// Owned here so it survives every view update for the life of the process.
    @State private var appEnvironment = AppEnvironment(launchOptions: LaunchOptions.parse())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
                .modelContainerIfAvailable(appEnvironment.container)
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
