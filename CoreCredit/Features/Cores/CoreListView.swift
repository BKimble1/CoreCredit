//
//  CoreListView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The ledger: every core the shop is tracking, searchable, filterable, and sortable.
///
/// The view owns the `@Query` and nothing else about *which* rows appear —
/// `CoreItemQuery.filterAndSort(_:filter:sort:now:calendar:)` decides that, so a search here finds
/// the same records an export would, and the rules stay unit-testable without SwiftUI.
///
/// Two empty states, on purpose. An empty **ledger** offers to add the first core, with the
/// workflow lesson folded away in `HowItWorksDisclosure` for whoever wants it. An empty **result**
/// says the filter is too narrow and offers to clear it. Telling a shop owner "no cores" when they
/// have forty of them behind a filter is how a ledger loses trust.
///
/// Adding is the only gated action: `EntitlementPolicy.blockingTrigger(unresolvedCount:tier:)` is
/// asked first, and the paywall is presented *instead of* the editor when the free limit is
/// reached. Everything already in the ledger stays viewable, editable, and exportable on any tier.
struct CoreListView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \CoreItem.createdAt, order: .reverse) private var items: [CoreItem]
    @Query private var profiles: [ShopProfile]
    @Query(sort: \Vendor.name) private var vendors: [Vendor]

    @State private var model: CoreListModel

    private let title: String

    /// - Parameters:
    ///   - initialFilter: Criteria to open with. The dashboard uses this to drill into one status
    ///     or into the overdue pile; the tab bar opens with `.none`.
    ///   - title: Navigation title, so a pre-filtered list says what it is showing.
    init(initialFilter: CoreItemFilter = .none, title: String = "Cores") {
        self.title = title
        _model = State(initialValue: CoreListModel(filter: initialFilter))
    }

    var body: some View {
        let visible = model.visibleItems(from: items, dateProvider: appEnvironment.dateProvider)

        return VStack(spacing: 0) {
            if let message = model.errorMessage {
                ErrorBanner(message: message, onDismiss: { model.clearError() })
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.s)
            }

            if !items.isEmpty {
                filterBar(visibleCount: visible.count)
            }

            if items.isEmpty {
                emptyLedger
            } else if visible.isEmpty {
                noMatches
            } else {
                list(visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same reason as the Dashboard: a `ZStack` holding a safe-area-ignoring background grows to
        // the full screen and takes the tab bar's inset away from the list inside it, which put the
        // last core under the bar. The background is painted behind instead, and the bottom margin
        // is ordinary breathing room rather than a guess at how tall the bar is.
        .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
        .background {
            Palette.background.ignoresSafeArea()
        }
        .navigationTitle(title)
        .accessibilityIdentifier(A11y.Cores.root)
        .searchable(
            text: searchBinding,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Part, number, invoice, RO, vendor, bin")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                addButton
            }
        }
        // One sheet, not three: stacked `.sheet` modifiers on the same view shadow one another, so
        // every presentation this screen owns goes through `CoreListModel.Route`.
        .sheet(item: routeBinding) { route in
            sheetContent(for: route)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for route: CoreListModel.Route) -> some View {
        switch route {
        case .filters:
            CoreFilterSheet(
                filter: model.filter,
                vendors: vendors,
                now: appEnvironment.dateProvider.now
            ) { newFilter in
                model.apply(newFilter)
            }
        case .editor:
            NavigationStack {
                CoreEditorView(mode: .create)
            }
        case .paywall(let trigger):
            PaywallView(trigger: trigger)
        }
    }

    // MARK: - Shared values

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private var now: Date { appEnvironment.dateProvider.now }

    private var calendar: Calendar { appEnvironment.dateProvider.calendar }

    // MARK: - List

    private func list(_ visible: [CoreItem]) -> some View {
        List {
            ForEach(visible, id: \.id) { item in
                NavigationLink {
                    CoreDetailView(item: item)
                } label: {
                    CoreRowView(
                        item: item,
                        currencyCode: currencyCode,
                        now: now,
                        calendar: calendar
                    )
                }
                .listRowBackground(Palette.surface)
                .listRowInsets(
                    EdgeInsets(
                        top: Spacing.xs,
                        leading: Spacing.l,
                        bottom: Spacing.xs,
                        trailing: Spacing.l
                    )
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(A11y.Cores.list)
    }

    // MARK: - Controls

    private func filterBar(visibleCount: Int) -> some View {
        HStack(spacing: Spacing.m) {
            Button {
                model.route = .filters
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .imageScale(.medium)
                    Text(filterButtonTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(model.hasActiveFilters ? Palette.accent : Palette.textSecondary)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Spacing.minimumTapTarget)
                .background(
                    Capsule(style: .continuous)
                        .fill(model.hasActiveFilters ? Palette.accent.opacity(0.14) : Palette.surface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            model.hasActiveFilters ? Palette.accent.opacity(0.38) : Palette.hairline,
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Filters"))
            .accessibilityValue(Text(filterAccessibilityValue))

            if model.hasActiveFilters {
                Button {
                    model.clearFilters()
                } label: {
                    Text("Clear")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, Spacing.s)
                        .frame(minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Removes every filter and shows the whole ledger."))
            }

            Spacer(minLength: Spacing.s)

            Text(countPhrase(visibleCount))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .accessibilityLabel(Text(countPhrase(visibleCount) + " shown"))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CoreItemSort.allCases) { option in
                Button {
                    model.sort = option
                } label: {
                    Label(
                        option.displayName,
                        systemImage: model.sort == option ? "checkmark" : option.symbolName
                    )
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(Text("Sort"))
        .accessibilityValue(Text(model.sort.displayName))
    }

    private var addButton: some View {
        Button {
            model.requestAddCore(
                items: items,
                tier: appEnvironment.subscriptions.entitlement.tier
            )
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityIdentifier(A11y.Cores.addButton)
        .accessibilityLabel(Text("Add core"))
        .accessibilityHint(Text("Logs a new core charge you are waiting to get credited."))
    }

    // MARK: - Empty states

    private var emptyLedger: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "No cores yet",
                    message: "Log your first core charge, return deadline, and expected credit.",
                    actionTitle: "Add core",
                    action: {
                        model.requestAddCore(
                            items: items,
                            tier: appEnvironment.subscriptions.entitlement.tier
                        )
                    }
                )

                HowItWorksDisclosure()
                    .padding(.horizontal, Spacing.l)
            }
            .padding(.vertical, Spacing.xl)
        }
    }

    private var noMatches: some View {
        ScrollView {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No cores match",
                message: "The records are still there — the filter is just too narrow.",
                actionTitle: "Clear filters",
                action: { model.clearFiltersAndSearch() }
            )
            .padding(.vertical, Spacing.xl)
        }
    }

    // MARK: - Text

    private var filterButtonTitle: String {
        let count = model.activeFilterCount
        return count == 0 ? "Filters" : "Filters (" + String(count) + ")"
    }

    private var filterAccessibilityValue: String {
        let count = model.activeFilterCount
        if count == 0 { return "None applied" }
        return count == 1 ? "1 filter applied" : String(count) + " filters applied"
    }

    private func countPhrase(_ count: Int) -> String {
        count == 1 ? "1 core" : String(count) + " cores"
    }

    // MARK: - Bindings

    private var searchBinding: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { model.searchText = $0 }
        )
    }

    private var routeBinding: Binding<CoreListModel.Route?> {
        Binding(
            get: { model.route },
            set: { model.route = $0 }
        )
    }
}
