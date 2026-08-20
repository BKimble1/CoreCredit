//
//  SubscriptionStatusView.swift
//  CoreCredit
//

import StoreKit
import SwiftData
import SwiftUI
import UIKit

/// The Settings screen that says, plainly, what this shop is on and what that means today.
///
/// It answers three questions and nothing else: which plan, how much of the free allowance is
/// used, and where to change or restore the subscription.
struct SubscriptionStatusView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    /// Used only to count unresolved cores for the free-tier allowance. Reading the whole set is
    /// deliberate: a shop's ledger is small, and a predicate on a raw status string is one silent
    /// typo away from reporting the wrong number.
    @Query private var coreItems: [CoreItem]

    init() { }

    var body: some View {
        SubscriptionStatusContent(
            controller: appEnvironment.subscriptions,
            unresolvedCount: RiskCalculator.unresolvedCount(coreItems)
        )
    }
}

// MARK: - Content

/// The body, separated from its environment lookups so it previews and tests without a store.
private struct SubscriptionStatusContent: View {

    let controller: SubscriptionController
    let unresolvedCount: Int

    @State private var isPresentingPaywall = false
    @State private var manageErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                planCard

                if controller.entitlement.isInGracePeriod {
                    billingRetryNotice
                }

                if let message = manageErrorMessage {
                    ErrorBanner(message: message, onDismiss: { manageErrorMessage = nil })
                }

                restoreFeedback

                if controller.isPro == false {
                    freeAllowanceCard
                    upgradeButton
                }

                accountCard
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // A pushed screen still sits behind the tab bar, so the last account action needs the
        // same breathing room the root screens got.
        .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
        .background {
            Palette.background.ignoresSafeArea()
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Settings.subscriptionScreen)
        .sheet(isPresented: $isPresentingPaywall) {
            PaywallView(trigger: .voluntary)
        }
        .task {
            if controller.loadState == .idle {
                await controller.loadProducts()
            }
            // Opening this screen is the moment a shop owner wants a current answer, so re-check
            // the store rather than trusting whatever was cached at launch.
            await controller.refreshEntitlement()
        }
    }

    // MARK: Restore feedback

    /// The outcome of a restore, in the same place the button that started it lives.
    ///
    /// A restore that finds nothing is reported plainly rather than silently: "nothing happened"
    /// is the single most confusing outcome a restore button can produce.
    @ViewBuilder
    private var restoreFeedback: some View {
        if let message = controller.purchasePhase.failureMessage {
            ErrorBanner(message: message, onDismiss: { controller.clearPurchasePhase() })
        } else if controller.purchasePhase == .succeeded {
            SectionCard(title: "Subscription found", systemImage: "checkmark.seal") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Pro is active on this device.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        controller.clearPurchasePhase()
                    } label: {
                        Text("OK")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: Spacing.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss"))
                }
            }
        } else if controller.purchasePhase == .pendingApproval {
            SectionCard(title: "Waiting for approval", systemImage: "clock") {
                Text(
                    "This purchase needs approval from the person who manages the Apple Account. "
                    + "Pro switches on by itself once they approve it."
                )
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Plan

    private var planCard: some View {
        SectionCard(title: "Plan", systemImage: "person.crop.circle") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabeledValueRow("Current plan", value: controller.entitlement.tier.displayName)

                // Wording and tense live in `SubscriptionPeriodPresentation`, so the one sentence
                // this app says about a paid period is a thing the test suite can pin. The date is
                // the store's own `expirationDate`, formatted and never computed.
                if let period = SubscriptionPeriodPresentation.row(
                    for: controller.entitlement,
                    now: Date()
                ) {
                    LabeledValueRow(period.label, value: period.value)
                }

                if controller.isPro {
                    Text("Unlimited open cores. Nothing in the app is gated.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Shown while StoreKit reports a grace or billing-retry period.
    ///
    /// Amber, not red: nothing is lost yet and access continues. Red in this app means overdue or
    /// disputed money, and borrowing it here would cheapen it.
    private var billingRetryNotice: some View {
        SectionCard(title: "Payment needs attention", systemImage: "exclamationmark.triangle") {
            Text(
                "The App Store couldn't take the last payment and is retrying. Pro access "
                + "continues in the meantime. Update the payment method in Settings, under your "
                + "Apple Account."
            )
            .font(.subheadline)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Free allowance

    private var freeAllowanceCard: some View {
        let limit = EntitlementPolicy.freeUnresolvedLimit
        let remaining = EntitlementPolicy.remainingFreeSlots(
            unresolvedCount: unresolvedCount,
            tier: controller.entitlement.tier
        ) ?? 0

        // Plain: the `StatTile` inside already draws a surface, and a card around a card is the
        // pattern this pass exists to remove.
        return SectionCard(title: "Free allowance", systemImage: "shippingbox", isPlain: true) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                StatTile(
                    title: "Open cores",
                    value: String(unresolvedCount) + " of " + String(limit),
                    symbol: "shippingbox",
                    tint: remaining == 0 ? Palette.accent : Palette.neutral,
                    caption: remainingCaption(remaining: remaining),
                    accessibilityValue: String(unresolvedCount) + " of " + String(limit) + " open cores used"
                )

                Text(
                    "The free plan limits how many cores can be open at once. Every core you have "
                    + "already logged stays fully usable — view it, edit it, record its credit, "
                    + "write it off, and export it, on any plan."
                )
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func remainingCaption(remaining: Int) -> String {
        if remaining == 0 {
            return "No room for another open core"
        }
        if remaining == 1 {
            return "Room for 1 more open core"
        }
        return "Room for " + String(remaining) + " more open cores"
    }

    private var upgradeButton: some View {
        Button {
            isPresentingPaywall = true
        } label: {
            PrimaryButtonLabel("Upgrade to Pro", systemImage: "arrow.up.circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Upgrade to Pro"))
        .accessibilityHint(Text("Opens the upgrade options."))
    }

    // MARK: Account actions

    private var accountCard: some View {
        SectionCard(title: "Apple Account", systemImage: "creditcard") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                restoreButton
                Divider().overlay(Palette.hairline)
                manageSubscriptionControl
            }
        }
    }

    private var restoreButton: some View {
        Button {
            Task { await controller.restorePurchases() }
        } label: {
            actionRowLabel(
                "Restore purchases",
                systemImage: "arrow.clockwise",
                showsProgress: controller.isRestoring
            )
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .accessibilityLabel(Text("Restore purchases"))
        .accessibilityHint(Text("Checks this Apple Account for a subscription you already bought."))
    }

    /// Prefers the in-app management sheet and falls back to Apple's web page.
    ///
    /// `AppStore.showManageSubscriptions(in:)` needs a live `UIWindowScene`. There are real
    /// situations where one is not reachable, so the fallback is not defensive padding — it is the
    /// path that keeps this row from becoming a dead button.
    @ViewBuilder
    private var manageSubscriptionControl: some View {
        if let scene = activeWindowScene {
            Button {
                Task { await presentManageSubscriptions(in: scene) }
            } label: {
                actionRowLabel("Manage subscription", systemImage: "arrow.up.forward.app", showsProgress: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Manage subscription"))
            .accessibilityHint(Text("Opens the App Store subscription settings."))
        } else {
            Link(destination: SubscriptionStatusContent.manageSubscriptionsURL) {
                actionRowLabel("Manage subscription", systemImage: "arrow.up.forward.app", showsProgress: false)
            }
            .accessibilityLabel(Text("Manage subscription"))
            .accessibilityHint(Text("Opens Apple's subscription page in the browser."))
        }
    }

    private func actionRowLabel(
        _ title: String,
        systemImage: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text(title)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.s)

            if showsProgress {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Main-actor isolated deliberately. This function is reached from a `Task` inside a
    /// `@ViewBuilder` property, which carries no isolation of its own, so without the annotation
    /// the body would run on the cooperative pool: `AppStore.showManageSubscriptions(in:)` would
    /// be asked to present a sheet from a background thread, and — worse, because it is silent —
    /// `manageErrorMessage` would be written off the main actor while SwiftUI reads it on. Same
    /// class of mistake as the notification-delegate crash in `NotificationResponder`.
    @MainActor
    private func presentManageSubscriptions(in scene: UIWindowScene) async {
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            manageErrorMessage = nil
        } catch {
            manageErrorMessage = "Couldn't open the subscription settings. You can manage the "
                + "subscription in the Settings app, under your Apple Account."
        }
    }

    /// The foreground scene, or any connected one, or `nil` when the app has none.
    private var activeWindowScene: UIWindowScene? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first
    }

    private static let manageSubscriptionsURL =
        URL(string: "https://apps.apple.com/account/subscriptions") ?? AppConfiguration.fallbackURL
}

// MARK: - Previews

#Preview("Subscription — free, at the limit") {
    NavigationStack {
        SubscriptionStatusContent(
            controller: SubscriptionController(
                engine: StubSubscriptionEngine(tier: .free),
                defaults: UserDefaults(suiteName: "CoreCreditPreview") ?? .standard
            ),
            unresolvedCount: AppConfiguration.freeUnresolvedItemLimit
        )
    }
}

#Preview("Subscription — Pro") {
    NavigationStack {
        SubscriptionStatusContent(
            controller: SubscriptionController(
                engine: StubSubscriptionEngine(tier: .pro),
                defaults: UserDefaults(suiteName: "CoreCreditPreview") ?? .standard
            ),
            unresolvedCount: 12
        )
    }
}
