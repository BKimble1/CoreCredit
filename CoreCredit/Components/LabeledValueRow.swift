//
//  LabeledValueRow.swift
//  CoreCredit
//

import SwiftUI

/// A label on the left, its value on the right — the workhorse row of every detail screen.
///
/// At accessibility text sizes the row stacks vertically instead of squeezing two columns into a
/// phone width, which is what keeps invoice references and part numbers from truncating. The label
/// and value are combined into a single accessibility element so VoiceOver reads "Invoice, 4471-B"
/// as one phrase.
struct LabeledValueRow: View {

    private let label: String
    private let value: String
    private let symbol: String?
    private let isMonospaced: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - label: Field name.
    ///   - value: Already-formatted value. An empty string renders as an em dash and is spoken as
    ///     "Not set".
    ///   - symbol: Optional SF Symbol shown before the label.
    ///   - isMonospaced: Use monospaced digits — set this for references, part numbers, and any
    ///     figure that should align with the row above it.
    init(_ label: String, value: String, symbol: String? = nil, isMonospaced: Bool = false) {
        self.label = label
        self.value = value
        self.symbol = symbol
        self.isMonospaced = isMonospaced
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    labelView
                    valueView(isStacked: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    labelView
                    Spacer(minLength: Spacing.s)
                    valueView(isStacked: false)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value.isEmpty ? "Not set" : value))
    }

    // MARK: Private

    private var labelView: some View {
        HStack(spacing: Spacing.s) {
            if let symbol = symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func valueView(isStacked: Bool) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(valueFont)
            .foregroundStyle(Palette.textPrimary)
            .multilineTextAlignment(isStacked ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: isStacked ? .leading : .trailing)
    }

    private var valueFont: Font {
        let base = Font.system(.subheadline, design: .default, weight: .medium)
        return isMonospaced ? base.monospacedDigit() : base
    }
}

#Preview("Labeled value rows") {
    VStack(spacing: Spacing.s) {
        LabeledValueRow("Vendor", value: "NAPA Auto Parts", symbol: "building.2")
        LabeledValueRow("Invoice", value: "4471-B", symbol: "doc.text", isMonospaced: true)
        LabeledValueRow("Bin", value: "Rack C — shelf 2", symbol: "tray.full")
        LabeledValueRow("Repair order", value: "", symbol: "wrench.and.screwdriver")
        LabeledValueRow(
            "Notes",
            value: "Driver said the counter would not take it without the original box.",
            symbol: "note.text"
        )
    }
    .padding(Spacing.l)
    .background(Palette.background)
}
