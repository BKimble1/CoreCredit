//
//  CreditReconciliationTests.swift
//  CoreCreditTests
//
//  Required scenarios 1–4:
//    1. An $86.50 unresolved core makes Money at Risk equal $86.50.
//    2. Awaiting old core → Ready to return → Returned — awaiting credit does NOT clear it.
//    3. An exact $86.50 credit closes it and drops Money at Risk to zero.
//    4. A $75.00 credit against $86.50 yields an $11.50 discrepancy and a Disputed item.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("Recording vendor credits against the core charge")
struct CreditReconciliationTests {

    private let calendar = TestClock.calendar
    private let now = TestClock.referenceNow

    // MARK: - Pure reconciliation

    @Test("An identical credit is an exact match")
    func anIdenticalCreditIsExact() {
        let outcome = CreditReconciler.outcome(expected: Money(cents: 8_650), actual: Money(cents: 8_650))
        #expect(outcome == .exact)
        #expect(outcome.isDiscrepancy == false)
        #expect(outcome.difference == Money.zero)
        #expect(outcome.summaryText == "Credited in full")
        #expect(CreditReconciler.resultingStatus(for: outcome) == .credited)
    }

    @Test("A short credit reports a positive difference and opens a dispute")
    func aShortCreditOpensADispute() {
        let outcome = CreditReconciler.outcome(expected: Money(cents: 8_650), actual: Money(cents: 7_500))
        #expect(outcome == .short(difference: Money(cents: 1_150)))
        #expect(outcome.isDiscrepancy)
        #expect(outcome.difference == Money(cents: 1_150))
        #expect(outcome.summaryText == "Short by ")
        #expect(CreditReconciler.resultingStatus(for: outcome) == .disputed)
    }

    @Test("An over-credit reports a positive difference but still closes as credited")
    func anOverCreditClosesTheItem() {
        let outcome = CreditReconciler.outcome(expected: Money(cents: 8_650), actual: Money(cents: 9_000))
        #expect(outcome == .over(difference: Money(cents: 350)))
        #expect(outcome.isDiscrepancy)
        #expect(outcome.difference == Money(cents: 350))
        #expect(outcome.summaryText == "Over by ")
        #expect(CreditReconciler.resultingStatus(for: outcome) == .credited)
    }

    // MARK: - Scenario 1

    @MainActor
    @Test("Adding an $86.50 unresolved core makes money at risk equal $86.50")
    func addingAnEightySixFiftyCoreMakesMoneyAtRiskEightySixFifty() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)

        let item = try makeItem(context: context, service: service, amountCents: 8_650)
        #expect(item.expectedCredit == Money(cents: 8_650))
        #expect(item.status == .awaitingCore)

        let stored = try service.allItems()
        let summary = RiskCalculator.summarize(stored, now: now, calendar: calendar)
        #expect(summary.moneyAtRisk == Money(cents: 8_650))
        #expect(summary.unresolvedCount == 1)
    }

    // MARK: - Scenario 2

    @MainActor
    @Test("Awaiting → Ready to return → Returned awaiting credit never removes the money at risk")
    func walkingTheReturnCycleKeepsTheMoneyAtRisk() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service, amountCents: 8_650)

        func moneyAtRisk() throws -> Money {
            let stored = try service.allItems()
            return RiskCalculator.summarize(stored, now: now, calendar: calendar).moneyAtRisk
        }

        #expect(item.status == .awaitingCore)
        #expect(try moneyAtRisk() == Money(cents: 8_650))

        try service.transition(item, to: .readyToReturn, detail: nil)
        #expect(item.status == .readyToReturn)
        #expect(try moneyAtRisk() == Money(cents: 8_650))

        try service.transition(item, to: .returnedAwaitingCredit, detail: nil)
        #expect(item.status == .returnedAwaitingCredit)
        #expect(item.status.isUnresolved)
        #expect(try moneyAtRisk() == Money(cents: 8_650))
        #expect(RiskCalculator.remainingExposure(for: item) == Money(cents: 8_650))
        #expect(try service.unresolvedCount() == 1)
    }

    // MARK: - Scenario 3

    @MainActor
    @Test("An exact $86.50 credit closes the core and drops money at risk to zero")
    func anExactCreditClosesTheCore() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service, amountCents: 8_650)

        try service.transition(item, to: .readyToReturn, detail: nil)
        try service.transition(item, to: .returnedAwaitingCredit, detail: nil)

        let reconciliation = CreditReconciliation(
            creditDate: TestClock.date(year: 2026, month: 3, day: 20),
            reference: "CM-4471",
            amount: Money(cents: 8_650)
        )
        let outcome = try service.recordCredit(item, reconciliation: reconciliation)

        #expect(outcome == .exact)
        #expect(item.status == .credited)
        #expect(item.status.isClosed)
        #expect(item.actualCredit == Money(cents: 8_650))
        #expect(item.creditReference == "CM-4471")
        #expect(item.creditedDate == TestClock.date(year: 2026, month: 3, day: 20))
        #expect(RiskCalculator.remainingExposure(for: item) == Money.zero)

        let stored = try service.allItems()
        let summary = RiskCalculator.summarize(stored, now: now, calendar: calendar)
        #expect(summary.moneyAtRisk == Money.zero)
        #expect(summary.unresolvedCount == 0)
        #expect(try service.unresolvedCount() == 0)
        #expect(item.timeline.contains(where: { $0.type == .creditRecorded }))
        #expect(item.timeline.contains(where: { $0.type == .disputeOpened }) == false)
    }

    // MARK: - Scenario 4

    @MainActor
    @Test("A $75.00 credit against $86.50 leaves an $11.50 discrepancy on a disputed core")
    func aShortCreditLeavesElevenFiftyDisputed() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service, amountCents: 8_650)

        try service.transition(item, to: .readyToReturn, detail: nil)
        try service.transition(item, to: .returnedAwaitingCredit, detail: nil)

        let reconciliation = CreditReconciliation(
            creditDate: TestClock.date(year: 2026, month: 3, day: 20),
            reference: "CM-4471",
            amount: Money(cents: 7_500)
        )
        let outcome = try service.recordCredit(item, reconciliation: reconciliation)

        #expect(outcome == .short(difference: Money(cents: 1_150)))
        #expect(item.status == .disputed)
        #expect(item.status.isUnresolved)
        #expect(item.actualCredit == Money(cents: 7_500))
        #expect(RiskCalculator.discrepancy(for: item) == Money(cents: 1_150))
        #expect(RiskCalculator.remainingExposure(for: item) == Money(cents: 1_150))

        let stored = try service.allItems()
        let summary = RiskCalculator.summarize(stored, now: now, calendar: calendar)
        #expect(summary.moneyAtRisk == Money(cents: 1_150))
        #expect(summary.unresolvedCount == 1)

        let disputeEvents = item.timeline.filter { $0.type == .disputeOpened }
        #expect(disputeEvents.count == 1)
        #expect(disputeEvents.contains(where: { $0.amount == Money(cents: 1_150) }))
    }

    // MARK: - Guard rails

    @MainActor
    @Test("A credit cannot be recorded against a core that never went back")
    func recordingACreditTooEarlyIsRejected() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service)

        let reconciliation = CreditReconciliation(
            creditDate: now, reference: "CM-1", amount: Money(cents: 8_650)
        )

        #expect(throws: DomainError.invalidTransition(from: .awaitingCore, to: .credited)) {
            try service.recordCredit(item, reconciliation: reconciliation)
        }
        #expect(item.status == .awaitingCore)
        #expect(item.actualCredit == nil)
    }

    @MainActor
    @Test("A short credit can be re-recorded on an already disputed core")
    func aDisputedCoreAcceptsACorrectedCredit() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service, amountCents: 8_650)

        try service.transition(item, to: .readyToReturn, detail: nil)
        try service.transition(item, to: .returnedAwaitingCredit, detail: nil)
        try service.recordCredit(item, reconciliation: CreditReconciliation(
            creditDate: now, reference: "CM-1", amount: Money(cents: 7_500)))
        #expect(item.status == .disputed)

        let corrected = try service.recordCredit(item, reconciliation: CreditReconciliation(
            creditDate: now, reference: "CM-2", amount: Money(cents: 8_650)))

        #expect(corrected == .exact)
        #expect(item.status == .credited)
        #expect(item.creditReference == "CM-2")
        #expect(RiskCalculator.remainingExposure(for: item) == Money.zero)
    }

    @MainActor
    @Test("Clearing a recorded credit reopens the core as returned awaiting credit")
    func clearingARecordedCreditReopensTheCore() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service, amountCents: 8_650)

        try creditInFull(item, service: service, reference: "CM-4471")
        #expect(item.status == .credited)

        try service.clearRecordedCredit(item)

        #expect(item.status == .returnedAwaitingCredit)
        #expect(item.actualCredit == nil)
        #expect(item.creditedDate == nil)
        #expect(item.creditReference == "")
        #expect(RiskCalculator.remainingExposure(for: item) == Money(cents: 8_650))
        #expect(item.timeline.contains(where: { $0.type == .reopened }))
    }

    @MainActor
    @Test("A written-off core stops counting toward money at risk")
    func writingOffClosesTheExposure() throws {
        let context = try makeInMemoryContext()
        let service = makeItemService(context: context)
        let item = try makeItem(context: context, service: service, amountCents: 8_650)

        try service.writeOff(item, reason: "Vendor lost the core")

        let stored = try service.allItems()
        #expect(item.status == .writtenOff)
        #expect(RiskCalculator.remainingExposure(for: item) == Money.zero)
        #expect(RiskCalculator.summarize(stored, now: now, calendar: calendar).moneyAtRisk == Money.zero)
        #expect(item.timeline.contains(where: { $0.type == .writtenOff && $0.detail == "Vendor lost the core" }))
    }
}
