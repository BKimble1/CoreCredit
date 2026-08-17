//
//  DashboardView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// "1 core" / "4 cores".
private func coreCountPhrase(_ count: Int) -> String {
    count == 1 ? "1 core" : String(count) + " cores"
}

/// The screen that keeps the app's promise: *know exactly how much core-credit money is still at
/// risk.*
///
/// Every figure here comes from one `RiskCalculator.summarize(_:now:calendar:)` pass over the live
/// `@Query`, driven by `AppEnvironment.dateProvider` rather than `Date()`, so the injected clock
/// stays authoritative and a UI test can freeze time and still see the same aging buckets. The
/// summary and the urgent list are computed once at the top of `body` and handed down, so a render
/// never adds the ledger up twice.
///
/// The layout is a stack of wide blocks rather than a wall of small cards: the headline total, the
/// one primary action, what needs chasing today, where the money sits by status, and how long it
/// has been sitting. Every tile and row is a `NavigationLink` into the same ledger, so no figure is
/// a dead end.
///
/// With an empty ledger there is no fake data and no zeroed-out chrome — just an explanation of the
/// financial workflow the app exists to close.
struct DashboardView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \CoreItem.createdAt, order: .reverse) private var items: [CoreItem]
    @Query private var profiles: [ShopProfile]

    @State private var model = DashboardModel()

    /// Declared explicitly rather than relying on the synthesized memberwise initializer, whose
    /// access level would otherwise be tied to this view's `private` stored properties.
    init() { }

    var body: some View {
        let summary = model.summary(for: items, dateProvider: appEnvironment.dateProvider)
        let urgent = model.urgentItems(from: items, dateProvider: appEnvironment.dateProvider)

        return ZStack {
            Palette.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let message = model.errorMessage {
                        ErrorBanner(message: message, onDismiss: { model.clearError() })
                    }

                    if summary.hasAnyItems {
                        populatedContent(summary: summary, urgent: urgent)
                    } else {
                        emptyContent
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Dashboard")
        .accessibilityIdentifier(A11y.Dashboard.root)
        // One sheet, not two: stacked `.sheet` modifiers on the same view shadow one another, so
        // both presentations go through `DashboardModel.Route`.
        .sheet(item: routeBinding) { route in
            sheetContent(for: route)
        }
    }

    // MARK: - Sheets

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

    // MARK: - Shared values

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private var now: Date { appEnvironment.dateProvider.now }

    private var calendar: Calendar { appEnvironment.dateProvider.calendar }

    // MARK: - Populated state

    @ViewBuilder
    private func populatedContent(summary: RiskSummary, urgent: [CoreItem]) -> some View {
        MoneyAtRiskHeader(summary: summary, currencyCode: currencyCode)
        addCoreActions
        needsAttentionSection(summary: summary, urgent: urgent)
        statusSection(summary: summary)
        agingSection(summary: summary)
    }

    private func statusSection(summary: RiskSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionHeading("Where the money is sitting")

            StatusCardGrid(summary: summary, currencyCode: currencyCode) { status in
                CoreListView(
                    initialFilter: CoreItemFilter(statuses: [status]),
                    title: status.displayName
                )
            }
        }
    }

    private func agingSection(summary: RiskSummary) -> some View {
        SectionCard(title: "How long it has been sitting", systemImage: "calendar") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(summary.agingBuckets) { bucket in
                    NavigationLink {
                        AgingBucketItemsView(bucket: bucket.bucket)
                    } label: {
                        AgingBucketRow(summary: bucket, currencyCode: currencyCode)
                    }
                    .buttonStyle(.plain)

                    if bucket.id != summary.agingBuckets.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func needsAttentionSection(summary: RiskSummary, urgent: [CoreItem]) -> some View {
        SectionCard(title: "Needs attention", systemImage: "exclamationmark.circle") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if urgent.isEmpty {
                    Text("Nothing is overdue. Keep sending cores back before their window closes.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(urgent, id: \.id) { item in
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
                        .buttonStyle(.plain)

                        Divider()
                    }

                    seeAllRow(summary: summary)
                }
            }
        }
    }

    private func seeAllRow(summary: RiskSummary) -> some View {
        let title = seeAllTitle(summary: summary)
        let showsOverdue = summary.overdueCount > 0

        return NavigationLink {
            if showsOverdue {
                CoreListView(
                    initialFilter: CoreItemFilter(onlyOverdue: true),
                    title: "Overdue"
                )
            } else {
                CoreListView(
                    initialFilter: CoreItemFilter(statuses: Set(CoreStatus.unresolvedCases)),
                    title: "Open cores"
                )
            }
        } label: {
            HStack(spacing: Spacing.s) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.s)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func seeAllTitle(summary: RiskSummary) -> String {
        if summary.overdueCount > 0 {
            return "See all " + coreCountPhrase(summary.overdueCount) + " overdue"
        }
        return "See all " + coreCountPhrase(summary.unresolvedCount) + " still open"
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyContent: some View {
        EmptyStateView(
            symbol: "dollarsign.circle",
            title: "No core money on the books yet",
            message: "A core charge is your money sitting on a vendor's account. Log the first one "
                + "and this screen tells you exactly how much is still out there."
        )

        workflowCard
        addCoreActions
    }

    private var workflowCard: some View {
        SectionCard(title: "How a core charge comes back", systemImage: "list.number") {
            VStack(alignment: .leading, spacing: Spacing.l) {
                workflowStep(
                    number: 1,
                    title: "The vendor charges you a core",
                    detail: "A deposit is added to the invoice on top of the new part."
                )
                workflowStep(
                    number: 2,
                    title: "You keep the old part",
                    detail: "Tag it and put it in a bin so it does not walk off the shelf."
                )
                workflowStep(
                    number: 3,
                    title: "You return it in time",
                    detail: "Send it back before the vendor's return window closes."
                )
                workflowStep(
                    number: 4,
                    title: "You confirm the credit",
                    detail: "Match the credit memo against the charge. Anything short stays on "
                        + "your books until it is settled."
                )
            }
        }
    }

    private func workflowStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(String(number))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Palette.onColor(for: .readyToReturn))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.accent))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step " + String(number) + ". " + title))
        .accessibilityValue(Text(detail))
    }

    // MARK: - Shared pieces

    /// The two ways into the same new record: type it, or scan it.
    ///
    /// Both go through `DashboardModel`, so both hit the free-limit check before anything opens.
    private var addCoreActions: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            addCoreButton
            scanCoreButton
        }
    }

    private var addCoreButton: some View {
        Button {
            model.requestAddCore(
                items: items,
                tier: appEnvironment.subscriptions.entitlement.tier
            )
        } label: {
            PrimaryButtonLabel("Add core", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Dashboard.addCore)
        .accessibilityHint(Text("Logs a new core charge you are waiting to get credited."))
    }

    /// Opens the intake form with the scanner already in front of it. Secondary, not primary: amber
    /// belongs to the one action on the screen that always works, which is the one that needs no
    /// camera at all.
    private var scanCoreButton: some View {
        Button {
            model.requestScanCore(
                items: items,
                tier: appEnvironment.subscriptions.entitlement.tier
            )
        } label: {
            DashboardActionLabel(title: "Scan core", systemImage: "barcode.viewfinder")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Dashboard.scanCore)
        .accessibilityLabel(Text("Scan core"))
        .accessibilityHint(Text("Opens the scanner on a new core charge. You can still type "
                                + "everything in if the code will not read."))
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(Typography.sectionTitle)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Bindings

    private var routeBinding: Binding<DashboardModel.Route?> {
        Binding(
            get: { model.route },
            set: { model.route = $0 }
        )
    }
}

// MARK: - Aging drill-down

/// The open cores sitting in one aging band.
///
/// Aging is deliberately **not** a `CoreItemFilter` criterion: a core's age is measured from
/// whichever date last mattered to it (`RiskCalculator.referenceDate(for:)`), which is not the same
/// as its received date once it has been returned. So this drill-down asks `RiskCalculator` for the
/// bucket directly instead of pretending a received-date range would give the same answer. Ordering
/// still goes through `CoreItemQuery`.
private struct AgingBucketItemsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @Query(sort: \CoreItem.createdAt, order: .reverse) private var items: [CoreItem]
    @Query private var profiles: [ShopProfile]

    private let bucket: AgingBucket

    init(bucket: AgingBucket) {
        self.bucket = bucket
    }

    var body: some View {
        let matching = matchingItems

        return ZStack {
            Palette.background
                .ignoresSafeArea()

            if matching.isEmpty {
                ScrollView {
                    EmptyStateView(
                        symbol: "calendar",
                        title: "Nothing in this band",
                        message: "No open core has been sitting for "
                            + bucket.displayName.lowercased()
                            + "."
                    )
                    .padding(.vertical, Spacing.xxl)
                }
            } else {
                List {
                    ForEach(matching, id: \.id) { item in
                        NavigationLink {
                            CoreDetailView(item: item)
                        } label: {
                            CoreRowView(
                                item: item,
                                currencyCode: currencyCode,
                                now: appEnvironment.dateProvider.now,
                                calendar: appEnvironment.dateProvider.calendar
                            )
                        }
                        .listRowBackground(Palette.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(bucket.displayName)
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private var matchingItems: [CoreItem] {
        let now = appEnvironment.dateProvider.now
        let calendar = appEnvironment.dateProvider.calendar
        let open = items.filter { item in
            item.status.isUnresolved
                && RiskCalculator.agingBucket(item, now: now, calendar: calendar) == bucket
        }
        return CoreItemQuery.sort(open, by: .oldestFirst)
    }
}

// MARK: - Secondary action label

/// The label for a supporting action on the dashboard.
///
/// Outlined rather than filled: amber marks the one primary action on a screen, and on this screen
/// that is "Add core" — the path that works with no camera, no permission, and no hardware.
private struct DashboardActionLabel: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
