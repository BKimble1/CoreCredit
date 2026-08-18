//
//  AttachmentPickerSheet.swift
//  CoreCredit
//
//  Capture feature — getting one photograph into the ledger.
//
//  ## Two sources, one pipeline
//
//  A photo arrives either from the camera or from `PhotosPicker`, and both go through
//  `ImageProcessor.prepare` before they become an `Attachment`. That is what keeps the store
//  bounded (a 48 MP invoice photo becomes a few hundred kilobytes) and what bakes EXIF orientation
//  into the pixels, so an invoice photographed in portrait is not filed on its side.
//
//  ## No photo-library permission
//
//  `PhotosPicker` runs out of process and needs no library authorisation and no usage description.
//  Nothing in this file asks for one, and nothing should be added that does: a shop's photo library
//  is none of this app's business. The camera path uses the camera permission the scanner already
//  needs.
//

import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Captures or picks one photo, prepares it, and hands back a ready-to-store `Attachment`.
@MainActor
struct AttachmentPickerSheet: View {

    /// What this photograph is evidence of. Drives the title, the icon, and the stored kind.
    private let kind: AttachmentKind

    /// Called once with the finished attachment. The caller decides whether it is written to the
    /// record immediately or held until the record exists.
    private let onCapture: (Attachment) -> Void

    init(kind: AttachmentKind, onCapture: @escaping (Attachment) -> Void) {
        self.kind = kind
        self.onCapture = onCapture
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var pickedItem: PhotosPickerItem?
    @State private var isPresentingCamera = false
    @State private var processed: ProcessedImage?
    @State private var preview: UIImage?
    @State private var caption: String = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @FocusState private var isCaptionFocused: Bool

    private static let contentMaxWidth: CGFloat = 560
    private static let previewHeight: CGFloat = 220

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let errorMessage = errorMessage {
                        ErrorBanner(message: errorMessage,
                                    onDismiss: { self.errorMessage = nil })
                    }

                    if processed == nil {
                        sourceCard
                    } else {
                        previewCard
                    }

                    captionCard
                }
                .padding(Spacing.l)
                .frame(maxWidth: AttachmentPickerSheet.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(kind.displayName + " photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint(Text("Closes without adding a photo."))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isCaptionFocused = false }
                }
            }
            .overlay {
                if isProcessing {
                    LoadingOverlay(message: "Preparing the photo…")
                }
            }
        }
        .tint(Palette.accent)
        .onChange(of: pickedItem) { _, newValue in
            guard let newValue = newValue else { return }
            Task { await load(newValue) }
        }
        .fullScreenCover(isPresented: $isPresentingCamera) {
            CameraCaptureView(
                onImage: { image in
                    isPresentingCamera = false
                    Task { await process(image) }
                },
                onCancel: { isPresentingCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Choosing a source

    private var sourceCard: some View {
        SectionCard(title: "Add a " + kind.displayName.lowercased() + " photo",
                    systemImage: kind.symbolName) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if AttachmentPickerSheet.isCameraAvailable {
                    Button {
                        isCaptionFocused = false
                        isPresentingCamera = true
                    } label: {
                        PrimaryButtonLabel("Take a photo", systemImage: "camera")
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                    .accessibilityLabel(Text("Take a photo"))
                    .accessibilityHint(Text("Opens the camera."))
                }

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    PhotoLibraryLabel()
                }
                .disabled(isProcessing)
                .accessibilityLabel(Text("Choose from photos"))
                .accessibilityHint(Text("Picks an existing photo. "
                                        + "CoreCredit never reads the rest of your library."))

                if !AttachmentPickerSheet.isCameraAvailable {
                    Text("No camera is available on this device, so pick an existing photo instead.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Photo picker label

    /// A standalone view rather than a computed property on the sheet.
    ///
    /// `PhotosPicker`'s label builder is `@Sendable` in the iOS 26 SDK, so referencing a
    /// main-actor-isolated member of `AttachmentPickerSheet` from inside it captures `self` across
    /// an isolation boundary. This type captures nothing — it reads only the design tokens, which
    /// are nonisolated — so the closure has nothing to smuggle.
    private struct PhotoLibraryLabel: View {
        var body: some View {
            HStack(spacing: Spacing.s) {
                Image(systemName: "photo.on.rectangle")
                    .imageScale(.medium)
                Text("Choose from photos")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

    // MARK: - Reviewing the result

    @ViewBuilder
    private var previewCard: some View {
        SectionCard(title: "Ready to add", systemImage: kind.symbolName) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let preview = preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: AttachmentPickerSheet.previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Preview of the " + kind.displayName.lowercased()
                                                 + " photo"))
                        .accessibilityAddTraits(.isImage)
                }

                if let processed = processed {
                    Text(sizeSummary(for: processed))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                Button {
                    confirm()
                } label: {
                    PrimaryButtonLabel("Add photo", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                .disabled(isProcessing || processed == nil)

                Button {
                    reset()
                } label: {
                    Text("Choose a different photo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Caption

    private var captionCard: some View {
        SectionCard(title: "Caption (optional)", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                TextField(captionPlaceholder, text: $caption, axis: .vertical)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1...3)
                    .focused($isCaptionFocused)
                    .padding(Spacing.m)
                    .frame(minHeight: Spacing.minimumTapTarget, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                            .fill(Palette.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                            .strokeBorder(isCaptionFocused ? Palette.accent : Palette.fieldBorder,
                                          lineWidth: isCaptionFocused ? 2 : 1)
                    )
                    .accessibilityLabel(Text("Photo caption"))

                Text("A caption is read out with the photo and printed in a dispute packet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Work

    /// Loads the picked library item and prepares it for storage.
    private func load(_ item: PhotosPickerItem) async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = ImageProcessingError.invalidImage.errorDescription
                return
            }
            let result = try await ImageProcessor.prepare(data: data)
            apply(result)
        } catch let error as ImageProcessingError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Prepares an image that came straight off the camera.
    private func process(_ image: UIImage) async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            let result = try await ImageProcessor.prepare(image: image)
            apply(result)
        } catch let error as ImageProcessingError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stores the prepared bytes and builds a small preview for the review card.
    private func apply(_ result: ProcessedImage) {
        processed = result
        preview = ImageProcessor.thumbnail(from: result.data,
                                           maxDimension: AttachmentPickerSheet.previewHeight * 3)
    }

    /// Builds the attachment and hands it to the caller.
    private func confirm() {
        guard let processed = processed else { return }
        let attachment = Attachment(
            kind: kind,
            imageData: processed.data,
            pixelWidth: processed.pixelWidth,
            pixelHeight: processed.pixelHeight,
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            capturedAt: appEnvironment.dateProvider.now
        )
        onCapture(attachment)
        dismiss()
    }

    /// Clears the prepared image so the source buttons come back.
    private func reset() {
        processed = nil
        preview = nil
        pickedItem = nil
        errorMessage = nil
    }

    // MARK: - Copy

    /// What to point the camera at, per kind of evidence.
    private var guidance: String {
        switch kind {
        case .part:
            return "Photograph the old core itself, so there is no argument about what went back."
        case .box:
            return "Photograph the box or the label, including any core-return sticker."
        case .invoice:
            return "Photograph the invoice showing the core charge. You can read the details off it "
                + "afterwards."
        case .receipt:
            return "Photograph the signed return receipt. This is the proof the core reached the "
                + "vendor."
        case .other:
            return "Photograph anything else worth keeping with this core."
        }
    }

    private var captionPlaceholder: String {
        switch kind {
        case .part: return "Casting number visible on the housing"
        case .box: return "Core return sticker on the end of the box"
        case .invoice: return "Core charge on line 3"
        case .receipt: return "Signed by the driver"
        case .other: return "What this shows"
        }
    }

    /// Rounded size and dimensions, so a shop can see the app is not hoarding megabytes.
    private func sizeSummary(for image: ProcessedImage) -> String {
        let kilobytes = max(1, image.byteCount / 1024)
        return String(image.pixelWidth) + " × " + String(image.pixelHeight)
            + " pixels · about " + String(kilobytes) + " KB"
    }

    /// Whether this device can take a photo at all. Never trusted from a cached value: on iPad the
    /// answer can differ between models, and in the simulator it is simply `false`.
    private static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}

// MARK: - Camera

/// The system camera, wrapped so SwiftUI can present it.
///
/// `UIImagePickerController` is used rather than a bespoke `AVCaptureSession` on purpose: this is a
/// single still photograph, the system UI already handles focus, flash, and retake, and there is no
/// custom capture behaviour worth the code it would cost.
@MainActor
private struct CameraCaptureView: UIViewControllerRepresentable {

    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Guarded: setting `.camera` on a device without one raises at runtime, and the caller only
        // shows this view when a camera exists — but presentation can race a hardware change.
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        }
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // Re-capture the closures so they never point at stale SwiftUI state.
        context.coordinator.onImage = onImage
        context.coordinator.onCancel = onCancel
    }

    /// Delegate bridge.
    ///
    /// Callbacks hop to the main actor through a `Task` rather than calling straight back into
    /// SwiftUI, so a capture result is never delivered in the middle of a view update.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

        var onImage: (UIImage) -> Void
        var onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let image = image {
                    self.onImage(image)
                } else {
                    // A media type this picker cannot hand back as a still image is treated as a
                    // cancel rather than as an error the user cannot act on.
                    self.onCancel()
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            Task { @MainActor [weak self] in
                self?.onCancel()
            }
        }
    }
}
