//
//  StatusMachineTests.swift
//  CoreCreditTests
//
//  Required scenario 8: invalid status transitions are rejected by domain code — both by
//  `CoreStatusMachine.validate` and by `CoreItemService.transition`.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("The core status machine is the only door status changes can walk through")
struct StatusMachineTests {

    /// Wrapper so an unknown raw value is decoded inside a JSON object rather than as a fragment.
    private struct StatusEnvelope: Codable, Equatable {
        var status: CoreStatus
    }

    // MARK: - Transition table

    @Test("The canonical transition table is exactly as documented")
    func transitionTableMatchesTheContract() {
        #expect(CoreStatusMachine.allowedTransitions(from: .awaitingCore) == [.readyToReturn, .writtenOff])
        #expect(CoreStatusMachine.allowedTransitions(from: .readyToReturn)
            == [.returnedAwaitingCredit, .awaitingCore, .writtenOff])
        #expect(CoreStatusMachine.allowedTransitions(from: .returnedAwaitingCredit)
            == [.credited, .disputed, .readyToReturn, .writtenOff])
        #expect(CoreStatusMachine.allowedTransitions(from: .credited) == [.disputed, .returnedAwaitingCredit])
        #expect(CoreStatusMachine.allowedTransitions(from: .disputed)
            == [.credited, .writtenOff, .returnedAwaitingCredit])
        #expect(CoreStatusMachine.allowedTransitions(from: .writtenOff) == [.awaitingCore, .disputed])
    }

    @Test("A status can never transition to itself")
    func sameToSameIsAlwaysRejected() {
        for status in CoreStatus.allCases {
            #expect(CoreStatusMachine.canTransition(from: status, to: status) == false)
            #expect(CoreStatusMachine.allowedTransitions(from: status).contains(status) == false)
        }
    }

    @Test("Every move on the table validates without throwing")
    func everyListedMoveIsAccepted() throws {
        for from in CoreStatus.allCases {
            for to in CoreStatusMachine.allowedTransitions(from: from) {
                #expect(CoreStatusMachine.canTransition(from: from, to: to))
                try CoreStatusMachine.validate(from: from, to: to)
            }
        }
    }

    @Test("A move off the table throws DomainError.invalidTransition")
    func validateRejectsMovesOffTheTable() {
        #expect(throws: DomainError.invalidTransition(from: .awaitingCore, to: .credited)) {
            try CoreStatusMachine.validate(from: .awaitingCore, to: .credited)
        }
        #expect(throws: DomainError.invalidTransition(from: .awaitingCore, to: .returnedAwaitingCredit)) {
            try CoreStatusMachine.validate(from: .awaitingCore, to: .returnedAwaitingCredit)
        }
        #expect(throws: DomainError.invalidTransition(from: .credited, to: .writtenOff)) {
            try CoreStatusMachine.validate(from: .credited, to: .writtenOff)
        }
        #expect(throws: DomainError.invalidTransition(from: .writtenOff, to: .credited)) {
            try CoreStatusMachine.validate(from: .writtenOff, to: .credited)
        }
        #expect(throws: DomainError.invalidTransition(from: .disputed, to: .disputed)) {
            try CoreStatusMachine.validate(from: .disputed, to: .disputed)
        }
    }

    @Test("The invalid-transition error reads in plain shop English")
    func invalidTransitionErrorIsReadable() {
        let error = DomainError.invalidTransition(from: .awaitingCore, to: .credited)
        #expect(error.errorDescription == "You can't move an item from Awaiting old core to Credited.")
        #expect(error.recoverySuggestion == "Pick one of the statuses offered in the menu instead.")
    }

    @Test("Menu transitions are ordered by the display sort index")
    func userSelectableTransitionsAreOrdered() {
        #expect(CoreStatusMachine.userSelectableTransitions(from: .returnedAwaitingCredit)
            == [.readyToReturn, .credited, .disputed, .writtenOff])
        #expect(CoreStatusMachine.userSelectableTransitions(from: .awaitingCore)
            == [.readyToReturn, .writtenOff])
        #expect(CoreStatusMachine.userSelectableTransitions(from: .credited)
            == [.returnedAwaitingCredit, .disputed])
    }

    @Test("Only backward steps count as a reversal")
    func reversalsAreTheBackwardStepsOnly() {
        #expect(CoreStatusMachine.isReversal(from: .readyToReturn, to: .awaitingCore))
        #expect(CoreStatusMachine.isReversal(from: .returnedAwaitingCredit, to: .readyToReturn))
        #expect(CoreStatusMachine.isReversal(from: .credited, to: .returnedAwaitingCredit))
        #expect(CoreStatusMachine.isReversal(from: .disputed, to: .returnedAwaitingCredit))
        #expect(CoreStatusMachine.isReversal(from: .writtenOff, to: .awaitingCore))

        #expect(CoreStatusMachine.isReversal(from: .disputed, to: .credited) == false)
        #expect(CoreStatusMachine.isReversal(from: .awaitingCore, to: .readyToReturn) == false)
        #expect(CoreStatusMachine.isReversal(from: .awaitingCore, to: .credited) == false)
    }

    // MARK: - Forward-compatible decoding

    @Test("An unknown raw value falls back to awaiting old core")
    func unknownRawValuesFallBack() {
        #expect(CoreStatus.decoded(fromRawValue: "somethingFromTheFuture") == .awaitingCore)
        #expect(CoreStatus.decoded(fromRawValue: "") == .awaitingCore)
        #expect(CoreStatus.decoded(fromRawValue: "disputed") == .disputed)
    }

    @Test("Decoding an unknown raw value through JSONDecoder does not throw")
    func decodingAnUnknownRawValueDoesNotThrow() throws {
        let data = Data("{\"status\":\"somethingFromTheFuture\"}".utf8)
        let decoded = try JSONDecoder().decode(StatusEnvelope.self, from: data)
        #expect(decoded.status == .awaitingCore)

        let known = Data("{\"status\":\"returnedAwaitingCredit\"}".utf8)
        #expect(try JSONDecoder().decode(StatusEnvelope.self, from: known).status == .returnedAwaitingCredit)
    }

    @Test("Encoding still round-trips the real raw string")
    func encodingRoundTripsTheRawValue() throws {
        let encoded = try JSONEncoder().encode(StatusEnvelope(status: .writtenOff))
        #expect(utf8Text(encoded).contains("writtenOff"))
        #expect(try JSONDecoder().decode(StatusEnvelope.self, from: encoded).status == .writtenOff)
    }

    // MARK: - Status vocabulary

    @Test("Statuses partition cleanly into unresolved and closed")
    func statusesPartitionIntoUnresolvedAndClosed() {
        #expect(CoreStatus.unresolvedCases == [.awaitingCore, .readyToReturn, .returnedAwaitingCredit, .disputed])
        #expect(CoreStatus.closedCases == [.credited, .writtenOff])

        for status in CoreStatus.allCases {
            #expect(status.isClosed == !status.isUnresolved)
        }
        #expect(CoreStatus.disputed.isUnresolved)
        #expect(CoreStatus.credited.isClosed)
        #expect(CoreStatus.writtenOff.isClosed)
    }

    @Test("Status labels match the contract")
    func statusLabelsMatchTheContract() {
        #expect(CoreStatus.awaitingCore.displayName == "Awaiting old core")
        #expect(CoreStatus.readyToReturn.displayName == "Ready to return")
        #expect(CoreStatus.returnedAwaitingCredit.displayName == "Returned \u{2014} awaiting credit")
        #expect(CoreStatus.credited.displayName == "Credited")
        #expect(CoreStatus.disputed.displayName == "Disputed")
        #expect(CoreStatus.writtenOff.displayName == "Written off")

        #expect(CoreStatus.awaitingCore.shortName == "Awaiting")
        #expect(CoreStatus.readyToReturn.shortName == "Ready")
        #expect(CoreStatus.returnedAwaitingCredit.shortName == "Returned")
        #expect(CoreStatus.writtenOff.shortName == "Written off")

        #expect(CoreStatus.awaitingCore.symbolName == "shippingbox")
        #expect(CoreStatus.disputed.symbolName == "exclamationmark.triangle")
        #expect(CoreStatus.credited.id == "credited")
        #expect(CoreStatus.awaitingCore.sortIndex < CoreStatus.writtenOff.sortIndex)
        #expect(CoreStatus.returnedAwaitingCredit.accessibilityHint.isEmpty == false)
    }

    // MARK: - The service enforces the same table

    @MainActor
    @Test("The item service surfaces an illegal transition as DomainError.invalidTransition")
    func serviceRejectsAnIllegalTransition() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service)

        #expect(item.status == .awaitingCore)

        #expect(throws: DomainError.invalidTransition(from: .awaitingCore, to: .credited)) {
            try service.transition(item, to: .credited, detail: nil)
        }

        #expect(item.status == .awaitingCore)
        #expect(item.timeline.contains(where: { $0.type == .statusChanged }) == false)
    }

    @MainActor
    @Test("The item service refuses to re-save the status an item already has")
    func serviceRejectsASameToSameTransition() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service)

        #expect(throws: DomainError.invalidTransition(from: .awaitingCore, to: .awaitingCore)) {
            try service.transition(item, to: .awaitingCore, detail: nil)
        }
        #expect(item.timeline.filter({ $0.type == .statusChanged }).isEmpty)
    }

    @MainActor
    @Test("A legal transition records the move and stamps the returned date")
    func serviceRecordsALegalTransition() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service)

        try service.transition(item, to: .readyToReturn, detail: nil)
        #expect(item.status == .readyToReturn)
        #expect(item.returnedDate == nil)

        try service.transition(item, to: .returnedAwaitingCredit, detail: nil)
        #expect(item.status == .returnedAwaitingCredit)
        #expect(item.returnedDate == TestClock.referenceNow)

        try service.transition(item, to: .readyToReturn, detail: nil)
        #expect(item.status == .readyToReturn)
        #expect(item.returnedDate == nil)

        // Every event carries the same frozen timestamp, so assert on membership rather than order.
        let changes = item.timeline.filter { $0.type == .statusChanged }
        #expect(changes.count == 3)
        #expect(changes.contains(where: { $0.fromStatus == .awaitingCore && $0.toStatus == .readyToReturn }))
        #expect(changes.contains(where: { $0.fromStatus == .readyToReturn && $0.toStatus == .returnedAwaitingCredit }))
        #expect(changes.contains(where: { $0.fromStatus == .returnedAwaitingCredit && $0.toStatus == .readyToReturn }))
    }

    @MainActor
    @Test("Writing a core off from an ineligible status is rejected")
    func writeOffRespectsTheTransitionTable() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service)

        try creditInFull(item, service: service)
        #expect(item.status == .credited)

        #expect(throws: DomainError.invalidTransition(from: .credited, to: .writtenOff)) {
            try service.writeOff(item, reason: "Vendor refused it")
        }
        #expect(item.status == .credited)
    }
}
