//
//  RootView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// Decides what the app shows: the store-unavailable screen, onboarding, or the tab bar.
///
/// The order of those three questions is deliberate.
///
/// 1. **Is there a store at all?** Without one there is no `ModelContext` in the environment, so
///    nothing that uses `@Query` may be constructed. `StoreUnavailableView` touches neither.
/// 2. **Has this shop been set up?** A first launch goes to onboarding.
/// 3. Otherwise the tab bar.
///
/// When a store *did* open but only as the in-memory fallback, a persistent banner sits above
/// whatever is showing and says plainly that this session is not being saved. That is the honest
/// surface for a fallback: the app still works, the owner can still log a core, and they are told
/// before they trust it with something they will need on Friday.
struct RootView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    /// A container opened by the retry button after `AppEnvironment` gave up. `AppEnvironment`
    /// holds its container as a `let`, so recovery is owned here instead.
    @State private var recoveredContainer: ModelContainer?

    /// Declared explicitly rather than relying on the synthesized memberwise initializer, whose
    /// access level would otherwise be tied to this view's `private` stored properties.
    init() { }

    var body: some View {
        content
            .tint(Palette.accent)
            .task {
                await appEnvironment.bootstrap()
            }
            .transaction { transaction in
                // UI tests must not race a transition.
                if appEnvironment.launchOptions.disableAnimations {
                    transaction.disablesAnimations = true
                }
            }
    }

    // MARK: - Branches

    @ViewBuilder
    private var content: some View {
        if let container = activeContainer {
            LoadedRootView()
                .modelContainer(container)
        } else {
            StoreUnavailableView(
                message: storeUnavailableMessage,
                onRetry: retryOpeningStore,
                onReset: resetLocalData
            )
        }
    }

    private var activeContainer: ModelContainer? {
        appEnvironment.container ?? recoveredContainer
    }

    private var storeUnavailableMessage: String {
        appEnvironment.storeLoadWarning ?? RootView.unknownFailureMessage
    }

    // MARK: - Recovery

    /// Tries to open the store again — the right first move after a full disk has been cleared,
    /// or after the device has finished a restore.
    private func retryOpeningStore() {
        let container = ModelContainerFactory.makeAppContainer(
            inMemory: appEnvironment.launchOptions.useInMemoryStore
        )
        recoveredContainer = container
        appEnvironment.storeLoadWarning = ModelContainerFactory.lastLoadFailureMessage
    }

    /// Deletes the unopenable store files and tries again.
    ///
    /// Destructive and unrecoverable, which is why `StoreUnavailableView` puts it behind a
    /// confirmation and says so in words. It is the last resort for a store so damaged that it
    /// cannot be read — and at that point the data is already gone; only the file is left.
    private func resetLocalData() {
        if ModelContainerFactory.destroyOnDiskStore() {
            retryOpeningStore()
        } else {
            // The factory records why the files could not be removed. Show that instead of
            // pretending the reset worked.
            appEnvironment.storeLoadWarning = ModelContainerFactory.lastLoadFailureMessage
        }
    }

    private static let unknownFailureMessage =
        "CoreCredit could not open the file it keeps your cores in, and did not report a reason."
}

// MARK: - Loaded root

/// The part of the root that needs a `ModelContext`.
///
/// Kept separate so its `@Query` is only ever created underneath a view that has a container.
private struct LoadedRootView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @Query(sort: \ShopProfile.createdAt, order: .forward) private var profiles: [ShopProfile]

    var body: some View {
        VStack(spacing: 0) {
            if let warning = appEnvironment.storeLoadWarning {
                ErrorBanner(message: LoadedRootView.notSavingMessage(reason: warning))
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
            }

            destination
        }
        .background(Palette.background)
    }

    @ViewBuilder
    private var destination: some View {
        if isOnboarded {
            MainTabView()
        } else {
            OnboardingView()
        }
    }

    /// `-uiTestSkipOnboarding` starts on the tab bar whatever the profile says, so a test that is
    /// not about onboarding never has to walk through it.
    private var isOnboarded: Bool {
        if appEnvironment.launchOptions.skipOnboarding {
            return true
        }
        return profiles.first?.hasCompletedOnboarding ?? false
    }

    /// Leads with the consequence, then the reason. An owner needs to know their work is not
    /// being kept before they need to know which file failed to open.
    private static func notSavingMessage(reason: String) -> String {
        "CoreCredit couldn't open its saved data, so anything you add now will be gone when you "
            + "close the app. " + reason
    }
}
