//
//  CoreDetailModel.swift
//  CoreCredit
//

import Foundation
import Observation

/// View state for `CoreDetailView`: which sheet is up, whether this screen is the one waiting on an
/// export, whether the record has been deleted, and the last error.
///
/// No mutation lives here. Every write goes through `CoreItemService`, which is the only thing that
/// can append to a core's timeline — the detail screen's job is to decide *what* to ask for and to
/// show what came back, including the failures.
@MainActor
@Observable
final class CoreDetailModel {

    // MARK: - Routing

    /// The modal this screen currently has open. `nil` means the detail screen itself is in front.
    ///
    /// One enum, presented by a single `.sheet(item:)`, rather than a separate boolean per sheet:
    /// two `.sheet` modifiers attached to the *same* view can shadow one another, so only one of
    /// them would ever present. Each case carries its own `id`, so moving straight from one sheet
    /// to another is a change of identity and re-presents.
    enum Route: Identifiable {

        /// The core editor, opened on this record.
        case editor

        /// Recording the vendor's credit memo against this core.
        case credit

        /// The printable shelf label.
        case binTag

        /// The finished dispute packet, waiting to be shared. Carries the document so a second
        /// packet built in the same session is a different identity and re-presents.
        case export(ExportDocument)

        var id: String {
            switch self {
            case .editor:
                return "editor"
            case .credit:
                return "credit"
            case .binTag:
                return "binTag"
            case .export(let document):
                return "export." + document.id.uuidString
            }
        }
    }

    /// Which sheet this screen has asked for, if any.
    ///
    /// `.export` is never stored here: the finished document lives on the shared
    /// `ExportCoordinator`, so the view derives that case from `isAwaitingExport` and
    /// `presentedDocument` instead of duplicating it.
    var route: Route?

    /// True from the moment this screen asks for a dispute packet until the share sheet closes.
    ///
    /// `ExportCoordinator` is shared across the app, so the flag makes sure this screen only
    /// presents the document *it* asked for and never steals one another screen is waiting on.
    var isAwaitingExport = false

    /// Set the instant the record is deleted, so `body` stops reading a `CoreItem` that is no
    /// longer in the store while the dismiss animation runs.
    var isDeleted = false

    var errorMessage: String?

    init() { }

    // MARK: - Status action copy

    /// The button title for a status move.
    ///
    /// Reversals are labelled as an undo rather than as a new step, because moving a core *back*
    /// from "returned" to "ready" means it never actually went back, and the wording should say so.
    /// The available moves themselves always come from `CoreStatusMachine`, never from this file.
    func transitionTitle(from current: CoreStatus, to target: CoreStatus) -> String {
        if CoreStatusMachine.isReversal(from: current, to: target) {
            return "Undo — back to " + target.displayName.lowercased()
        }
        if target == .writtenOff {
            return "Write this core off"
        }
        return "Mark " + target.displayName.lowercased()
    }

    /// Spoken explanation of what a status move does to the ledger.
    func transitionHint(to target: CoreStatus) -> String {
        target.accessibilityHint
    }

    // MARK: - Errors

    func present(_ error: any Error) {
        errorMessage = CoreDetailModel.message(for: error)
    }

    func clearError() {
        errorMessage = nil
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
                return description + " " + suggestion
            }
            return description
        }
        return error.localizedDescription
    }
}
