//
//  OnboardingView.swift
//  CoreCredit
//
//  First launch: what this app does, who the shop is, and where cores go back to.
//

import SwiftData
import SwiftUI
import UIKit

/// The first-launch flow.
///
/// Three pages explaining the core-return workflow, then the shop's name and printing details,
/// then an optional first vendor. That is the whole thing: no account, no marketing, and no
/// permission prompts. The camera, photo library, and notification prompts are asked for later,
/// at the moment the owner uses those features, because iOS only offers each prompt once and a
/// prompt nobody understands is a prompt that gets denied.
///
/// Setup finishes by writing the shop profile through `CoreItemService`, which flips
/// `hasCompletedOnboarding`. `RootView` observes that with `@Query` and swaps in the tab bar, so
/// this view never has to dismiss itself.
struct OnboardingView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @State private var model = OnboardingModel()

    /// Declared explicitly rather than relying on the synthesized memberwise initializer, whose
    /// access level would otherwise be tied to this view's `private` stored properties.
    init() { }

    var body: some View {
        ZStack {
            Palette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                progressHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        if let message = model.errorMessage {
                            ErrorBanner(message: message, onDismiss: { model.clearError() })
                        }

                        stepContent
                    }
                    .padding(Spacing.l)
                    .frame(maxWidth: OnboardingView.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                footer
            }
        }
        // Same reason as `CoreListView`: this root is a `ZStack`, which is not an accessibility
        // element, so `onboarding.root` propagated down and overwrote the footer button's
        // `onboarding.next`. The progress header was still found by its label — labels are not
        // affected — which is why the suite could assert "Step 1 of 5" and then time out looking
        // for the button directly beneath it. `.contain` gives the identifier somewhere to bind
        // and keeps the header, the step content, and both footer buttons individually exposed.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Onboarding.root)
    }

    private static let contentMaxWidth: CGFloat = 560

    // MARK: - Progress

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(model.progressText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            HStack(spacing: Spacing.xs) {
                ForEach(OnboardingStep.allCases) { step in
                    Capsule(style: .continuous)
                        .fill(step.rawValue <= model.step.rawValue ? Palette.accent : Palette.hairline)
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.l)
        .frame(maxWidth: OnboardingView.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.progressText))
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        if let page = model.workflowPage {
            workflowContent(page)
        } else if model.step == .shopDetails {
            shopDetailsContent
        } else {
            vendorContent
        }
    }

    private func workflowContent(_ page: OnboardingWorkflowPage) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Image(systemName: page.symbolName)
                .font(.system(.largeTitle, design: .default, weight: .regular))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            Text(page.title)
                .font(Typography.hero)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(page.lead)
                .font(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SectionCard {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(page.points.indices, id: \.self) { index in
                        pointRow(number: index + 1, text: page.points[index])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pointRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(String(number))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Palette.onAccent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.accent))
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shop details

    private var shopDetailsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            heading(
                title: "Who is the shop?",
                lead: "This is what a vendor sees at the top of a printed dispute packet or a "
                    + "ledger export. Only the name is required — the rest can wait."
            )

            SectionCard(title: "Shop", systemImage: "building.2") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    OnboardingTextField(
                        title: "Shop name",
                        placeholder: "Miller's Diesel Service",
                        text: $model.shopName,
                        identifier: A11y.Onboarding.shopName,
                        contentType: .organizationName,
                        autocapitalization: .words,
                        footnote: "Required. Printed on everything you send a vendor."
                    )

                    OnboardingTextField(
                        title: "Phone",
                        placeholder: "Optional",
                        text: $model.phone,
                        contentType: .telephoneNumber,
                        keyboardType: .phonePad,
                        autocapitalization: .never
                    )

                    OnboardingTextField(
                        title: "Email",
                        placeholder: "Optional",
                        text: $model.email,
                        contentType: .emailAddress,
                        keyboardType: .emailAddress,
                        autocapitalization: .never,
                        disablesAutocorrection: true
                    )
                }
            }

            SectionCard(title: "Address", systemImage: "mappin.and.ellipse") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    OnboardingTextField(
                        title: "Street",
                        placeholder: "Optional",
                        text: $model.addressLine1,
                        contentType: .streetAddressLine1,
                        autocapitalization: .words
                    )

                    OnboardingTextField(
                        title: "City",
                        placeholder: "Optional",
                        text: $model.city,
                        contentType: .addressCity,
                        autocapitalization: .words
                    )

                    OnboardingTextField(
                        title: "State or region",
                        placeholder: "Optional",
                        text: $model.region,
                        contentType: .addressState,
                        autocapitalization: .words
                    )

                    OnboardingTextField(
                        title: "ZIP or postal code",
                        placeholder: "Optional",
                        text: $model.postalCode,
                        contentType: .postalCode,
                        keyboardType: .numbersAndPunctuation,
                        autocapitalization: .characters,
                        disablesAutocorrection: true
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - First vendor

    private var vendorContent: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            heading(
                title: "Where do cores go back to?",
                lead: "Add the supplier you return the most cores to. The return window sets the "
                    + "due date on every core you log against them. You can add more vendors, and "
                    + "change this one, in Settings."
            )

            SectionCard(title: "First vendor", systemImage: "building.2") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    OnboardingTextField(
                        title: "Vendor name",
                        placeholder: "NAPA",
                        text: $model.vendorName,
                        autocapitalization: .words,
                        footnote: "Leave this empty, or tap Skip, to add vendors later."
                    )

                    Stepper(value: $model.vendorReturnWindowDays,
                            in: DueDateCalculator.minimumWindowDays...DueDateCalculator.maximumWindowDays) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Return window")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)

                            Text(returnWindowText)
                                .font(Typography.rowTitle)
                                .foregroundStyle(Palette.textPrimary)
                        }
                    }
                    .frame(minHeight: Spacing.minimumTapTarget)
                    .accessibilityLabel(Text("Return window in days"))
                    .accessibilityValue(Text(returnWindowText))
                    .accessibilityHint(Text("How long this vendor gives you to send the old part back."))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var returnWindowText: String {
        let days = model.vendorReturnWindowDays
        return String(days) + (days == 1 ? " day" : " days")
    }

    private func heading(title: String, lead: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title)
                .font(Typography.hero)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(lead)
                .font(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Spacing.m) {
            Button(action: primaryAction) {
                PrimaryButtonLabel(primaryTitle, systemImage: primarySymbol)
            }
            .buttonStyle(.plain)
            .disabled(model.isSaving)
            .accessibilityIdentifier(model.isFinalStep ? A11y.Onboarding.finish : A11y.Onboarding.next)
            .accessibilityHint(Text(primaryHint))

            HStack(spacing: Spacing.l) {
                if !model.isFirstStep {
                    Button {
                        model.goBack()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "chevron.left")
                                .imageScale(.small)
                            Text("Back")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(Palette.textSecondary)
                        .frame(minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                if model.isFinalStep {
                    Button {
                        finishSetup(creatingVendor: false)
                    } label: {
                        Text("Skip for now")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: Spacing.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(A11y.Onboarding.skip)
                    .accessibilityHint(Text("Finishes setup without adding a vendor."))
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: OnboardingView.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
        }
    }

    private var primaryTitle: String {
        if model.isFinalStep { return "Finish setup" }
        if model.step == .shopDetails { return "Continue" }
        return "Next"
    }

    private var primarySymbol: String {
        model.isFinalStep ? "checkmark" : "arrow.right"
    }

    private var primaryHint: String {
        if model.isFinalStep {
            return "Saves your shop details and opens CoreCredit."
        }
        if model.step == .shopDetails {
            return "Saves nothing yet. Moves on to your first vendor."
        }
        return "Moves to the next page."
    }

    private func primaryAction() {
        if model.isFinalStep {
            finishSetup(creatingVendor: true)
        } else {
            model.advance()
        }
    }

    /// Writes the profile — and the vendor, unless skipped — through the audited service.
    ///
    /// The result is inspected by `OnboardingModel`, which either clears the error or shows one;
    /// on success `RootView` swaps this view for the tab bar on the next update.
    private func finishSetup(creatingVendor: Bool) {
        let service = appEnvironment.itemService(modelContext)
        _ = model.finish(creatingVendor: creatingVendor, using: service)
    }
}

// MARK: - Text field

/// A labelled text field sized for a shop floor: 44pt tall, label above rather than inside, and a
/// footnote slot for the one thing the owner needs to know about the field.
private struct OnboardingTextField: View {

    private let title: String
    private let placeholder: String
    @Binding private var text: String
    private let identifier: String?
    private let contentType: UITextContentType?
    private let keyboardType: UIKeyboardType
    private let autocapitalization: TextInputAutocapitalization
    private let disablesAutocorrection: Bool
    private let footnote: String?

    init(title: String,
         placeholder: String,
         text: Binding<String>,
         identifier: String? = nil,
         contentType: UITextContentType? = nil,
         keyboardType: UIKeyboardType = .default,
         autocapitalization: TextInputAutocapitalization = .sentences,
         disablesAutocorrection: Bool = false,
         footnote: String? = nil) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.identifier = identifier
        self.contentType = contentType
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
        self.disablesAutocorrection = disablesAutocorrection
        self.footnote = footnote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .textContentType(contentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disablesAutocorrection)
                .submitLabel(.next)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Spacing.minimumTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .fill(Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.fieldBorder, lineWidth: 1)
                )
                .accessibilityLabel(Text(title))
                .modifier(OptionalAccessibilityIdentifier(identifier: identifier))

            if let footnote = footnote {
                Text(footnote)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Applies an accessibility identifier only when one was supplied, so fields the UI tests do not
/// query stay free of invented identifier strings.
private struct OptionalAccessibilityIdentifier: ViewModifier {

    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier = identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
