//
//  CoreStatusMachine.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// The one and only definition of which status changes are legal.
///
/// Every write path (`CoreItemService.transition`, batch creation, credit recording) runs through
/// here, so the timeline can never contain a jump that the UI would not have offered.
enum CoreStatusMachine {

    /// Canonical transition table.
    ///
    /// - `awaitingCore` -> `readyToReturn`, `writtenOff`
    /// - `readyToReturn` -> `returnedAwaitingCredit`, `awaitingCore`, `writtenOff`
    /// - `returnedAwaitingCredit` -> `credited`, `disputed`, `readyToReturn`, `writtenOff`
    /// - `credited` -> `disputed`, `returnedAwaitingCredit`
    /// - `disputed` -> `credited`, `writtenOff`, `returnedAwaitingCredit`
    /// - `writtenOff` -> `awaitingCore`, `disputed`
    ///
    /// A status is never listed as a destination from itself; see `canTransition(from:to:)`.
    static func allowedTransitions(from status: CoreStatus) -> Set<CoreStatus> {
        switch status {
        case .awaitingCore:
            return [.readyToReturn, .writtenOff]
        case .readyToReturn:
            return [.returnedAwaitingCredit, .awaitingCore, .writtenOff]
        case .returnedAwaitingCredit:
            return [.credited, .disputed, .readyToReturn, .writtenOff]
        case .credited:
            return [.disputed, .returnedAwaitingCredit]
        case .disputed:
            return [.credited, .writtenOff, .returnedAwaitingCredit]
        case .writtenOff:
            return [.awaitingCore, .disputed]
        }
    }

    /// Same-status "transitions" are rejected: re-saving a status must not append a timeline entry.
    static func canTransition(from: CoreStatus, to: CoreStatus) -> Bool {
        if from == to { return false }
        return allowedTransitions(from: from).contains(to)
    }

    /// Throws `DomainError.invalidTransition` when the move is not on the table.
    static func validate(from: CoreStatus, to: CoreStatus) throws {
        guard canTransition(from: from, to: to) else {
            throw DomainError.invalidTransition(from: from, to: to)
        }
    }

    /// Ordered list for menus — the allowed set sorted by `CoreStatus.sortIndex`.
    static func userSelectableTransitions(from status: CoreStatus) -> [CoreStatus] {
        allowedTransitions(from: status).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// True when the transition walks the cycle backwards and is therefore safe to label "Undo".
    ///
    /// This is an explicit list rather than a comparison of `sortIndex`, because `disputed ->
    /// credited` moves to a lower index but is a *resolution*, not an undo.
    static func isReversal(from: CoreStatus, to: CoreStatus) -> Bool {
        guard canTransition(from: from, to: to) else { return false }
        switch (from, to) {
        case (.readyToReturn, .awaitingCore),
             (.returnedAwaitingCredit, .readyToReturn),
             (.credited, .returnedAwaitingCredit),
             (.disputed, .returnedAwaitingCredit),
             (.writtenOff, .awaitingCore):
            return true
        default:
            return false
        }
    }
}
