//
//  ReturnBatchTests.swift
//  CoreCreditTests
//
//  Required scenario 9: return batches cannot mix vendors, and a valid batch correctly updates
//  every selected item.
//

import Foundation
import SwiftData
import Testing
@testable import CoreCredit

@Suite("Return batches are single-vendor and move every core they carry")
struct ReturnBatchTests {

    private let returnDate = TestClock.date(year: 2026, month: 3, day: 14)

    // MARK: - Rejections

    @MainActor
    @Test("A batch holding cores from two vendors is rejected")
    func aBatchCannotMixVendors() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let oreilly = makeVendor(context: context, name: "O'Reilly", windowDays: 14)

        let alternator = try makeItem(context: context, service: itemService,
                                      partName: "Alternator", amountCents: 8_650, vendor: napa)
        let starter = try makeItem(context: context, service: itemService,
                                   partName: "Starter", amountCents: 5_400, vendor: oreilly)

        #expect(throws: DomainError.mixedVendorBatch) {
            try batchService.createBatch(vendor: napa,
                                         items: [alternator, starter],
                                         returnDate: returnDate,
                                         method: .driverPickup,
                                         reference: "RET-991",
                                         notes: "")
        }

        #expect(alternator.status == .awaitingCore)
        #expect(starter.status == .awaitingCore)
        #expect(alternator.returnBatch == nil)
        #expect(try batchService.allBatches().isEmpty)
    }

    @MainActor
    @Test("A core with no vendor at all cannot join a vendor's batch")
    func aCoreWithNoVendorCannotJoinABatch() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let orphan = try makeItem(context: context, service: itemService,
                                  partName: "Water pump", vendor: napa)
        orphan.vendor = nil

        #expect(throws: DomainError.mixedVendorBatch) {
            try batchService.createBatch(vendor: napa,
                                         items: [orphan],
                                         returnDate: returnDate,
                                         method: .counterDropOff,
                                         reference: "RET-992",
                                         notes: "")
        }
    }

    @MainActor
    @Test("An empty batch and a vendorless batch are both rejected")
    func emptyAndVendorlessBatchesAreRejected() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService, vendor: napa)

        #expect(throws: DomainError.emptyBatch) {
            try batchService.createBatch(vendor: napa, items: [], returnDate: returnDate,
                                         method: .shipped, reference: "RET-993", notes: "")
        }

        #expect(throws: DomainError.missingVendor) {
            try batchService.createBatch(vendor: nil, items: [alternator], returnDate: returnDate,
                                         method: .shipped, reference: "RET-993", notes: "")
        }
    }

    // MARK: - Scenario 9: a valid batch updates every selected item

    @MainActor
    @Test("Creating a batch moves every selected core to returned awaiting credit")
    func creatingABatchUpdatesEverySelectedCore() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService,
                                      partName: "Alternator", amountCents: 8_650, vendor: napa)
        let starter = try makeItem(context: context, service: itemService,
                                   partName: "Starter", amountCents: 5_400, vendor: napa)

        let batch = try batchService.createBatch(vendor: napa,
                                                 items: [alternator, starter],
                                                 returnDate: returnDate,
                                                 method: .driverPickup,
                                                 reference: "  RET-991  ",
                                                 notes: "Driver took two cores.")

        for item in [alternator, starter] {
            #expect(item.status == .returnedAwaitingCredit)
            #expect(item.returnedDate == returnDate)
            #expect(item.returnBatch?.id == batch.id)
            #expect(item.timeline.contains(where: { $0.type == .addedToBatch }))
            #expect(item.timeline.contains(where: { $0.type == .returned }))
        }

        #expect(batch.itemCount == 2)
        #expect(batch.reference == "RET-991")
        #expect(batch.notes == "Driver took two cores.")
        #expect(batch.method == .driverPickup)
        #expect(batch.vendor?.id == napa.id)
        #expect(batch.returnDate == returnDate)
        #expect(batch.totalExpectedCredit == Money(cents: 14_050))
        #expect(batch.outstandingCredit == Money(cents: 14_050))
        #expect(batch.isFullyCredited == false)
        #expect(batch.displayTitle == "NAPA \u{2014} 2 cores")
        #expect(batch.coreItems.map(\.partName) == ["Alternator", "Starter"])
        #expect(try batchService.allBatches().count == 1)
        #expect(try batchService.openBatches().count == 1)
    }

    @MainActor
    @Test("A batch stops being open once every core it holds is credited")
    func aBatchClosesWhenAllItsCoresAreCredited() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService,
                                      partName: "Alternator", amountCents: 8_650, vendor: napa)
        let starter = try makeItem(context: context, service: itemService,
                                   partName: "Starter", amountCents: 5_400, vendor: napa)

        let batch = try batchService.createBatch(vendor: napa, items: [alternator, starter],
                                                 returnDate: returnDate, method: .counterDropOff,
                                                 reference: "RET-991", notes: "")

        for item in [alternator, starter] {
            let reconciliation = CreditReconciliation(creditDate: returnDate,
                                                      reference: "CM-" + item.partName,
                                                      amount: item.expectedCredit)
            try itemService.recordCredit(item, reconciliation: reconciliation)
        }

        #expect(batch.isFullyCredited)
        #expect(batch.outstandingCredit == Money.zero)
        #expect(try batchService.openBatches().isEmpty)
        #expect(try batchService.allBatches().count == 1)
    }

    @MainActor
    @Test("A batch holding a written-off core is not treated as fully credited")
    func aWrittenOffCoreDoesNotCountAsSettled() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService,
                                      partName: "Alternator", amountCents: 8_650, vendor: napa)

        let batch = try batchService.createBatch(vendor: napa, items: [alternator],
                                                 returnDate: returnDate, method: .shipped,
                                                 reference: "RET-994", notes: "")

        try itemService.writeOff(alternator, reason: "Vendor lost it")

        #expect(alternator.status == .writtenOff)
        #expect(batch.outstandingCredit == Money.zero)
        #expect(batch.isFullyCredited == false)
    }

    // MARK: - Membership changes

    @MainActor
    @Test("A core already on another batch cannot be added to a second one")
    func aCoreCannotBeOnTwoBatchesAtOnce() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService,
                                      partName: "Alternator", vendor: napa)
        let starter = try makeItem(context: context, service: itemService,
                                   partName: "Starter", amountCents: 5_400, vendor: napa)

        try batchService.createBatch(vendor: napa, items: [alternator], returnDate: returnDate,
                                     method: .driverPickup, reference: "RET-991", notes: "")
        let second = try batchService.createBatch(vendor: napa, items: [starter], returnDate: returnDate,
                                                  method: .driverPickup, reference: "RET-992", notes: "")

        #expect(throws: DomainError.itemAlreadyInBatch("Alternator")) {
            try batchService.addItems([alternator], to: second)
        }
    }

    @MainActor
    @Test("Removing a core from a batch detaches it but leaves its status alone")
    func removingACoreLeavesItsStatusAlone() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService, vendor: napa)
        let batch = try batchService.createBatch(vendor: napa, items: [alternator],
                                                 returnDate: returnDate, method: .driverPickup,
                                                 reference: "RET-991", notes: "")

        try batchService.removeItem(alternator, from: batch)

        #expect(alternator.returnBatch == nil)
        #expect(alternator.status == .returnedAwaitingCredit)
        #expect(batch.itemCount == 0)
        #expect(alternator.timeline.contains(where: { $0.type == .removedFromBatch }))

        #expect(throws: DomainError.notFound) {
            try batchService.removeItem(alternator, from: batch)
        }
    }

    @MainActor
    @Test("Deleting a batch detaches its cores and keeps their status and history")
    func deletingABatchKeepsTheCores() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService, vendor: napa)
        let batch = try batchService.createBatch(vendor: napa, items: [alternator],
                                                 returnDate: returnDate, method: .driverPickup,
                                                 reference: "RET-991", notes: "")

        try batchService.delete(batch)

        #expect(try batchService.allBatches().isEmpty)
        #expect(try itemService.allItems().count == 1)
        #expect(alternator.returnBatch == nil)
        #expect(alternator.status == .returnedAwaitingCredit)
        #expect(alternator.timeline.contains(where: { $0.type == .removedFromBatch }))
    }

    @MainActor
    @Test("Editing a batch header never rewrites the cores' returned dates")
    func editingABatchHeaderLeavesItemHistoryAlone() throws {
        let context = try makeInMemoryContext()
        let itemService = makeItemService(context: context)
        let batchService = makeBatchService(context: context)

        let napa = makeVendor(context: context, name: "NAPA", windowDays: 30)
        let alternator = try makeItem(context: context, service: itemService, vendor: napa)
        let batch = try batchService.createBatch(vendor: napa, items: [alternator],
                                                 returnDate: returnDate, method: .driverPickup,
                                                 reference: "RET-991", notes: "")

        let laterDate = TestClock.date(year: 2026, month: 3, day: 16)
        try batchService.updateBatch(batch, returnDate: laterDate, method: .shipped,
                                     reference: " RET-991-A ", notes: "Corrected reference.")

        #expect(batch.returnDate == laterDate)
        #expect(batch.method == .shipped)
        #expect(batch.reference == "RET-991-A")
        #expect(batch.notes == "Corrected reference.")
        #expect(alternator.returnedDate == returnDate)
    }

    // MARK: - Return methods

    @Test("Return methods decode unknown raw values to Other")
    func returnMethodsDecodeSafely() {
        #expect(ReturnMethod.decoded(fromRawValue: "teleport") == .other)
        #expect(ReturnMethod.decoded(fromRawValue: "shipped") == .shipped)
        #expect(ReturnMethod.driverPickup.displayName == "Driver pickup")
        #expect(ReturnMethod.counterDropOff.displayName == "Counter drop-off")
        #expect(ReturnMethod.shipped.displayName == "Shipped")
        #expect(ReturnMethod.other.displayName == "Other")
        #expect(ReturnMethod.allCases.count == 4)
        #expect(ReturnMethod.shipped.id == "shipped")
    }
}
