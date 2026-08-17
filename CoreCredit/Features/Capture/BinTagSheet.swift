//
//  BinTagSheet.swift
//  CoreCredit
//
//  Capture feature — the printable shelf label for one core.
//
//  ## What a bin tag is for
//
//  It gets taped to a shelf next to a greasy alternator and read again weeks later, sometimes by
//  someone who has never opened the app. So the screen shows the same three things the printed
//  label does: a large QR code, the part it belongs to, and what the core is worth. The QR carries
//  only a short `corecredit://item/<uuid>` link — see `BinTagPayload` — because a dense symbol is a
//  symbol that will not scan off a dusty shelf.
//
//  If the code cannot be generated, the sheet says so in words and still offers the tag: the
//  printed label falls back to the item's short identifier, which a person can type. An empty grey
//  box would be the one useless outcome.
//
//  ## Who writes the file
//
//  The shareable PDF is produced by `ExportCoordinator.exportBinTag(for:profile:)`, the same object
//  behind every other export in the app, so this sheet inherits its progress flag, its error
//  phrasing, and the retention sweep of the exports folder. Printing still renders its own bytes
//  through `BinTagRenderer`, because the print sheet needs the data itself rather than a file URL.
//

import SwiftData
import SwiftUI
import UIKit

/// Shows, shares, and prints the QR bin tag for one core.
@MainActor
struct BinTagSheet: View {

    private let item: CoreItem

    init(item: CoreItem) {
        self.item = item
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [ShopProfile]

    @State private var qrImage: UIImage?
    @State private var pdfData: Data?
    @State private var errorMessage: String?
    @State private var hasPrepared = false

    /// True from the moment this sheet asks the shared coordinator for a file until it closes.
    ///
    /// `ExportCoordinator` is shared across the app, so the flag makes sure this sheet only offers
    /// the document *it* asked for and never one another screen is waiting on.
    @State private var isAwaitingExport = false

    private static let contentMaxWidth: CGFloat = 560
    private static let qrSide: CGFloat = 240

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let errorMessage = errorMessage {
                        ErrorBanner(message: errorMessage,
                                    retryTitle: "Try again",
                                    onRetry: { prepare() },
                                    onDismiss: { self.errorMessage = nil })
                    }

                    // Only this sheet's own export failure: the coordinator is shared, so a
                    // failure raised by Settings must not surface here as if the tag had failed.
                    if isAwaitingExport, let exportError = appEnvironment.exports.lastError {
                        ErrorBanner(message: exportError,
                                    retryTitle: "Try again",
                                    onRetry: { prepare() },
                                    onDismiss: {
                                        appEnvironment.exports.clearError()
                                        isAwaitingExport = false
                                    })
                    }

                    if hasPrepared {
                        tagCard
                        detailCard
                        actionButtons
                    } else {
                        SectionCard {
                            HStack(spacing: Spacing.m) {
                                ProgressView()
                                Text("Building the bin tag…")
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Building the bin tag"))
                        }
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: BinTagSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .navigationTitle("Bin tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        releaseDocument()
                        dismiss()
                    }
                }
            }
        }
        .tint(Palette.accent)
        .task {
            guard !hasPrepared else { return }
            prepare()
        }
        // Also covers a swipe-down dismissal, so the shared coordinator is never left holding a
        // document that a later screen would pop a share sheet for.
        .onDisappear {
            releaseDocument()
        }
    }

    // MARK: - The tag itself

    private var tagCard: some View {
        SectionCard {
            VStack(spacing: Spacing.l) {
                if let qrImage = qrImage {
                    Image(uiImage: qrImage)
                        .resizable()
                        // Nearest-neighbour keeps the modules hard-edged when the symbol is scaled;
                        // smoothing them into grey ramps is what makes a printed tag fail to read.
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: BinTagSheet.qrSide, height: BinTagSheet.qrSide)
                        .padding(Spacing.m)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("QR code for " + item.displayTitle))
                        .accessibilityValue(Text("Scanning it opens this core in CoreCredit."))
                        .accessibilityAddTraits(.isImage)
                } else {
                    missingCodeNotice
                }

                VStack(spacing: Spacing.s) {
                    Text(item.displayTitle)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    MoneyLabel(item.expectedCredit, currencyCode: currencyCode, style: .prominent)
                        .accessibilityLabel(Text("Expected core credit"))
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Shown instead of an empty box when the symbol could not be produced.
    private var missingCodeNotice: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "qrcode")
                .font(.system(.largeTitle, design: .default, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text("The QR code couldn't be created.")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text("The tag still prints with the part details and the reference below, so it can be "
                 + "looked up by hand.")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Reference " + shortIdentifier)
                .font(Typography.money)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    // MARK: - Printed details, on screen

    private var detailCard: some View {
        SectionCard(title: "On the tag", systemImage: "qrcode") {
            VStack(spacing: Spacing.s) {
                LabeledValueRow("Part", value: item.displayTitle, symbol: "shippingbox")
                LabeledValueRow("Part no.", value: item.partNumber,
                                symbol: "number", isMonospaced: true)
                LabeledValueRow("Vendor", value: item.vendorName ?? "", symbol: "building.2")
                LabeledValueRow("Bin", value: item.binLabel ?? "", symbol: "tray.full")
                LabeledValueRow("Expected credit",
                                value: item.expectedCredit.formatted(currencyCode: currencyCode),
                                symbol: "dollarsign.circle",
                                isMonospaced: true)
                LabeledValueRow("Reference", value: shortIdentifier,
                                symbol: "barcode", isMonospaced: true)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: Spacing.m) {
            if let document = document {
                ShareLink(item: document.url) {
                    PrimaryButtonLabel("Share bin tag", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("Share bin tag"))
                .accessibilityHint(Text("Sends the tag as a PDF."))
            } else if isAwaitingExport && appEnvironment.exports.inFlight {
                HStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("Getting the tag ready to share…")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Getting the tag ready to share"))
            }

            if UIPrintInteractionController.isPrintingAvailable, pdfData != nil {
                Button {
                    printTag()
                } label: {
                    SheetActionLabel(title: "Print bin tag", systemImage: "printer")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Print bin tag"))
                .accessibilityHint(Text("Opens the system print sheet."))
            }
        }
    }

    // MARK: - Work

    /// Renders the QR symbol and the bytes the printer needs, then asks the shared coordinator for
    /// the shareable file. A `nil` QR is not a failure — the renderer prints the tag without it.
    private func prepare() {
        errorMessage = nil

        // Drop anything left over from a previous attempt so a retry can never offer the stale
        // file while the new one is still being written.
        appEnvironment.exports.clearError()
        appEnvironment.exports.dismiss()

        let payload = BinTagPayload(item: item)
        qrImage = QRCodeGenerator.image(for: payload.encodedString)

        do {
            // The raw name, not `displayName`: the renderer substitutes the app's own name when a
            // shop has not set one, which reads far better on a physical label than "Your shop".
            pdfData = try BinTagRenderer.makePDFData(item: item,
                                                     shopName: profile.name,
                                                     currencyCode: currencyCode,
                                                     qrImage: qrImage)
        } catch {
            pdfData = nil
            errorMessage = BinTagSheet.presentable(error)
        }

        // The file to share is written by `ExportCoordinator`, which owns naming, the caches
        // folder, the retention sweep, and the user-facing phrasing of any failure.
        isAwaitingExport = true
        let exports = appEnvironment.exports
        let core = item
        let shop = profile
        Task {
            await exports.exportBinTag(for: core, profile: shop)
        }

        hasPrepared = true
    }

    /// Lets go of the coordinator's document once this sheet is finished with it.
    private func releaseDocument() {
        guard isAwaitingExport else { return }
        isAwaitingExport = false
        appEnvironment.exports.dismiss()
    }

    /// Hands the rendered PDF to the system print sheet.
    ///
    /// The rect-and-view form is used wherever a host view can be found, because on iPad the plain
    /// modal form is not the supported presentation. Failing to find one falls back rather than
    /// leaving the button dead.
    private func printTag() {
        guard let data = pdfData else { return }
        guard UIPrintInteractionController.isPrintingAvailable else {
            errorMessage = "Printing isn't available on this device. Share the tag instead."
            return
        }

        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = "Bin tag — " + item.displayTitle

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data as NSData

        let completion: UIPrintInteractionController.CompletionHandler = { _, _, error in
            if let error = error {
                errorMessage = "The tag couldn't be printed. " + error.localizedDescription
            }
        }

        if let host = BinTagSheet.hostView() {
            let anchor = CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 1, height: 1)
            _ = controller.present(from: anchor, in: host, animated: true, completionHandler: completion)
        } else {
            _ = controller.present(animated: true, completionHandler: completion)
        }
    }

    // MARK: - Derived values

    /// The finished file, once the coordinator has written it — and only while this sheet is the
    /// one that asked for it.
    private var document: ExportDocument? {
        guard isAwaitingExport else { return nil }
        return appEnvironment.exports.presentedDocument
    }

    /// The shop profile, or a display-only default when the store has not created one yet.
    private var profile: ShopProfile {
        profiles.first ?? ShopProfile()
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? AppConfiguration.defaultCurrencyCode
    }

    /// The first eight characters of the item's identifier — the same short reference the printed
    /// tag carries, so a damaged code can still be looked up by hand.
    private var shortIdentifier: String {
        String(item.id.uuidString.prefix(8))
    }

    /// The topmost window's root view, used as the print sheet's anchor on iPad.
    private static func hostView() -> UIView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.keyWindow {
                return window
            }
        }
        return nil
    }

    /// Prefers an error's own sentence over a Cocoa domain and code.
    private static func presentable(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

// MARK: - Sheet action label

/// An outlined secondary action. Amber stays reserved for the one primary action on a screen.
@MainActor
private struct SheetActionLabel: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
