//
//  MainTabView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The four-destination shell: a tab bar on iPhone, a sidebar on iPad.
///
/// # Why the layout is switched rather than adapted
///
/// A tab bar on a full-width iPad puts four items in the middle of a very wide strip and wastes
/// the space where the ledger should be. `NavigationSplitView` keeps the destinations visible on
/// the left and gives the cores list the rest of the screen, which is how this app is actually
/// used on a counter iPad. The two layouts share one `selectedTab`, so switching orientation or
/// resizing a Split View window keeps the owner where they were.
///
/// # Navigation state
///
/// In the compact layout each tab owns a `NavigationStack`, so drilling into a core on the Cores
/// tab and switching to Returns and back returns to that core. In the regular layout the detail
/// column carries one stack, keyed by the selected destination, so switching destinations never
/// leaves a screen from the previous one on top.
///
/// Cores is the only destination anything outside the app can name — a bin tag's QR code says
/// "open *this* core" — so it is the only one carrying a programmatic destination. Both layouts
/// read the same `deepLinkedCore`, so a link followed on an iPhone and on a counter iPad lands on
/// the same screen.
///
/// # Adding a core
///
/// There is still no "Add core" button here. The free-tier limit is checked before the editor
/// opens, and that check already lives on the Dashboard and the Cores list; duplicating it in the
/// shell would be a second place for the paywall rule to drift out of step with the first.
///
/// The shell *does* open the editor for a quick scan arriving from outside the app — a widget, a
/// Shortcut, the Action Button — and that path deliberately skips the pre-check. See
/// `DashboardModel.beginQuickScan()` for why, and note that it changes nothing about the limit
/// itself: `CoreEditorModel.save` asks `EntitlementPolicy` the same question before a record is
/// written, so a free shop at its limit gets the paywall at the moment it would have saved.
///
/// # Deep links
///
/// `AppEnvironment.deepLinks` records where an incoming link wants to go; this view is the only
/// thing that acts on it. It consumes on appear *and* on change, which is what covers both cases:
/// a cold start, where the URL arrived long before there was a tab bar, and a running app, where
/// it arrives while the owner is looking at something else.
///
/// # Reminders
///
/// This is also the one place the reminder queue is rebuilt for the app as a whole — once when the
/// shell appears, and again whenever the scene becomes active. Every *other* rebuild is a
/// consequence of a write, and `CoreItemService` already announces those through
/// `CoreItemChangeRelay`. What that write-path hook cannot see is time passing and the world moving
/// on underneath a suspended app: a device that sat in a drawer over the weekend, a queue iOS
/// discarded, a reminder that fired while the app was closed. Asking `ReminderCoordinator` to
/// re-read the ledger on the way back in is what keeps the queue honest, and no feature screen has
/// to know that.
struct MainTabView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: AppTab = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The core a deep link asked for, while its detail screen is on top of the ledger.
    ///
    /// Deliberately an optional driving `navigationDestination(item:)` rather than a bound
    /// `NavigationStack(path:)`. The Cores stack already contains view-based `NavigationLink`s —
    /// every row in `CoreListView` is one — and those are the links Apple asks you *not* to mix
    /// with a bound path. This form pushes programmatically without taking ownership of the stack,
    /// so tapping a row behaves exactly as it did before this file learned about deep links.
    @State private var deepLinkedCore: CoreItem?

    /// Routing for the one modal the shell opens by itself. Reuses `DashboardModel` rather than
    /// inventing a parallel enum: `Route.scanCore` already means "the create editor with the
    /// scanner in front of it", and there must be exactly one answer to what that looks like.
    @State private var quickScan = DashboardModel()

    init() { }

    var body: some View {
        ShellSheetHost(model: quickScan) {
            Group {
                if horizontalSizeClass == .regular {
                    splitLayout
                } else {
                    tabLayout
                }
            }
            .sheet(item: paywallBinding) { trigger in
                PaywallView(trigger: trigger)
            }
        }
        .onAppear {
            consumePendingDeepLink()
        }
        .onChange(of: appEnvironment.deepLinks.pending) { _, _ in
            consumePendingDeepLink()
        }
        .task {
            await refreshReminders()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Only `.active`. `.inactive` is the state during an app-switcher swipe and a
            // notification pull-down, and rebuilding the queue every time the owner glances at
            // Control Centre would be work nobody asked for.
            guard newPhase == .active else { return }
            Task { await refreshReminders() }
        }
    }

    // MARK: - Reminders

    /// Rebuilds the whole reminder queue from what is in the store right now.
    ///
    /// `refreshFromStore(_:)` is `async` and main-actor isolated, so both call sites reach it from
    /// a task rather than inline. It is safe to run more than once — it cancels everything and
    /// re-plans from scratch, and every request identifier is derived from the item and the kind
    /// (`CoreReminderRequest.identifier`), so a repeat pass replaces the same alerts instead of
    /// stacking duplicates. A launch where `.task` and the first `.active` transition both fire
    /// therefore costs a little work and changes nothing about what is queued.
    ///
    /// Nothing here asks for permission: `refreshFromStore` only reads and schedules, and a device
    /// that has refused notifications simply records the refusal in `ReminderCoordinator.lastError`
    /// for the notification settings screen to show.
    @MainActor
    private func refreshReminders() async {
        await appEnvironment.reminders.refreshFromStore(modelContext)
    }

    /// The shell presents `AppEnvironment.pendingPaywallTrigger` so a screen without its own
    /// sheet — a Settings row, say — can ask for the paywall. Feature screens that already own a
    /// paywall sheet keep using theirs; this never fires for them.
    private var paywallBinding: Binding<PaywallTrigger?> {
        Binding(
            get: { appEnvironment.pendingPaywallTrigger },
            set: { newValue in appEnvironment.pendingPaywallTrigger = newValue }
        )
    }

    // MARK: - Deep links

    /// Takes whatever the router is holding and acts on it, once.
    ///
    /// Safe to call repeatedly and from both `onAppear` and `onChange`: `consume()` clears the
    /// link as it hands it over, so the second caller gets `nil` and does nothing.
    private func consumePendingDeepLink() {
        guard let link = appEnvironment.deepLinks.consume() else { return }

        switch link {
        case .scan:
            // The Cores tab rather than the Dashboard: this link ends in a new record, and the
            // ledger is where the owner will look for it once the editor closes.
            selectedTab = .cores
            quickScan.beginQuickScan()

        case .item(let identifier):
            // A bin tag can outlive the core it was printed for — the part went back, the record
            // was deleted, the phone was restored from a backup. A link to a core that is not
            // there any more does nothing at all rather than dumping the owner on an empty screen
            // they did not ask for; the ledger they were already looking at is the honest answer.
            guard let item = coreItem(with: identifier) else { return }
            selectedTab = .cores
            deepLinkedCore = item
        }
    }

    /// The core carrying `identifier`, or `nil` when the ledger has no such record.
    ///
    /// `target` is a plain local on purpose: a `#Predicate` is compiled into a store query, so it
    /// can compare against a captured value but cannot call a function or read a computed
    /// property. `fetchLimit` is 1 because `CoreItem.id` identifies exactly one record.
    private func coreItem(with identifier: UUID) -> CoreItem? {
        let target = identifier
        var descriptor = FetchDescriptor<CoreItem>(
            predicate: #Predicate<CoreItem> { item in item.id == target }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Compact: tab bar

    private var tabLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label(AppTab.dashboard.title, systemImage: AppTab.dashboard.symbolName)
            }
            .tag(AppTab.dashboard)
            .accessibilityIdentifier(AppTab.dashboard.accessibilityIdentifier)

            NavigationStack {
                CoreListView()
                    .navigationDestination(item: $deepLinkedCore) { item in
                        CoreDetailView(item: item)
                    }
            }
            .tabItem {
                Label(AppTab.cores.title, systemImage: AppTab.cores.symbolName)
            }
            .tag(AppTab.cores)
            .accessibilityIdentifier(AppTab.cores.accessibilityIdentifier)

            NavigationStack {
                ReturnsView()
            }
            .tabItem {
                Label(AppTab.returns.title, systemImage: AppTab.returns.symbolName)
            }
            .tag(AppTab.returns)
            .accessibilityIdentifier(AppTab.returns.accessibilityIdentifier)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(AppTab.settings.title, systemImage: AppTab.settings.symbolName)
            }
            .tag(AppTab.settings)
            .accessibilityIdentifier(AppTab.settings.accessibilityIdentifier)
        }
    }

    // MARK: - Regular: sidebar

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                ForEach(AppTab.allCases) { tab in
                    NavigationLink(value: tab) {
                        Label(tab.title, systemImage: tab.symbolName)
                            .font(Typography.rowTitle)
                            .frame(minHeight: Spacing.minimumTapTarget, alignment: .leading)
                    }
                    .accessibilityIdentifier(tab.accessibilityIdentifier)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(AppConfiguration.displayName)
        } detail: {
            NavigationStack {
                destination(for: selectedTab)
                    .navigationDestination(item: deepLinkedCoreBinding) { item in
                        CoreDetailView(item: item)
                    }
            }
            // A fresh stack per destination: Returns must never open on top of a core detail.
            .id(selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The sidebar's selection is optional — deselecting is possible — but the detail column
    /// always shows something, so a `nil` selection is ignored rather than blanking the screen.
    private var sidebarSelection: Binding<AppTab?> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if let newValue = newValue {
                    selectedTab = newValue
                }
            }
        )
    }

    /// `deepLinkedCore`, but only while Cores is the selected destination.
    ///
    /// The regular layout has one detail stack shared by all four destinations. Handing it the
    /// deep-linked core unconditionally would open a core detail on top of Returns the moment the
    /// owner switched destinations, so every other destination sees `nil` and cannot write back.
    private var deepLinkedCoreBinding: Binding<CoreItem?> {
        Binding(
            get: { selectedTab == .cores ? deepLinkedCore : nil },
            set: { newValue in
                guard selectedTab == .cores else { return }
                deepLinkedCore = newValue
            }
        )
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard:
            DashboardView()
        case .cores:
            CoreListView()
        case .returns:
            ReturnsView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Shell sheet

/// Hosts the one modal the app shell opens by itself, in response to a deep link, a Shortcut, or
/// the Action Button.
///
/// # Why this is a view of its own
///
/// `MainTabView` already carries a `.sheet` for the paywall, and two `.sheet` modifiers in the
/// same chain can shadow one another — only one of them would ever present, and which one is not
/// something to find out on a shop floor. So the shell's second presentation hangs from a view
/// that owns nothing else, exactly as each feature screen keeps its own single route enum.
///
/// # It presents the ordinary editor
///
/// `DashboardModel.Route` is reused rather than copied: `.scanCore` is *the* definition of "the
/// create editor with the scanner already in front of it", and there is one editor and one
/// scanner in this app. Cancelling the camera therefore lands on the draft form, not on nothing,
/// because the scanner was always a sheet over that form.
@MainActor
private struct ShellSheetHost<Content: View>: View {

    private let model: DashboardModel
    private let content: Content

    init(model: DashboardModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content
            .sheet(item: routeBinding) { route in
                sheetContent(for: route)
                    // One identifier for "something outside the app brought this to the front",
                    // whichever screen answered, so a UI test has a single thing to wait on.
                    .accessibilityIdentifier(A11y.Root.deepLinkTarget)
            }
    }

    @ViewBuilder
    private func sheetContent(for route: DashboardModel.Route) -> some View {
        switch route {
        case .editor:
            NavigationStack {
                CoreEditorView(mode: .create)
            }
        case .scanCore:
            NavigationStack {
                CoreEditorView(mode: .create, initialRoute: .scan)
            }
        case .paywall(let trigger):
            PaywallView(trigger: trigger)
        }
    }

    /// Written out rather than taken from a `@Bindable`, matching how every other screen in this
    /// app drives its single `.sheet(item:)`. Clearing it on dismissal is what lets the next quick
    /// scan present a fresh draft.
    private var routeBinding: Binding<DashboardModel.Route?> {
        Binding(
            get: { model.route },
            set: { newValue in model.route = newValue }
        )
    }
}
