//
//  ScannerDiagnosticsView.swift
//  CoreCredit
//
//  Settings — what the scanner actually saw.
//
//  ## Why a shop tool has a diagnostics screen
//
//  "It scanned the wrong number" is unanswerable without the reading itself. This screen holds the
//  most recent capture session and nothing else: the codes that came back and whether they were
//  accepted, the lines Vision read, the candidates that were ranked out of them with the reason each
//  one was proposed, and any permission or hardware failure along the way.
//
//  ## It never leaves the device
//
//  `ScanDiagnosticsRecorder` keeps one session in memory. There is no upload, no analytics, and no
//  file written behind the user's back — the JSON exists only when they ask for it, and it travels
//  only where they send it. The screen says so in as many words, because a technician being asked to
//  "send the diagnostics" deserves to know exactly what they are sending.
//

import SwiftUI
import UIKit

/// The most recent scan session, in full, with a way to copy it and a way to erase it.
struct ScannerDiagnosticsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var didCopy = false

    init() { }

    private static let contentMaxWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                privacyCard

                if let session = appEnvironment.scanDiagnostics.session, session.isEmpty == false {
                    sessionCard(session)
                    barcodeCard(session)
                    lineCard(session)
                    candidateCard(session)
                    failureCard(session)
                    noteCard(session)
                    exportCard
                    clearButton
                } else {
                    emptyCard
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: ScannerDiagnosticsView.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Scanner diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Diagnostics.root)
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        SectionCard(title: "Stays on this device", systemImage: "lock") {
            Text("These notes are kept in memory on this iPhone or iPad only. CoreCredit never "
                 + "uploads them, never sends them anywhere on its own, and keeps no history — only "
                 + "the most recent scan is here, and it is gone when the app closes. No photograph "
                 + "and no image data is ever recorded.")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Empty

    private var emptyCard: some View {
        SectionCard {
            EmptyStateView(
                symbol: "barcode.viewfinder",
                title: "No scan recorded yet",
                message: "Scan a barcode or read a photo, then come back here to see exactly what "
                    + "the camera made of it."
            )
        }
    }

    // MARK: - Session

    private func sessionCard(_ session: ScanDiagnosticsSession) -> some View {
        SectionCard(title: "This scan", systemImage: "clock") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                LabeledValueRow("Started",
                                value: session.startedAt.formatted(date: .abbreviated,
                                                                   time: .shortened),
                                symbol: "clock")
                LabeledValueRow("Source", value: session.source, symbol: "camera")
                LabeledValueRow("Camera", value: session.availability, symbol: "checkmark.shield")
            }
        }
    }

    // MARK: - Barcodes

    @ViewBuilder
    private func barcodeCard(_ session: ScanDiagnosticsSession) -> some View {
        if session.barcodes.isEmpty == false {
            SectionCard(title: "Codes read", systemImage: "barcode") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(session.barcodes) { barcode in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(barcode.payload)
                                .font(Typography.rowTitle)
                                .foregroundStyle(Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(barcode.symbology)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text((barcode.accepted ? "Accepted — " : "Ignored — ") + barcode.reason)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Lines

    @ViewBuilder
    private func lineCard(_ session: ScanDiagnosticsSession) -> some View {
        if session.lines.isEmpty == false {
            SectionCard(title: "Text read", systemImage: "doc.plaintext") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(session.lines) { line in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(line.text)
                                .font(Typography.rowTitle)
                                .foregroundStyle(Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(ScannerDiagnosticsView.lineDetail(for: line))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// Page and recognition confidence for one line.
    ///
    /// This figure is Vision's own character confidence and it is shown as a number on purpose:
    /// this screen is the raw reading, not the confirmation UI. The bands the user actually decides
    /// with are words, and they live on the review sheet.
    private static func lineDetail(for line: ScanDiagnosticsLine) -> String {
        let score = line.confidence.formatted(.number.precision(.fractionLength(2)))
        return "Page " + String(line.page + 1) + " · recognition confidence " + score
    }

    // MARK: - Candidates

    @ViewBuilder
    private func candidateCard(_ session: ScanDiagnosticsSession) -> some View {
        if session.candidates.isEmpty == false {
            SectionCard(title: "What was proposed", systemImage: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(session.candidates) { candidate in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(candidate.kind + " · " + candidate.band)
                                .font(Typography.rowTitle)
                                .foregroundStyle(Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Read as " + candidate.rawValue)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if candidate.normalizedValue != candidate.rawValue {
                                Text("Cleaned up to " + candidate.normalizedValue)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let symbology = candidate.symbology, symbology.isEmpty == false {
                                Text(symbology)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(candidate.reason)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Failures and notes

    @ViewBuilder
    private func failureCard(_ session: ScanDiagnosticsSession) -> some View {
        if session.failures.isEmpty == false {
            SectionCard(title: "What went wrong", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(Array(session.failures.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.subheadline)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func noteCard(_ session: ScanDiagnosticsSession) -> some View {
        if session.notes.isEmpty == false {
            SectionCard(title: "Notes", systemImage: "note.text") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(Array(session.notes.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportCard: some View {
        if let json = appEnvironment.scanDiagnostics.jsonReport() {
            SectionCard(title: "Send it to support", systemImage: "square.and.arrow.up") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("The same information as plain JSON. It goes only where you send it.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        UIPasteboard.general.string = json
                        didCopy = true
                    } label: {
                        PrimaryButtonLabel("Copy JSON", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy JSON"))
                    .accessibilityHint(Text("Puts the diagnostics on the clipboard so you can paste "
                                            + "them into an email."))

                    ShareLink(item: json) {
                        DiagnosticsActionLabel(title: "Share JSON",
                                               systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Share JSON"))
                    .accessibilityHint(Text("Opens the share sheet with the diagnostics as text."))

                    if didCopy {
                        Text("Copied to the clipboard.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text("Copied to the clipboard."))
                    }
                }
            }
        }
    }

    // MARK: - Clearing

    private var clearButton: some View {
        DestructiveConfirmButton(
            title: "Clear diagnostics",
            confirmationTitle: "Clear diagnostics",
            message: "This erases the recorded scan from this device. It does not touch any core, "
                + "photo, or return — only these notes.",
            action: {
                appEnvironment.scanDiagnostics.clear()
                didCopy = false
            }
        )
        .accessibilityIdentifier(A11y.Diagnostics.clear)
    }
}

// MARK: - Secondary action label

/// The label for the share action, matching the outlined secondary buttons used elsewhere.
private struct DiagnosticsActionLabel: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
