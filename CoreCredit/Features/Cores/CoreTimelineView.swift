//
//  CoreTimelineView.swift
//  CoreCredit
//

import SwiftUI

/// A core's append-only history, oldest entry first.
///
/// This is the evidence a shop puts in front of a parts manager when a credit comes up short, so it
/// is shown in full and in order rather than summarised: every status change, every photo, every
/// credit, with the timestamp it was recorded. Nothing on this screen can edit or remove an entry —
/// `CoreEvent` records are only ever appended by `CoreItemService`, and they cascade away only with
/// the core itself.
///
/// Each entry is one accessibility element reading `CoreEvent.accessibilityDescription`, so
/// VoiceOver gets a sentence instead of a scattering of labels.
struct CoreTimelineView: View {

    private let events: [CoreEvent]
    private let currencyCode: String

    /// - Parameters:
    ///   - events: Normally `CoreItem.timeline`, which is already sorted oldest first.
    ///   - currencyCode: `ShopProfile.currencyCode`.
    init(events: [CoreEvent], currencyCode: String) {
        self.events = events
        self.currencyCode = currencyCode
    }

    var body: some View {
        if events.isEmpty {
            Text("No history recorded yet.")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(events, id: \.id) { event in
                    row(for: event, isLast: event.id == events.last?.id)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Private

    private func row(for event: CoreEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            marker(for: event)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(event.type.displayName)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !trimmed(event.detail).isEmpty {
                    Text(trimmed(event.detail))
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let amount = event.amount {
                    MoneyLabel(amount, currencyCode: currencyCode, style: .caption)
                }

                if !trimmed(event.reference).isEmpty {
                    Text("Reference " + trimmed(event.reference))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.bottom, isLast ? 0 : Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(event.accessibilityDescription))
    }

    /// The glyph in the left gutter.
    ///
    /// Deliberately a plain disc rather than a drawn rail: a connecting line has to be measured
    /// against text that can triple in height under Dynamic Type, and a rail that stops halfway
    /// down an entry reads as a rendering bug. The consistent left gutter carries the sequence on
    /// its own.
    private func marker(for event: CoreEvent) -> some View {
        Image(systemName: event.type.symbolName)
            .imageScale(.small)
            .foregroundStyle(tint(for: event))
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(tint(for: event).opacity(0.14))
            )
            .overlay(
                Circle().strokeBorder(tint(for: event).opacity(0.35), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    /// Timeline entries borrow the status palette where the event *is* a status outcome, and stay
    /// neutral otherwise — red and green must keep meaning "late" and "credited".
    private func tint(for event: CoreEvent) -> Color {
        switch event.type {
        case .creditRecorded:
            return Palette.positive
        case .disputeOpened:
            return Palette.danger
        case .writtenOff:
            return Palette.muted
        case .returned, .addedToBatch, .removedFromBatch:
            return Palette.accent
        case .statusChanged:
            if let target = event.toStatus {
                return Palette.color(for: target)
            }
            return Palette.neutral
        case .created, .edited, .photoAdded, .photoRemoved, .reopened,
             .reminderScheduled, .reminderCancelled:
            return Palette.neutral
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
