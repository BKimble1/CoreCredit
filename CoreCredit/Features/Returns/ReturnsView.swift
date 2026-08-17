//
//  ReturnsView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI

/// The half of the app where the money actually comes back.
///
/// Three sections, in the order the work happens:
///
/// 1. **Ready to return**, grouped by vendor, because a return trip is per vendor.
/// 2. **Open returns**, so a batch that is still owed money stays visible.
/// 3. **Waiting on credit**, every core that has gone back and not been settled.
///
/// The figure at the top is the whole point of the screen: what is still owed to this shop. A core
/// stays counted there until a real vendor credit is recorded against it.
struct ReturnsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @Query(sort: \CoreItem.createdAt, order: .reverse) private var items: [CoreItem]
    @Query(sort: \ReturnBatch.returnDate, order: .reverse) private var batches: [ReturnBatch]
    @Query private var profiles: [ShopProfile]

    @State private var model = ReturnsModel()

    var body: some View {
        ZStack {
            Palette.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    outstandingHeader
                    errorBanner
                    readySection
                    batchesSection
                    creditQueueSection
                }
                .padding(Spacing.l)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Returns")
        .accessibilityIdentifier(A11y.Returns.root)
        // One sheet, not two: stacked `.sheet` modifiers on the same view shadow one another, so
        // both presentations go through `ReturnsModel.Route`.
        .sheet(item: $model.route) { route in
            sheetContent(for: route)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for route: ReturnsModel.Route) -> some View {
        switch route {
        case .batch(let request):
            CreateBatchSheet(vendor: request.vendor, preselected: request.preselected)
        case .credit(let item):
            RecordCreditSheet(item: item)
        }
    }

    // MARK: - Derived state

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    private var now: Date {
        appEnvironment.dateProvider.now
    }

    private var calendar: Calendar {
        appEnvironment.dateProvider.calendar
    }

    private var readyGroups: [ReturnsReadyGroup] {
        model.readyGroups(from: items)
    }

    private var openBatches: [ReturnBatch] {
        model.openBatches(from: batches)
    }

    private var settledBatches: [ReturnBatch] {
        model.settledBatches(from: batches)
    }

    private var queue: [ReturnsCreditQueueEntry] {
        model.creditQueue(from: items, now: now, calendar: calendar)
    }

    // MARK: - Header

    private var outstandingHeader: some View {
        let entries = queue
        let outstanding = model.totalOutstanding(in: entries)
        let overdue = model.overdueCount(in: entries)

        return VStack(alignment: .leading, spacing: Spacing.m) {
            StatTile(
                title: "Waiting on vendor credits",
                value: outstanding.formatted(currencyCode: currencyCode),
                symbol: "dollarsign.circle",
                tint: overdue > 0 ? Palette.danger : Palette.textPrimary,
                caption: headerCaption(entryCount: entries.count, overdueCount: overdue),
                accessibilityValue: outstanding.accessibilityText(currencyCode: currencyCode)
            )

            Text("A core keeps counting against you until the vendor's credit is recorded here.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headerCaption(entryCount: Int, overdueCount: Int) -> String {
        if entryCount == 0 {
            return "Nothing is waiting on a vendor right now."
        }
        var caption = ReturnsModel.coreCountText(entryCount) + " returned or disputed"
        if overdueCount > 0 {
            caption += " • " + String(overdueCount) + " past the return window"
        }
        return caption
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.errorMessage {
            ErrorBanner(message: message, onDismiss: { model.clearError() })
        }
    }

    // MARK: - Section 1: ready to return

    private var readySection: some View {
        SectionCard(title: "Ready to return", systemImage: CoreStatus.readyToReturn.symbolName) {
            let groups = readyGroups

            if groups.isEmpty {
                EmptyStateView(
                    symbol: CoreStatus.readyToReturn.symbolName,
                    title: "Nothing staged to go back",
                    message: "Mark a core Ready to return once the old unit is off the vehicle and on the shelf. It will show up here, grouped by the vendor it goes back to."
                )
            } else {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(stagedSummaryText(groups))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(groups) { group in
                        vendorGroupCard(group)
                    }
                }
            }
        }
    }

    /// "7 cores staged • $612.00 expected back"
    private func stagedSummaryText(_ groups: [ReturnsReadyGroup]) -> String {
        let count = groups.reduce(0) { partial, group in partial + group.itemCount }
        let total = model.totalStaged(in: groups).formatted(currencyCode: currencyCode)
        return ReturnsModel.coreCountText(count) + " staged • " + total + " expected back"
    }

    private func expansionTitle(_ group: ReturnsReadyGroup) -> String {
        if model.isExpanded(group) { return "Show fewer" }
        return "Show all " + ReturnsModel.coreCountText(group.itemCount)
    }

    private func createBatchLabel(_ group: ReturnsReadyGroup) -> String {
        "Create return batch for " + group.vendorName
    }

    private func createBatchHint(_ group: ReturnsReadyGroup) -> String {
        "Opens the return sheet with these "
            + ReturnsModel.coreCountText(group.itemCount)
            + " already selected."
    }

    private func settledToggleTitle(_ count: Int) -> String {
        if model.showsSettledBatches { return "Hide settled returns" }
        let noun = count == 1 ? " settled return" : " settled returns"
        return "Show " + String(count) + noun
    }

    private func vendorGroupCard(_ group: ReturnsReadyGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Label(group.vendorName, systemImage: "building.2")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.s)

                MoneyLabel(group.totalExpectedCredit, currencyCode: currencyCode, style: .row)
                    .accessibilityLabel(Text("Expected credit for " + group.vendorName))
            }

            Text(ReturnsModel.coreCountText(group.itemCount) + " ready")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(model.visibleItems(in: group), id: \.id) { item in
                    readyItemRow(item)
                }
            }

            if group.itemCount > ReturnsModel.collapsedItemPreviewCount {
                Button {
                    model.toggleExpansion(group)
                } label: {
                    Text(expansionTitle(group))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: Spacing.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if group.canCreateBatch {
                Button {
                    model.beginBatch(for: group)
                } label: {
                    PrimaryButtonLabel("Create return batch", systemImage: "arrow.uturn.left")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.Returns.createBatch(vendor: group.vendorName))
                .accessibilityLabel(Text(createBatchLabel(group)))
                .accessibilityHint(Text(createBatchHint(group)))
            } else {
                noVendorNotice
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var noVendorNotice: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.circle")
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text("A return goes back to one vendor, so these cores need a vendor before they can be batched. Open a core and choose where it goes back to.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readyItemRow(_ item: CoreItem) -> some View {
        NavigationLink {
            CoreDetailView(item: item)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(item.displayTitle)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = itemSubtitle(item) {
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: Spacing.s)

                MoneyLabel(item.expectedCredit, currencyCode: currencyCode, style: .caption)
                    .accessibilityLabel(Text("Expected credit"))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens this core."))
    }

    /// Part number and due-date context for a staged core, skipping whatever is missing.
    private func itemSubtitle(_ item: CoreItem) -> String? {
        var parts: [String] = []

        let partNumber = item.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if partNumber.isEmpty == false {
            parts.append(partNumber)
        }

        if RiskCalculator.isOverdue(item, now: now, calendar: calendar) {
            parts.append("Past the return window")
        } else if let days = RiskCalculator.daysUntilDue(item, now: now, calendar: calendar) {
            if days <= 0 {
                parts.append("Due back today")
            } else if days == 1 {
                parts.append("1 day left to return")
            } else {
                parts.append(String(days) + " days left to return")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Section 2: open returns

    private var batchesSection: some View {
        SectionCard(title: "Open returns", systemImage: "shippingbox") {
            let open = openBatches
            let settled = settledBatches

            VStack(alignment: .leading, spacing: Spacing.m) {
                if open.isEmpty {
                    EmptyStateView(
                        symbol: "shippingbox",
                        title: "No open returns",
                        message: "When you send a batch of cores back, it stays here until every credit on it has landed."
                    )
                } else {
                    ForEach(open, id: \.id) { batch in
                        batchRow(batch, isSettled: false)
                    }
                }

                if settled.isEmpty == false {
                    Button {
                        model.toggleSettledBatches()
                    } label: {
                        Text(settledToggleTitle(settled.count))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: Spacing.minimumTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if model.showsSettledBatches {
                        ForEach(settled, id: \.id) { batch in
                            batchRow(batch, isSettled: true)
                        }
                    }
                }
            }
        }
    }

    private func batchRow(_ batch: ReturnBatch, isSettled: Bool) -> some View {
        NavigationLink {
            BatchDetailView(batch: batch)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    Text(batch.vendor?.displayName ?? "Unknown vendor")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: Spacing.s)

                    MoneyLabel(
                        isSettled ? batch.totalExpectedCredit : batch.outstandingCredit,
                        currencyCode: currencyCode,
                        style: .row
                    )
                    .accessibilityLabel(Text(isSettled ? "Credited" : "Still outstanding"))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }

                HStack(spacing: Spacing.s) {
                    if isSettled {
                        Label("Settled", systemImage: "checkmark.seal")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.positive)
                    }

                    Text(batchSubtitle(batch))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens this return."))
    }

    private func batchSubtitle(_ batch: ReturnBatch) -> String {
        var parts: [String] = [
            ReturnsModel.coreCountText(batch.itemCount),
            batch.method.displayName,
            batch.returnDate.formatted(date: .abbreviated, time: .omitted)
        ]

        let reference = batch.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.isEmpty == false {
            parts.append("Ref " + reference)
        }

        return parts.joined(separator: " • ")
    }

    // MARK: - Section 3: waiting on credit

    private var creditQueueSection: some View {
        SectionCard(title: "Waiting on credit", systemImage: CoreStatus.returnedAwaitingCredit.symbolName) {
            let entries = queue

            if entries.isEmpty {
                EmptyStateView(
                    symbol: CoreStatus.credited.symbolName,
                    title: "Nothing outstanding",
                    message: "Every core you have sent back has been credited or closed. Cores you return next will queue up here until their credit lands."
                )
            } else {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Text("Total still owed")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)

                        Spacer(minLength: Spacing.s)

                        MoneyLabel(
                            model.totalOutstanding(in: entries),
                            currencyCode: currencyCode,
                            style: .prominent
                        )
                        .accessibilityLabel(Text("Total still owed"))
                    }

                    ForEach(entries) { entry in
                        creditQueueRow(entry)
                    }
                }
            }
        }
        .accessibilityIdentifier(A11y.Returns.awaitingCredit)
    }

    private func creditQueueRow(_ entry: ReturnsCreditQueueEntry) -> some View {
        let item = entry.item

        return VStack(alignment: .leading, spacing: Spacing.s) {
            NavigationLink {
                CoreDetailView(item: item)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(item.displayTitle)
                            .font(Typography.rowTitle)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(queueSubtitle(entry))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Spacing.s)

                    MoneyLabel(entry.outstanding, currencyCode: currencyCode, style: .row)
                        .accessibilityLabel(Text("Still owed"))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Spacing.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens this core."))

            HStack(spacing: Spacing.m) {
                StatusBadge(status: item.status, isOverdue: entry.isOverdue, compact: true)

                Spacer(minLength: Spacing.s)

                Button {
                    model.beginCredit(for: item)
                } label: {
                    ReturnsActionLabel(title: "Record credit", systemImage: CoreStatus.credited.symbolName)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Record credit for " + item.displayTitle))
                .accessibilityHint(Text("Enter the vendor's credit memo and compare it to what was expected."))
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    /// "Waiting 12 days • NAPA • short by $11.50" — whichever parts apply.
    private func queueSubtitle(_ entry: ReturnsCreditQueueEntry) -> String {
        var parts: [String] = [ReturnsModel.waitingText(days: entry.daysWaiting)]

        if let vendorName = entry.item.vendorName {
            parts.append(vendorName)
        }

        if entry.item.status == .disputed, let discrepancy = RiskCalculator.discrepancy(for: entry.item),
           discrepancy.isPositive {
            parts.append("Short by " + discrepancy.formatted(currencyCode: currencyCode))
        }

        return parts.joined(separator: " • ")
    }
}

// MARK: - ReturnsActionLabel

/// A secondary action inside a row: readable, tinted amber, and a full 44 points tall.
private struct ReturnsActionLabel: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: Spacing.minimumTapTarget)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
