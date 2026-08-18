//
//  PaywallView.swift
//  CoreCredit
//

import StoreKit
import SwiftUI
import UIKit

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

    /// The bundled document being read, if any.
    ///
    /// This screen is *presented as a sheet* from `MainTabView`, `CoreEditorView`, `CoreListView`,
    /// and `SubscriptionStatusView`, and none of those wrap it in a `NavigationStack`. There is
    /// therefore no stack here to push onto, so the documents are presented as their own sheet with
    /// their own `NavigationStack` rather than as a navigation destination.
    @State private var presentedDocument: PaywallLegalDocument?

    /// Set when Apple's manage-subscriptions sheet could not be opened.
    @State private var manageErrorMessage: String?

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
                    accountBlock
                    legalBlock
                }
                .padding(Spacing.l)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .accessibilityIdentifier(A11y.Paywall.root)
        .sheet(item: $presentedDocument) { entry in
            NavigationStack {
                LegalDocumentView(documentID: entry.documentID)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { presentedDocument = nil }
                                .accessibilityLabel(Text("Done"))
                                .accessibilityHint(Text("Closes the document and returns to the "
                                                        + "upgrade screen."))
                        }
                    }
            }
        }
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

    // MARK: Account actions

    /// The two things a shopper must always be able to do from a paywall without buying anything:
    /// get back a subscription they already paid for, and get to Apple's screen to change or cancel
    /// one.
    private var accountBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            restoreButton
            manageSubscriptionControl

            if let manageErrorMessage = manageErrorMessage {
                ErrorBanner(
                    message: manageErrorMessage,
                    onDismiss: { self.manageErrorMessage = nil }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restoreButton: some View {
        Button {
            Task { await controller.restorePurchases() }
        } label: {
            secondaryLabel(
                "Restore purchases",
                systemImage: "arrow.clockwise",
                showsProgress: controller.isRestoring
            )
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .accessibilityIdentifier(A11y.Paywall.restore)
        .accessibilityLabel(Text("Restore purchases"))
        .accessibilityHint(Text("Checks this Apple Account for a subscription you already bought."))
    }

    /// Prefers Apple's in-app management sheet and falls back to Apple's web page, matching
    /// `SubscriptionStatusView`.
    ///
    /// `AppStore.showManageSubscriptions(in:)` needs a live `UIWindowScene`. There are real
    /// situations where one is not reachable, so the fallback is not defensive padding — it is what
    /// keeps this control from becoming a dead button.
    @ViewBuilder
    private var manageSubscriptionControl: some View {
        if let scene = activeWindowScene {
            Button {
                Task { await presentManageSubscriptions(in: scene) }
            } label: {
                secondaryLabel(
                    "Manage subscription",
                    systemImage: "arrow.up.forward.app",
                    showsProgress: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Paywall.manageSubscription)
            .accessibilityLabel(Text("Manage subscription"))
            .accessibilityHint(Text("Opens the App Store subscription settings."))
        } else {
            Link(destination: PaywallContent.manageSubscriptionsURL) {
                secondaryLabel(
                    "Manage subscription",
                    systemImage: "arrow.up.forward.app",
                    showsProgress: false
                )
            }
            .accessibilityIdentifier(A11y.Paywall.manageSubscription)
            .accessibilityLabel(Text("Manage subscription"))
            .accessibilityHint(Text("Opens Apple's subscription page in the browser."))
        }
    }

    private func secondaryLabel(
        _ title: String,
        systemImage: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: Spacing.s) {
            if showsProgress {
                ProgressView()
            } else {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(title)
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

    // MARK: Legal

    /// The renewal disclosure, and the two documents a shopper is agreeing to.
    ///
    /// Both open the copy compiled into the app rather than a web page, so they can be read at the
    /// moment of purchase with no signal and with nothing fetched.
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
                legalButton(.termsOfUse, identifier: A11y.Paywall.termsOfUse)
                legalButton(.privacyPolicy, identifier: A11y.Paywall.privacyPolicy)
            }
            .foregroundStyle(Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The identifier is passed in rather than derived from `documentID`, because only two of the
    /// three bundled documents belong on a paywall and a mapping function would need a case for the
    /// one that never appears here.
    private func legalButton(_ documentID: LegalDocumentID, identifier: String) -> some View {
        Button {
            presentedDocument = PaywallLegalDocument(documentID: documentID)
        } label: {
            Text(documentID.displayName)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: Spacing.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(documentID.displayName))
        .accessibilityHint(Text("Opens the document, which is stored inside the app."))
    }

    // MARK: Helpers

    /// The free-tier limit when that is why this sheet opened, otherwise `nil`.
    private var freeLimit: Int? {
        switch trigger {
        case .freeLimitReached(let limit): return limit
        case .voluntary, .photoAssist: return nil
        }
    }
}

// MARK: - Sheet item

/// Identity for the document sheet.
///
/// `LegalDocumentID` is a plain domain enum and is deliberately left free of SwiftUI's
/// `Identifiable` requirement; this wrapper supplies the identity `sheet(item:)` needs without
/// pushing a presentation concern down into the model.
private struct PaywallLegalDocument: Identifiable {

    let documentID: LegalDocumentID

    var id: String { documentID.rawValue }
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
