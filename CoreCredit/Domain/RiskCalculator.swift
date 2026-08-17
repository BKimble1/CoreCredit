//
//  RiskCalculator.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//

import Foundation

/// One aging bucket's slice of the outstanding money.
struct AgingBucketSummary: Equatable, Sendable, Identifiable {
    var bucket: AgingBucket
    var count: Int
    var amount: Money

    var id: String { bucket.rawValue }
}

/// Everything the dashboard needs, computed once from a list of items.
struct RiskSummary: Equatable, Sendable {

    /// Total remaining exposure across **unresolved** items only.
    var moneyAtRisk: Money

    /// The part of `moneyAtRisk` that is already past its due date.
    var overdueAmount: Money

    var overdueCount: Int
    var unresolvedCount: Int

    /// Item counts for every status present in the input, resolved statuses included.
    var statusCounts: [CoreStatus: Int]

    /// Sum of `expectedCredit` per status, resolved statuses included.
    ///
    /// This is the face value of the cores in that status — not the remaining exposure — so the
    /// dashboard can show "Credited: $412.00 recovered" alongside "Awaiting: $260.00 owed".
    var statusAmounts: [CoreStatus: Money]

    /// Always exactly three entries, in `AgingBucket.allCases` order, even when empty.
    var agingBuckets: [AgingBucketSummary]

    static let empty = RiskSummary(
        moneyAtRisk: .zero,
        overdueAmount: .zero,
        overdueCount: 0,
        unresolvedCount: 0,
        statusCounts: [:],
        statusAmounts: [:],
        agingBuckets: AgingBucket.allCases.map {
            AgingBucketSummary(bucket: $0, count: 0, amount: .zero)
        }
    )

    func count(for status: CoreStatus) -> Int {
        statusCounts[status] ?? 0
    }

    func amount(for status: CoreStatus) -> Money {
        statusAmounts[status] ?? .zero
    }

    func aging(_ bucket: AgingBucket) -> AgingBucketSummary {
        if let match = agingBuckets.first(where: { $0.bucket == bucket }) {
            return match
        }
        return AgingBucketSummary(bucket: bucket, count: 0, amount: .zero)
    }

    /// True when at least one item of any status was summarised.
    var hasAnyItems: Bool {
        statusCounts.values.contains(where: { $0 > 0 })
    }
}

/// The money maths behind the dashboard: what is still owed, what is late, and how old it is.
///
/// Every date-sensitive function takes `now` and `calendar` explicitly. Nothing here reads the
/// system clock.
enum RiskCalculator {

    /// How much of this core's charge the shop could still lose.
    ///
    /// - Closed statuses (`credited`, `writtenOff`): `.zero` — the outcome is settled either way.
    /// - `disputed` **with** a recorded actual credit: `max(0, expected - actual)` — only the
    ///   shortfall is still at stake.
    /// - Everything else: the full `expectedCredit`.
    static func remainingExposure(for item: some CoreItemRepresenting) -> Money {
        if item.status.isClosed { return .zero }
        if item.status == .disputed, let actual = item.actualCredit {
            let difference = item.expectedCredit - actual
            return difference.isNegative ? .zero : difference
        }
        return item.expectedCredit
    }

    /// `expected - actual`, or `nil` when no credit has been recorded.
    ///
    /// Positive means the vendor short-paid; negative means they over-credited.
    static func discrepancy(for item: some CoreItemRepresenting) -> Money? {
        guard let actual = item.actualCredit else { return nil }
        return item.expectedCredit - actual
    }

    /// True only for an unresolved item whose due date is in the past.
    ///
    /// Both dates are normalised with `startOfDay(for:)`, so a core due **today** is not overdue —
    /// the shop still has the rest of the day to get it on the truck.
    static func isOverdue(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> Bool {
        guard item.status.isUnresolved else { return false }
        guard let due = item.dueDate else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    /// Whole days until the due date; negative once it has passed.
    ///
    /// `nil` when the item has no due date or is already closed.
    static func daysUntilDue(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> Int? {
        guard item.status.isUnresolved else { return nil }
        guard let due = item.dueDate else { return nil }
        return DueDateCalculator.dayDifference(from: now, to: due, calendar: calendar)
    }

    /// The date the item's age is measured from — the last thing that actually happened to it.
    ///
    /// - `awaitingCore` / `readyToReturn`: `receivedDate`
    /// - `returnedAwaitingCredit`: `returnedDate ?? receivedDate`
    /// - `disputed`, `credited`, `writtenOff`: `creditedDate ?? returnedDate ?? receivedDate`
    static func referenceDate(for item: some CoreItemRepresenting) -> Date {
        switch item.status {
        case .awaitingCore, .readyToReturn:
            return item.receivedDate
        case .returnedAwaitingCredit:
            return item.returnedDate ?? item.receivedDate
        case .disputed, .credited, .writtenOff:
            return item.creditedDate ?? item.returnedDate ?? item.receivedDate
        }
    }

    /// Whole days between `referenceDate(for:)` and `now`, never below zero.
    static func ageInDays(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> Int {
        let days = DueDateCalculator.dayDifference(
            from: referenceDate(for: item),
            to: now,
            calendar: calendar
        )
        return days < 0 ? 0 : days
    }

    static func agingBucket(_ item: some CoreItemRepresenting, now: Date, calendar: Calendar) -> AgingBucket {
        AgingBucket.bucket(forDays: ageInDays(item, now: now, calendar: calendar))
    }

    /// Rolls a list of items up into a single dashboard summary.
    ///
    /// `moneyAtRisk`, `overdueAmount`, `overdueCount`, and the aging buckets come from **unresolved
    /// items only**. `statusCounts` and `statusAmounts` cover every status present, so a shop can
    /// still see how much it recovered this month. The bucket array always has three entries.
    static func summarize<Item: CoreItemRepresenting>(_ items: [Item], now: Date, calendar: Calendar) -> RiskSummary {
        var moneyAtRisk = Money.zero
        var overdueAmount = Money.zero
        var overdueCount = 0
        var unresolvedCount = 0
        var statusCounts: [CoreStatus: Int] = [:]
        var statusAmounts: [CoreStatus: Money] = [:]
        var bucketCounts: [AgingBucket: Int] = [:]
        var bucketAmounts: [AgingBucket: Money] = [:]

        for item in items {
            let status = item.status
            statusCounts[status, default: 0] += 1
            statusAmounts[status, default: Money.zero] += item.expectedCredit

            guard status.isUnresolved else { continue }

            unresolvedCount += 1
            let exposure = remainingExposure(for: item)
            moneyAtRisk += exposure

            let bucket = agingBucket(item, now: now, calendar: calendar)
            bucketCounts[bucket, default: 0] += 1
            bucketAmounts[bucket, default: Money.zero] += exposure

            if isOverdue(item, now: now, calendar: calendar) {
                overdueCount += 1
                overdueAmount += exposure
            }
        }

        let buckets = AgingBucket.allCases.map { bucket in
            AgingBucketSummary(
                bucket: bucket,
                count: bucketCounts[bucket] ?? 0,
                amount: bucketAmounts[bucket] ?? Money.zero
            )
        }

        return RiskSummary(
            moneyAtRisk: moneyAtRisk,
            overdueAmount: overdueAmount,
            overdueCount: overdueCount,
            unresolvedCount: unresolvedCount,
            statusCounts: statusCounts,
            statusAmounts: statusAmounts,
            agingBuckets: buckets
        )
    }

    /// How many items still represent outstanding money. Drives the free-tier limit.
    static func unresolvedCount<Item: CoreItemRepresenting>(_ items: [Item]) -> Int {
        var total = 0
        for item in items where item.status.isUnresolved {
            total += 1
        }
        return total
    }
}
