//
//  MainTabView.swift
//  CoreCredit
//

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
/// # Adding a core
///
/// There is no "Add core" button here on purpose. The free-tier limit is checked before the
/// editor opens, and that check already lives on the Dashboard and the Cores list. Duplicating it
/// in the shell would be a second place for the paywall rule to drift out of step with the first.
struct MainTabView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab: AppTab = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init() { }

    var body: some View {
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

    /// The shell presents `AppEnvironment.pendingPaywallTrigger` so a screen without its own
    /// sheet — a Settings row, say — can ask for the paywall. Feature screens that already own a
    /// paywall sheet keep using theirs; this never fires for them.
    private var paywallBinding: Binding<PaywallTrigger?> {
        Binding(
            get: { appEnvironment.pendingPaywallTrigger },
            set: { newValue in appEnvironment.pendingPaywallTrigger = newValue }
        )
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
