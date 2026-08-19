//
//  PhotoAssistSheet.swift
//  CoreCredit
//
//  AI Photo Assist (Beta). Gather up to six photographs, read them on this device, and hand what
//  was found to the same review sheet every other capture path ends at.
//
//  ## Where this sits
//
//  It is a sheet over the Scan core surface, not a destination. There is no tab, no dashboard card,
//  no widget action, and no onboarding page for it. Close it and the scanner is still there; the
//  session and every photograph in it are gone with it.
//
//  ## What it does not do
//
//  It does not save anything. It produces a `ScanReviewSession` — the identical value a live scan
//  or a document scan produces — which the host hands to the review sheet, where the user ticks
//  what is right and applies it to a draft that is still unsaved. The form's own Save is still the
//  only thing that writes a core, and it still asks the entitlement policy first.
//
//  ## No permission is requested by opening this
//
//  Importing from Photos uses `PhotosPicker`, which runs out of process and needs no photo-library
//  permission at all. The camera is only ever asked for when somebody taps Take photo.
//

import PhotosUI
import SwiftUI
import UIKit

struct PhotoAssistSheet: View {

    /// Called with the fused result once the user accepts it. The host presents the review sheet.
    private let onReviewReady: (ScanReviewSession) -> Void

    init(onReviewReady: @escaping (ScanReviewSession) -> Void) {
        self.onReviewReady = onReviewReady
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var session: PhotoAssistSession?
    @State private var picked: [PhotosPickerItem] = []
    @State private var notice: String?
    @State private var isImporting = false
    @State private var isAutoCaptureOn = false
    @State private var autoStatus = "Hold steady"
    @State private var isShowingCamera = false

    private static let contentMaxWidth: CGFloat = 560
    private static let thumbnailSize: CGFloat = 84
    private static let autoPreviewHeight: CGFloat = 220

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    explanation
                    FormErrorText(notice)
                    gatheredPhotos
                    captureActions
                    analysisSection
                }
                .padding(Spacing.l)
                .frame(maxWidth: PhotoAssistSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .contentMargins(.bottom, Spacing.scrollBottomBreathingRoom, for: .scrollContent)
            .background { Palette.background.ignoresSafeArea() }
            .navigationTitle("AI Photo Assist")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11y.PhotoAssist.root)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                        .accessibilityHint(Text("Closes the assistant. Nothing is saved."))
                }
            }
        }
        .task { prepareSession() }
        .onDisappear {
            session?.cancel()
            // Belt and braces. The preview's own onDisappear normally does this, but a sheet
            // dismissed while it is on screen is exactly the case where a held camera would
            // survive the screen that asked for it.
            appEnvironment.depthProvider.stop()
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraCaptureView(
                onImage: { image in
                    isShowingCamera = false
                    Task { await add(image) }
                },
                onCancel: { isShowingCamera = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: picked) { _, items in
            guard items.isEmpty == false else { return }
            Task { await importPicked(items) }
        }
    }

    // MARK: - Explanation

    private var explanation: some View {
        SectionCard(title: "How this works", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Add photos of the part, label or box, and invoice. Analysis stays on this "
                     + "device. You'll review everything before saving.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(PhotoAssistShot.allCases) { shot in
                        shotHint(shot)
                    }
                }

                if let session {
                    Text(capabilityLine(for: session))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier(A11y.PhotoAssist.capability)
                }
            }
        }
    }

    private func shotHint(_ shot: PhotoAssistShot) -> some View {
        let isTaken = session?.missingShots.contains(shot) == false

        return HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: isTaken ? "checkmark.circle.fill" : shot.symbolName)
                .foregroundStyle(isTaken ? Palette.accent : Palette.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(shot.displayName).font(Typography.rowTitle)
                Text(shot.guidance)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(shot.displayName + ". " + shot.guidance))
        .accessibilityValue(Text(isTaken ? "Added" : "Not added yet"))
    }

    /// One honest line about which senses this particular device actually has, and is using.
    ///
    /// A phone without a LiDAR scanner is not told it is missing anything, because it is not: the
    /// feature is identical without depth, and saying "no LiDAR" to somebody who cannot do anything
    /// about it is noise dressed up as transparency.
    ///
    /// Nor does a phone that *has* one get told depth is being used before it is. Depth is only
    /// measured while automatic capture is running — that is the only moment there is a live AR
    /// session — so the line says "can use" until a reading has actually arrived, and "using" only
    /// once one has. Claiming a sense the app is not currently exercising is the same kind of
    /// unearned confidence this whole feature is built to refuse.
    private func capabilityLine(for session: PhotoAssistSession) -> String {
        guard session.isDepthSupported else { return "Standard camera analysis." }
        return session.depthSummary == nil
            ? "This device has a depth scanner. Auto capture uses it to separate the part from the "
                + "background."
            : "Using this device's depth scanner to separate the part from the background."
    }

    // MARK: - Photographs

    @ViewBuilder
    private var gatheredPhotos: some View {
        if let session, session.photos.isEmpty == false {
            SectionCard(title: "Photos", systemImage: "photo.on.rectangle") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.m) {
                            ForEach(Array(session.photos.enumerated()), id: \.element.id) { pair in
                                thumbnail(pair.element, at: pair.offset)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Text(countLine(for: session))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func countLine(for session: PhotoAssistSession) -> String {
        let count = session.photos.count
        let noun = count == 1 ? "photo" : "photos"
        if session.canAddMorePhotos {
            return "\(count) \(noun). You can add \(session.remainingPhotoSlots) more."
        }
        return "\(count) \(noun) — that's the limit. Remove one to add another."
    }

    private func thumbnail(_ photo: PhotoAssistSession.Photo, at index: Int) -> some View {
        VStack(spacing: Spacing.xs) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = UIImage(data: photo.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // A scripted fixture under UI testing carries one byte and decodes to
                        // nothing. The slot still has to be visible and removable.
                        Palette.surfaceElevated
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(Palette.textSecondary)
                            }
                    }
                }
                .frame(width: PhotoAssistSheet.thumbnailSize,
                       height: PhotoAssistSheet.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))

                Button {
                    session?.remove(photo.id)
                    notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .padding(Spacing.xs)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.xs))
                }
                .buttonStyle(.plain)
                .padding(Spacing.xs)
                .frame(minWidth: Spacing.minimumTapTarget, minHeight: Spacing.minimumTapTarget,
                       alignment: .topTrailing)
                .accessibilityIdentifier(A11y.PhotoAssist.remove(index))
                .accessibilityLabel(Text("Remove photo \(index + 1)"))
            }

            Text(photo.shot?.displayName ?? "Photo \(index + 1)")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityIdentifier(A11y.PhotoAssist.photo(index))
        // Reordering and re-tagging through a menu rather than a drag. A drag in a horizontal strip
        // of 84pt thumbnails is a poor target with one hand on a part, and it is unreachable with
        // VoiceOver; a menu is both, and it says out loud what each action does.
        .contextMenu {
            ForEach(PhotoAssistShot.allCases) { shot in
                Button {
                    session?.setShot(shot, for: photo.id)
                } label: {
                    Label("This is the " + shot.displayName.localizedLowercase,
                          systemImage: shot.symbolName)
                }
            }

            Divider()

            Button {
                session?.movePhoto(from: index, to: index - 1)
            } label: {
                Label("Move earlier", systemImage: "arrow.left")
            }
            .disabled(index == 0)

            Button {
                session?.movePhoto(from: index, to: index + 1)
            } label: {
                Label("Move later", systemImage: "arrow.right")
            }
            .disabled(index >= (session?.photos.count ?? 0) - 1)

            Divider()

            Button(role: .destructive) {
                session?.remove(photo.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // MARK: - Capture

    private var captureActions: some View {
        SectionCard(title: "Add photos", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PhotosPicker(selection: $picked,
                             maxSelectionCount: session?.remainingPhotoSlots ?? 0,
                             matching: .images,
                             photoLibrary: .shared()) {
                    CaptureRowLabel(title: "Choose from Photos",
                                    detail: "Pick several at once. No photo access is requested.",
                                    symbol: "photo.on.rectangle.angled")
                }
                .disabled(canAddMore == false || isImporting)
                .accessibilityIdentifier(A11y.PhotoAssist.importPhotos)

                Button {
                    notice = nil
                    isShowingCamera = true
                } label: {
                    CaptureRowLabel(title: "Take photo",
                                    detail: "The camera is only asked for when you tap this.",
                                    symbol: "camera")
                }
                .buttonStyle(.plain)
                .disabled(canAddMore == false)
                .accessibilityIdentifier(A11y.PhotoAssist.takePhoto)

                if ARPhotoCapture.isSupported {
                    Toggle(isOn: $isAutoCaptureOn) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Auto capture").font(Typography.rowTitle)
                            Text("Collects a frame when the view holds still. Only while this "
                                 + "screen is open.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .disabled(canAddMore == false)
                    .accessibilityIdentifier(A11y.PhotoAssist.autoCapture)

                    if isAutoCaptureOn {
                        autoCapturePreview
                    }
                }

                if appEnvironment.launchOptions.photoAssistScenario != nil {
                    Button("Add sample photos") { addScriptedSamples() }
                        .accessibilityIdentifier(A11y.PhotoAssist.addSamples)
                }
            }
        }
    }

    private var canAddMore: Bool { session?.canAddMorePhotos ?? false }

    /// The live view that collects frames on its own.
    ///
    /// Only ever on screen while this card is: the AR session begins when this view is made and is
    /// paused when it is torn down, so closing the sheet — or simply switching the toggle off —
    /// ends it. Nothing collects in the background.
    @ViewBuilder
    private var autoCapturePreview: some View {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        VStack(alignment: .leading, spacing: Spacing.s) {
            ARPhotoCaptureView(
                onCapture: { data in Task { await addAutomatic(data) } },
                onStatus: { autoStatus = $0 },
                isCollecting: canAddMore
            )
            .frame(height: PhotoAssistSheet.autoPreviewHeight)
            // The depth session's entire lifetime. It begins when this preview appears and ends
            // when it goes away, which is also what happens when the toggle is switched off or the
            // sheet is closed. Nothing measures anything outside this view being on screen.
            .onAppear { appEnvironment.depthProvider.start() }
            .onDisappear { appEnvironment.depthProvider.stop() }
            .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))
            .accessibilityHidden(true)

            Text(autoStatusLine)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel(Text(autoStatusLine))
        }
        #else
        EmptyView()
        #endif
    }

    private var autoStatusLine: String {
        guard let session else { return autoStatus }
        return autoStatus + " — " + String(session.photos.count) + " of "
            + String(PhotoAssistFusion.maximumImages) + " photos."
    }

    /// A frame the AR session collected on its own. Identical treatment to a tapped one: it is
    /// downsampled, it is de-duplicated, and it counts against the same six.
    private func addAutomatic(_ data: Data) async {
        guard let session, session.canAddMorePhotos else { return }

        // Sampled at the moment the frame was collected, which is the only moment it means
        // anything: it says something about what the camera was pointed at, not about the session.
        session.recordDepth(await appEnvironment.depthProvider.currentDepthSummary())

        guard let prepared = try? await ImageProcessor.prepare(data: data) else { return }
        let outcome = await session.add(prepared.data, shot: session.missingShots.first)
        switch outcome {
        case .added:
            autoStatus = "Captured"
        case .rejectedDuplicate:
            autoStatus = "Same view — move to the label or the invoice"
        case .rejectedLimit, .rejectedUnreadable:
            if let message = outcome.message { notice = message }
        }
    }

    // MARK: - Analysis

    @ViewBuilder
    private var analysisSection: some View {
        if let session {
            switch session.phase {
            case .idle:
                if session.photos.isEmpty == false {
                    Button { Task { await session.analyze() } } label: {
                        PrimaryButtonLabel("Read these photos", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11y.PhotoAssist.analyze)
                }

            case .analyzing(let completed, let total):
                SectionCard(title: "Reading", systemImage: "sparkles") {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        Text("Photo \(min(completed + 1, total)) of \(total).")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(A11y.PhotoAssist.progress)
                    .accessibilityLabel(Text("Reading photo \(min(completed + 1, total)) of \(total)."))
                }

            case .finished(let result):
                finished(result, in: session)

            case .failed(let message):
                SectionCard(title: "That didn't work", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(message).font(Typography.caption)
                        Text("You can still type the details in on the form behind this.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func finished(_ result: PhotoAssistFusionResult,
                          in session: PhotoAssistSession) -> some View {
        if result.hasConfidentIdentification == false && result.candidates.isEmpty {
            SectionCard(title: "Nothing to go on", systemImage: "questionmark.circle") {
                Text(PhotoAssistFusion.noConfidentMatchMessage)
                    .font(Typography.caption)
                    .accessibilityIdentifier(A11y.PhotoAssist.noMatch)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if result.hasConfidentIdentification == false {
                    SectionCard(title: "Not sure about the part", systemImage: "questionmark.circle") {
                        Text(PhotoAssistFusion.noConfidentMatchMessage)
                            .font(Typography.caption)
                            .accessibilityIdentifier(A11y.PhotoAssist.noMatch)
                    }
                }

                if result.conflictedKinds.isEmpty == false {
                    SectionCard(title: "Two photos disagree", systemImage: "exclamationmark.2") {
                        Text(conflictLine(result.conflictedKinds))
                            .font(Typography.caption)
                    }
                }

                Button { hand(session) } label: {
                    PrimaryButtonLabel("Review \(result.candidates.count) suggestions",
                                       systemImage: "checklist")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.PhotoAssist.analyze)
            }
        }
    }

    private func conflictLine(_ kinds: [ScanCandidateKind]) -> String {
        let names = kinds.map(\.displayName.localizedLowercase)
        let joined = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "Your photos gave more than one \(joined). Both are in the review, and neither is "
            + "ticked — pick the right one."
    }

    // MARK: - Actions

    private func prepareSession() {
        guard session == nil else { return }
        session = PhotoAssistSession(
            recognizer: appEnvironment.textRecognizer,
            classifier: appEnvironment.imageClassifier,
            fingerprinter: appEnvironment.imageFingerprinter,
            depth: appEnvironment.depthProvider
        )
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        guard let session else { return }
        isImporting = true
        defer {
            isImporting = false
            picked = []
        }

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                notice = PhotoAssistSession.AddOutcome.rejectedUnreadable.message
                continue
            }
            // Downsampled through the same path as every other image this app holds, so a session
            // of six photographs costs what six attachments cost rather than six camera originals.
            guard let prepared = try? await ImageProcessor.prepare(data: data) else {
                notice = PhotoAssistSession.AddOutcome.rejectedUnreadable.message
                continue
            }
            let outcome = await session.add(prepared.data)
            if let message = outcome.message { notice = message }
        }
    }

    /// One photograph from the camera, prepared exactly like an imported one.
    private func add(_ image: UIImage) async {
        guard let session else { return }
        guard let prepared = try? await ImageProcessor.prepare(image: image) else {
            notice = PhotoAssistSession.AddOutcome.rejectedUnreadable.message
            return
        }
        let outcome = await session.add(prepared.data, shot: session.missingShots.first)
        if let message = outcome.message { notice = message }
    }

    private func addScriptedSamples() {
        guard let session,
              let scenario = appEnvironment.launchOptions.photoAssistScenario else { return }
        Task {
            for index in 0..<scenario.photoCount {
                let outcome = await session.add(PhotoAssistFixture.imageData(at: index),
                                                shot: scenario.scripts[index].shot)
                if let message = outcome.message { notice = message }
            }
        }
    }

    private func hand(_ session: PhotoAssistSession) {
        guard let review = session.reviewSession() else { return }
        session.cancel()
        onReviewReady(review)
    }

    private func close() {
        session?.cancel()
        dismiss()
    }
}

// MARK: - Row label

/// A tappable row inside the capture card: symbol, title, one line of why.
private struct CaptureRowLabel: View {

    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Spacing.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
    }
}
