//
//  OnboardingModel.swift
//  CoreCredit
//

import Foundation
import Observation

/// The steps of first-launch setup, in order.
///
/// Three short pages explaining the workflow, then the two things the app genuinely needs: who
/// the shop is, and — optionally — the first vendor cores go back to.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {

    /// Log the core charge the moment the part is bought.
    case coreCharge

    /// Label the old part and get it back to the vendor.
    case labelAndReturn

    /// Confirm the credit actually lands.
    case confirmCredit

    /// Shop name and the details that appear on printed reports.
    case shopDetails

    /// First vendor and its return window. Skippable.
    case firstVendor

    var id: Int { rawValue }

    /// True for the explanatory pages, false for the two that collect information.
    var isWorkflowPage: Bool {
        switch self {
        case .coreCharge, .labelAndReturn, .confirmCredit:
            return true
        case .shopDetails, .firstVendor:
            return false
        }
    }
}

/// One explanatory page: a heading, a sentence, and the concrete things that happen at that stage.
struct OnboardingWorkflowPage: Equatable, Sendable {
    var symbolName: String
    var title: String
    var lead: String
    var points: [String]
}

/// State and rules for the first-launch flow.
///
/// # What this flow deliberately does not do
///
/// There is no account, no sign-in, and no permission wall. CoreCredit stores everything on the
/// device, so there is nothing to sign into; and the camera, photo, and notification prompts are
/// asked for in context, at the moment the owner uses those features. A setup flow that opens
/// with three system prompts teaches people to tap Don't Allow.
///
/// The only required field in the whole flow is the shop name, because it is printed at the top
/// of every dispute packet and ledger export.
@MainActor
@Observable
final class OnboardingModel {

    // MARK: - Position

    var step: OnboardingStep = .coreCharge

    // MARK: - Shop profile

    var shopName: String = ""
    var phone: String = ""
    var email: String = ""
    var addressLine1: String = ""
    var city: String = ""
    var region: String = ""
    var postalCode: String = ""

    // MARK: - First vendor

    var vendorName: String = ""
    var vendorReturnWindowDays: Int = AppConfiguration.defaultVendorReturnWindowDays

    // MARK: - Status

    private(set) var errorMessage: String?
    private(set) var isSaving: Bool = false

    init() { }

    // MARK: - Derived

    var trimmedShopName: String {
        shopName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedVendorName: String {
        vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stepNumber: Int { step.rawValue + 1 }

    var stepCount: Int { OnboardingStep.allCases.count }

    /// Spoken and displayed progress, e.g. "Step 4 of 5".
    var progressText: String {
        "Step " + String(stepNumber) + " of " + String(stepCount)
    }

    var isFinalStep: Bool { step == .firstVendor }

    var isFirstStep: Bool { step == .coreCharge }

    /// The shop name is the one thing setup cannot finish without.
    var canAdvance: Bool {
        switch step {
        case .shopDetails:
            return !trimmedShopName.isEmpty
        case .coreCharge, .labelAndReturn, .confirmCredit, .firstVendor:
            return true
        }
    }

    /// Copy for the current explanatory page, or `nil` on the two form steps.
    var workflowPage: OnboardingWorkflowPage? {
        switch step {
        case .coreCharge:
            return OnboardingWorkflowPage(
                symbolName: "dollarsign.circle",
                title: "A core charge is your money, held",
                lead: "The supplier adds a core charge to the invoice and gives it back when the "
                    + "old part comes in. Until then it is your cash sitting on their books.",
                points: [
                    "Log the core the day the part comes in: amount, vendor, invoice, and repair order.",
                    "Photograph the invoice line so the amount is never a memory.",
                    "CoreCredit sets the due date from the vendor's return window."
                ]
            )
        case .labelAndReturn:
            return OnboardingWorkflowPage(
                symbolName: "tray.full",
                title: "Label the old part, then send it back",
                lead: "Cores get lost between the bay and the shelf. A tag on the part and a bin "
                    + "on the record is what makes it findable a month later.",
                points: [
                    "Print a bin tag with the part, the vendor, and a scannable code.",
                    "Mark the core ready when the old part is off the vehicle and boxed.",
                    "Batch a vendor's cores together and record how they went back."
                ]
            )
        case .confirmCredit:
            return OnboardingWorkflowPage(
                symbolName: "checkmark.seal",
                title: "Confirm the credit actually arrives",
                lead: "Returning the core is not the end of it. The credit has to appear on a "
                    + "statement, for the amount you were charged.",
                points: [
                    "Record the credit when it lands, with its credit-memo reference.",
                    "A short credit is flagged as disputed instead of quietly closed.",
                    "Export a dispute packet — invoice, photos, dates, history — in one tap."
                ]
            )
        case .shopDetails, .firstVendor:
            return nil
        }
    }

    // MARK: - Navigation

    /// Moves to the next step. Refuses, with a message, when the current step is incomplete.
    func advance() {
        guard canAdvance else {
            errorMessage = OnboardingModel.missingShopNameMessage
            return
        }
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        errorMessage = nil
        step = next
    }

    func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        errorMessage = nil
        step = previous
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Finishing

    /// Writes the shop profile — and, when asked, the first vendor — and marks setup complete.
    ///
    /// The vendor is created first on purpose: if that write fails, setup is *not* marked
    /// complete, so the owner stays on this screen with a message rather than landing on an empty
    /// dashboard wondering where their vendor went.
    ///
    /// - Parameters:
    ///   - creatingVendor: `false` when the owner skipped the vendor step.
    ///   - service: The audited mutation service, built against the view's `ModelContext`.
    /// - Returns: `true` when everything was saved.
    func finish(creatingVendor: Bool, using service: CoreItemService) -> Bool {
        guard isSaving == false else { return false }

        guard !trimmedShopName.isEmpty else {
            step = .shopDetails
            errorMessage = OnboardingModel.missingShopNameMessage
            return false
        }

        isSaving = true
        defer { isSaving = false }

        do {
            if creatingVendor && !trimmedVendorName.isEmpty {
                try service.createVendor(
                    name: trimmedVendorName,
                    returnWindowDays: DueDateCalculator.clampWindowDays(vendorReturnWindowDays)
                )
            }

            let profile = try service.shopProfile()
            profile.name = trimmedShopName
            profile.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.addressLine1 = addressLine1.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.postalCode = postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.hasCompletedOnboarding = true
            try service.updateShopProfile(profile)

            errorMessage = nil
            return true
        } catch {
            errorMessage = OnboardingModel.message(for: error)
            return false
        }
    }

    // MARK: - Copy

    static let missingShopNameMessage =
        "Enter your shop's name. It goes at the top of every report you send a vendor."

    /// Prefers a `LocalizedError`'s own sentence, so a `DomainError` reads as written instead of
    /// as an error domain and code.
    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
