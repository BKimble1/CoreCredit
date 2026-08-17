//
//  AppEnvironment.swift
//  CoreCredit
//
//  The composition root: one object that owns every long-lived service and hands them to the
//  view tree through `.environment(_:)`.
//

import Foundation
import Observation
import SwiftData

/// The four top-level destinations, shared by the compact tab bar and the regular-width sidebar.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case cores
    case returns
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .cores: return "Cores"
        case .returns: return "Returns"
        case .settings: return "Settings"
        }
    }

    /// Fixed by the SF Symbol table in `docs/CONTRACTS.md` §9 so the icons never drift.
    var symbolName: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .cores: return "shippingbox.fill"
        case .returns: return "arrow.uturn.left"
        case .settings: return "gearshape"
        }
    }

    /// The automation identifier `CoreCreditUITests` queries for. Never spoken by VoiceOver.
    var accessibilityIdentifier: String {
        switch self {
        case .dashboard: return A11y.Tab.dashboard
        case .cores: return A11y.Tab.cores
        case .returns: return A11y.Tab.returns
        case .settings: return A11y.Tab.settings
        }
    }
}

/// Everything the app needs that outlives a single screen.
///
/// # Why this exists
///
/// Views must not decide which subscription engine, scheduler, or recogniser they are talking to.
/// That decision is made exactly once, here, from `LaunchOptions`: the real services on a normal
/// launch, and their deterministic counterparts under `-uiTesting`. A feature screen only ever
/// writes `appEnvironment.exports`, and it behaves identically in the App Store build and in a
/// UI test.
///
/// # Nothing is asked of the user at launch
///
/// `bootstrap()` reads the notification permission and never requests it. iOS presents the
/// permission prompt exactly once in the lifetime of an install, so spending it at launch —
/// before the owner has logged a single core or asked for a reminder — permanently costs the
/// feature. Reminders ask in context, from the notification settings screen or the moment the
/// owner switches reminders on. No camera or photo permission is requested here either.
///
/// # A missing store is a state, not a crash
///
/// `container` is optional because `ModelContainerFactory.makeAppContainer(inMemory:)` is allowed
/// to give up rather than trap. `nil` puts `RootView` into `StoreUnavailableView`; a non-`nil`
/// container paired with a non-`nil` `storeLoadWarning` means the app fell back to memory and the
/// owner is told, in a persistent banner, that this session is not being saved.
@MainActor
@Observable
final class AppEnvironment {

    // MARK: - Stored dependencies

    /// How this launch was configured. Read-only for the whole app.
    let launchOptions: LaunchOptions

    /// The injected clock and calendar. Every due date and aging bucket goes through it.
    let dateProvider: any DateProvider

    /// `nil` when the persistent store could not be opened at all.
    let container: ModelContainer?

    let subscriptions: SubscriptionController
    let reminders: ReminderCoordinator

    /// The `UNUserNotificationCenter` delegate: foreground presentation, the reminder actions, and
    /// the deep link a tapped reminder resolves to. Held here because the notification centre keeps
    /// only a weak reference to its delegate. Set `notifications.onOpenURL` from the app shell to
    /// hand tapped links to the router; nothing here requests permission.
    let notifications: NotificationResponder

    let exports: ExportCoordinator
    let textRecognizer: any TextRecognizing

    /// The local-only record of the most recent scanning session, shown on the Scanner Diagnostics
    /// screen. Nothing it holds is ever uploaded, and it stores no image bytes — see
    /// `ScanDiagnostics.swift`. It starts empty and stays empty until a scanner opens a session.
    let scanDiagnostics: ScanDiagnosticsRecorder

    /// Where an incoming `corecredit://` URL, a Shortcut, or the Action Button leaves its request.
    /// It only *records* the destination; `MainTabView` decides what that means and when, which is
    /// how a link that arrives before the tab bar exists survives a cold start.
    let deepLinks: DeepLinkRouter

    // MARK: - Observable state

    /// Why the requested store could not be opened, when a fallback store is in use. `nil` on a
    /// healthy launch.
    var storeLoadWarning: String?

    /// Set by a feature that wants the paywall shown from the app shell rather than from its own
    /// sheet — for example a Settings row. `MainTabView` presents and clears it.
    var pendingPaywallTrigger: PaywallTrigger?

    /// Guards `bootstrap()` against SwiftUI re-running the owning `.task`.
    @ObservationIgnored private var hasBootstrapped = false

    // MARK: - Init

    init(launchOptions: LaunchOptions) {
        self.launchOptions = launchOptions

        let clock = SystemDateProvider()
        self.dateProvider = clock

        // Bounded and non-throwing by contract: three attempts, then nil.
        self.container = ModelContainerFactory.makeAppContainer(inMemory: launchOptions.useInMemoryStore)

        // Read straight away, while it still describes the attempt above. Assigned to the
        // observable property at the end of init, once every stored property exists.
        let loadFailure = ModelContainerFactory.lastLoadFailureMessage

        // Subscriptions ------------------------------------------------------------------
        let engine: any SubscriptionEngine
        if launchOptions.isUITesting {
            engine = StubSubscriptionEngine(
                tier: launchOptions.forcedTier ?? .free,
                simulateLoadFailure: launchOptions.simulateStoreKitFailure
            )
        } else {
            engine = StoreKitSubscriptionEngine()
        }
        self.subscriptions = SubscriptionController(
            engine: engine,
            defaults: AppEnvironment.entitlementDefaults(for: launchOptions)
        )

        // Reminders ----------------------------------------------------------------------
        let scheduler: any NotificationScheduling
        if launchOptions.disableNotifications {
            // `-uiTestNotificationAuthorization denied` reaches the settings screen's denied and
            // not-determined branches, which are otherwise untestable: authorization cannot be
            // revoked from inside the process. Unset keeps the recorder's `.authorized` default.
            if let forced = launchOptions.notificationAuthorization {
                scheduler = RecordingNotificationScheduler(status: forced)
            } else {
                scheduler = RecordingNotificationScheduler()
            }
        } else {
            scheduler = UserNotificationScheduler()
        }
        self.reminders = ReminderCoordinator(scheduler: scheduler, dateProvider: clock)

        // Exports ------------------------------------------------------------------------
        self.exports = ExportCoordinator(dateProvider: clock)

        // Capture ------------------------------------------------------------------------
        if launchOptions.isUITesting {
            self.textRecognizer = StubTextRecognizer(
                lines: AppEnvironment.stubRecognizerLines(for: launchOptions),
                barcodes: AppEnvironment.stubRecognizerBarcodes(for: launchOptions)
            )
        } else {
            self.textRecognizer = VisionTextRecognizer()
        }

        // Diagnostics ---------------------------------------------------------------------
        // In memory, on this device, for the owner to read. No permission, no file, no network.
        self.scanDiagnostics = ScanDiagnosticsRecorder(dateProvider: clock)

        // Deep links -----------------------------------------------------------------------
        // Nothing is navigated by constructing this; it is an empty mailbox until a URL or an
        // `AppIntent` puts something in it. Constructed unconditionally, because a bin-tag QR code
        // and the Quick Scan widget work the same way in a UI test as they do on a counter.
        self.deepLinks = DeepLinkRouter()

        // A UI test can hand a link in at launch (`-uiTestDeepLink corecredit://scan`). This is the
        // cold-start path — the URL arrives before the shell exists and waits in the router until
        // `MainTabView` consumes it — which is the case worth testing and the awkward one to reach
        // otherwise, since XCUITest cannot open a custom scheme without driving Safari.
        // Gated on `isUITesting`, so a stray argument can never steer a shipping build.
        if launchOptions.isUITesting,
           let raw = launchOptions.deepLink,
           let url = URL(string: raw) {
            _ = self.deepLinks.handle(url)
        }

        // Notifications ----------------------------------------------------------------------
        // Registers the reminder categories and becomes the notification centre's delegate. It
        // asks for no permission: a tapped reminder hands its `corecredit://` link to the same
        // router a bin-tag QR code uses, through the registry, so the notification layer stays
        // ignorant of the view tree.
        self.notifications = NotificationResponder.installed(
            isEnabled: !launchOptions.disableNotifications,
            onOpenURL: { url in _ = DeepLinkRouterRegistry.current?.handle(url) }
        )

        self.storeLoadWarning = loadFailure
    }

    // MARK: - Bootstrap

    /// Brings the app up. Safe to call more than once; only the first call does any work.
    ///
    /// Deliberately in this order: the fixture lands before anything awaits, so a UI test never
    /// sees an empty first frame; the store answers next; the notification permission is *read*;
    /// and stale export files are swept last, off the main actor.
    func bootstrap() async {
        guard hasBootstrapped == false else { return }
        hasBootstrapped = true

        applySeedScenario()

        await subscriptions.start()

        // Reads the permission. Never prompts — see the type documentation.
        await reminders.refreshAuthorization()

        // Pure file housekeeping with no captured state, so it is free to run off the main actor.
        await Task.detached(priority: .utility) {
            ExportFileStore.cleanUpOldExports()
        }.value
    }

    // MARK: - Services

    /// Builds the item service against the caller's context, so a sheet with its own context
    /// still writes through the audited mutation path.
    func itemService(_ context: ModelContext) -> CoreItemService {
        CoreItemService(context: context, dateProvider: dateProvider)
    }

    func batchService(_ context: ModelContext) -> ReturnBatchService {
        ReturnBatchService(context: context, dateProvider: dateProvider)
    }

    // MARK: - Seeding

    /// Inserts the requested fixture.
    ///
    /// Gated on `useInMemoryStore` as well as the scenario, so a stray `-uiTestSeed` on a normal
    /// launch can never write demonstration cores into a real shop's ledger.
    ///
    /// Failures are deliberately not surfaced: this path is unreachable outside `-uiTesting`, and
    /// a UI test that does not get its fixture fails on its own assertions — which is the signal
    /// that actually says what went wrong. Showing a store-failure banner instead would be a lie.
    private func applySeedScenario() {
        guard launchOptions.useInMemoryStore, let container = container else { return }

        let context = container.mainContext
        let now = dateProvider.now

        switch launchOptions.seedScenario {
        case .none:
            break
        case .empty:
            markProfileOnboarded(in: context, now: now, fallbackName: "Test Shop")
        case .fiveUnresolved:
            ModelContainerFactory.seedSampleData(in: context, now: now)
        case .walkthrough:
            ModelContainerFactory.seedAcceptanceWalkthrough(in: context, now: now)
        }

        if launchOptions.skipOnboarding {
            markProfileOnboarded(in: context, now: now, fallbackName: "Test Shop")
        }
    }

    /// Finds or creates the single shop profile and marks it onboarded, so the run starts on the
    /// tab bar instead of the onboarding flow.
    private func markProfileOnboarded(in context: ModelContext, now: Date, fallbackName: String) {
        let descriptor = FetchDescriptor<ShopProfile>(
            sortBy: [SortDescriptor(\ShopProfile.createdAt, order: .forward)]
        )
        let existing = (try? context.fetch(descriptor)) ?? []

        let profile: ShopProfile
        if let first = existing.first {
            profile = first
        } else {
            let created = ShopProfile(name: fallbackName, now: now)
            context.insert(created)
            profile = created
        }

        profile.hasCompletedOnboarding = true
        profile.touch(now)
        try? context.save()
    }

    // MARK: - Deterministic test doubles

    /// A throwaway defaults suite for UI tests.
    ///
    /// The controller seeds itself from the cached entitlement before the engine answers. On a
    /// shared simulator that cache survives between runs, so a `-uiTestTier free` run could open
    /// showing Pro for a frame. A wiped suite makes the stub engine the only source of truth.
    private static func entitlementDefaults(for launchOptions: LaunchOptions) -> UserDefaults {
        guard launchOptions.isUITesting else { return .standard }

        let suiteName = AppConfiguration.bundleIdentifier + ".uitesting"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }

        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// The invoice the stub recogniser "reads".
    ///
    /// TEST VALUES ONLY. Chosen to match `seedAcceptanceWalkthrough`, so the OCR review sheet
    /// suggests the same alternator, invoice, repair order, and core charge the walkthrough
    /// script already asserts on. A supplied scanner payload is offered first, because that is
    /// the value the test asked to see.
    private static func stubRecognizerLines(for launchOptions: LaunchOptions) -> [String] {
        var lines: [String] = []
        if let payload = launchOptions.stubScannerPayload {
            lines.append(payload)
        }
        lines.append(contentsOf: [
            "NAPA AUTO PARTS",
            "INVOICE #INV-552",
            "RO 1024",
            "ALTERNATOR 03-1887",
            "CORE CHARGE 86.50"
        ])
        return lines
    }

    private static func stubRecognizerBarcodes(for launchOptions: LaunchOptions) -> [String] {
        guard let payload = launchOptions.stubScannerPayload else { return [] }
        return [payload]
    }
}
