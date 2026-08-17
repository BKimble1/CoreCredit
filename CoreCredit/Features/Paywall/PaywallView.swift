//
//  PaywallView.swift
//  CoreCredit
//

import SwiftUI

/// The upgrade sheet.
///
/// Tone is deliberately flat: what Pro costs, what it adds, what stays free, and two buttons.
/// There is no countdown, no struck-through "was" price, no badge that says the offer ends
/// tonight, and no colour doing work that words should do. The people using this app are quoting
/// a job at a parts counter; a paywall that plays games with them is a paywall they will
/// remember for the wrong reason.
struct PaywallView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    private let trigger: PaywallTrigger

    init(trigger: PaywallTrigger) {
        self.trigger = trigger
    }

    var body: some View {
        PaywallContent(trigger: trigger, controller: appEnvironment.subscriptions)
    }
}

// MARK: - Content

/// The paywall body, separated from its environment lookup so it can be previewed and driven
/// directly from a `SubscriptionController` in tests.
private struct PaywallContent: View {

    @Environment(\.dismiss) private var dismiss

    let trigger: PaywallTrigger
    let controller: SubscriptionController

    var body: some View {
        ZStack {
            Palette.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header
                    headlineBlock
                    statusBlock

                    if controller.purchasePhase == .succeeded {
                        successCard
                    } else {
                        productBlock
                    }

                    if let limit = freeLimit {
                        keepsWorkingCard(limit: limit)
                    }

                    includedCard
                    restoreButton
                    legalBlock
                }
                .padding(Spacing.l)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .accessibilityIdentifier(A11y.Paywall.root)
        .task {
            // The controller is normally started at launch. This covers the case where the sheet
            // is the first thing to need products — for example a cold launch straight into the
            // core editor.
            if controller.loadState == .idle {
                await controller.loadProducts()
            }
        }
        .onChange(of: controller.purchasePhase) { _, newPhase in
            // A cancelled purchase is not an error and gets no message: the sheet simply goes
            // back to how it was.
            if newPhase == .cancelled {
                controller.clearPurchasePhase()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Spacing.minimumTapTarget, height: Spacing.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Paywall.close)
            .accessibilityLabel(Text("Close"))
            .accessibilityHint(Text("Closes the upgrade screen. Nothing is charged."))
        }
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(trigger.headline)
                .font(Typography.hero)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(trigger.subheadline)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Banners

    /// Store problems and purchase feedback. Never blocks the close button.
    @ViewBuilder
    private var statusBlock: some View {
        if let message = controller.loadState.errorMessage {
            ErrorBanner(
                message: message,
                retryTitle: "Try again",
                onRetry: {
                    Task { await controller.retryLoadProducts() }
                }
            )
        }

        if let message = controller.purchasePhase.failureMessage {
            ErrorBanner(
                message: message,
                onDismiss: {
                    controller.clearPurchasePhase()
                }
            )
        }

        if controller.purchasePhase == .pendingApproval {
            SectionCard(title: "Waiting for approval", systemImage: "clock") {
                Text(
                    "This purchase needs approval from the person who manages the Apple Account. "
                    + "Pro switches on by itself once they approve it. Nothing has been charged yet."
                )
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Products

    @ViewBuilder
    private var productBlock: some View {
        let monthly = controller.monthlyProduct
        let annual = controller.annualProduct

        if monthly == nil && annual == nil {
            if controller.loadState.isLoading {
                HStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("Loading subscription options…")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if controller.loadState.isFailed == false {
                Text("Subscription options aren't available right now. Everything already in the app keeps working.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let monthly = monthly {
                    productRow(monthly, identifier: A11y.Paywall.monthly, savingsText: nil)
                }
                if let annual = annual {
                    productRow(
                        annual,
                        identifier: A11y.Paywall.annual,
                        savingsText: controller.annualSavingsText
                    )
                }
            }
        }
    }

    /// One purchasable row.
    ///
    /// The price string is whatever StoreKit returned for this shopper's storefront — it is never
    /// built, formatted, or hard-coded here.
    private func productRow(
        _ product: SubscriptionProduct,
        identifier: String,
        savingsText: String?
    ) -> some View {
        let isPurchasingThis = controller.purchasePhase.purchasingProductID == product.id

        return Button {
            Task { await controller.purchase(product) }
        } label: {
            HStack(alignment: .center, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(product.period.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)

                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text(product.displayPrice)
                            .font(Typography.money)
                            .foregroundStyle(Palette.textPrimary)
                        Text(product.period.perPeriodSuffix)
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    if let savingsText = savingsText {
                        Text(savingsText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                    }

                    if let offer = product.introductoryOffer {
                        Text(offer)
                            .font(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isPurchasingThis {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(spokenLabel(for: product, savingsText: savingsText)))
        .accessibilityHint(Text(isPurchasingThis ? "Purchase in progress." : "Starts the App Store purchase."))
    }

    private func spokenLabel(for product: SubscriptionProduct, savingsText: String?) -> String {
        var parts: [String] = [product.period.displayName, product.displayPrice]
        let suffix = product.period.spokenPeriodSuffix
        if suffix.isEmpty == false {
            parts.append(suffix)
        }
        if let savingsText = savingsText {
            parts.append(savingsText)
        }
        if let offer = product.introductoryOffer {
            parts.append(offer)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Cards

    private var successCard: some View {
        SectionCard(title: "You're on Pro", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Open core limit removed. Log as many as the shelf holds.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    controller.clearPurchasePhase()
                    dismiss()
                } label: {
                    PrimaryButtonLabel("Done", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The promise that matters most on this screen: nothing already logged is taken away.
    private func keepsWorkingCard(limit: Int) -> some View {
        SectionCard(title: "Your first " + String(limit) + " cores keep working", systemImage: "lock.open") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                bullet("View and edit every core you've already logged")
                bullet("Record vendor credits and settle disputes")
                bullet("Mark cores returned, credited, or written off")
                bullet("Export dispute packets, CSV ledgers, and backups")

                Text(
                    "Pro is only needed to open a new core beyond " + String(limit)
                    + ". Nothing you have already entered is ever locked away, on any plan."
                )
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.xs)
            }
        }
    }

    private var includedCard: some View {
        SectionCard(title: "What Pro includes", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                bullet("Unlimited open cores")
                bullet("Dispute packets with photos and a full status history")
                bullet("CSV ledger exports and JSON backups")
                bullet("Reminders before a vendor's return window closes")
                bullet("Printable bin tags with scannable codes")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Restore + legal

    private var restoreButton: some View {
        Button {
            Task { await controller.restorePurchases() }
        } label: {
            HStack(spacing: Spacing.s) {
                if controller.isRestoring {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                }
                Text("Restore purchases")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .accessibilityIdentifier(A11y.Paywall.restore)
        .accessibilityLabel(Text("Restore purchases"))
        .accessibilityHint(Text("Checks this Apple Account for a subscription you already bought."))
    }

    private var legalBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(
                "Payment is charged to your Apple Account when you confirm. The subscription "
                + "renews automatically unless auto-renew is turned off at least 24 hours before "
                + "the current period ends. Manage or cancel it in Settings, under your Apple "
                + "Account, then Subscriptions."
            )
            .font(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.l) {
                Link(destination: AppConfiguration.termsURL) {
                    Text("Terms of Use")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Terms of Use"))

                Link(destination: AppConfiguration.privacyURL) {
                    Text("Privacy Policy")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Privacy Policy"))
            }
            .foregroundStyle(Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Helpers

    /// The free-tier limit when that is why this sheet opened, otherwise `nil`.
    private var freeLimit: Int? {
        switch trigger {
        case .freeLimitReached(let limit): return limit
        case .voluntary: return nil
        }
    }
}

// MARK: - Previews

#Preview("Paywall — free limit reached") {
    PaywallContent(
        trigger: .freeLimitReached(limit: AppConfiguration.freeUnresolvedItemLimit),
        controller: SubscriptionController(
            engine: StubSubscriptionEngine(tier: .free),
            defaults: UserDefaults(suiteName: "CoreCreditPreview") ?? .standard
        )
    )
}

#Preview("Paywall — store unavailable") {
    PaywallContent(
        trigger: .voluntary,
        controller: SubscriptionController(
            engine: StubSubscriptionEngine(tier: .free, simulateLoadFailure: true),
            defaults: UserDefaults(suiteName: "CoreCreditPreview") ?? .standard
        )
    )
}
