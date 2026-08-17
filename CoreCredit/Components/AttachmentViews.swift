//
//  AttachmentViews.swift
//  CoreCredit
//

import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

// MARK: - AttachmentThumbnail

/// A square preview of one stored evidence photo.
///
/// Stored attachment data is a full-size JPEG (up to `AppConfiguration.attachmentMaxDimension` on
/// its long edge). Handing that straight to `Image(uiImage:)` would decode a multi-megapixel
/// bitmap for a 72-point tile, so the thumbnail is downsampled through ImageIO first and the
/// result is held in view state.
///
/// While the thumbnail is decoding — and if the data is missing or unreadable — the tile shows the
/// attachment kind's SF Symbol rather than an empty box, so the strip never collapses or flickers.
struct AttachmentThumbnail: View {

    private let attachment: Attachment
    private let size: CGFloat

    @State private var thumbnail: UIImage? = nil

    /// - Parameters:
    ///   - attachment: The stored photo.
    ///   - size: Side length in points.
    init(attachment: Attachment, size: CGFloat = 72) {
        self.attachment = attachment
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .fill(Palette.surfaceElevated)

            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.kind.symbolName)
                    .imageScale(.large)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .task(id: attachment.id) {
            loadThumbnail()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(attachment.accessibilityLabel))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Private

    private func loadThumbnail() {
        let requested = size * Self.thumbnailScale
        let pixelSize = min(requested, AppConfiguration.thumbnailMaxDimension)
        thumbnail = ThumbnailDecoder.image(from: attachment.imageData, maxPixelSize: pixelSize)
    }

    /// Decode at a multiple of the point size so the tile stays sharp on 3x displays, capped by
    /// `AppConfiguration.thumbnailMaxDimension` so a large tile cannot blow up the decode budget.
    private static let thumbnailScale: CGFloat = 3
}

// MARK: - AttachmentStrip

/// A horizontal run of evidence photos.
///
/// Renders nothing when there is nothing to show — the calling screen decides whether an empty
/// photo set deserves an `EmptyStateView` or simply no section at all.
///
/// Deletion is offered through a long-press context menu rather than an always-visible badge:
/// these photos are the proof behind a disputed credit, and a stray thumb should not be able to
/// destroy one.
struct AttachmentStrip: View {

    private let attachments: [Attachment]
    private let onSelect: ((Attachment) -> Void)?
    private let onDelete: ((Attachment) -> Void)?

    /// - Parameters:
    ///   - attachments: Photos in display order. Callers normally pass `CoreItem.photos` or
    ///     `ReturnBatch.receipts`, which are already sorted.
    ///   - onSelect: Tapping a thumbnail. When `nil`, thumbnails are not interactive.
    ///   - onDelete: Adds a destructive context-menu item.
    init(
        attachments: [Attachment],
        onSelect: ((Attachment) -> Void)? = nil,
        onDelete: ((Attachment) -> Void)? = nil
    ) {
        self.attachments = attachments
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Spacing.m) {
                    ForEach(attachments, id: \.id) { attachment in
                        thumbnailCell(for: attachment)
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xs)
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Private

    @ViewBuilder
    private func thumbnailCell(for attachment: Attachment) -> some View {
        if let onDelete = onDelete {
            tappableThumbnail(for: attachment)
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(attachment)
                    } label: {
                        Label("Delete photo", systemImage: "trash")
                    }
                }
        } else {
            tappableThumbnail(for: attachment)
        }
    }

    @ViewBuilder
    private func tappableThumbnail(for attachment: Attachment) -> some View {
        if let onSelect = onSelect {
            Button {
                onSelect(attachment)
            } label: {
                AttachmentThumbnail(attachment: attachment)
            }
            .buttonStyle(.plain)
        } else {
            AttachmentThumbnail(attachment: attachment)
        }
    }
}

// MARK: - ThumbnailDecoder

/// Downsamples JPEG data to a thumbnail without decoding the full-size bitmap.
///
/// Kept file-private: the app-wide image pipeline lives in `ImageProcessor`, and this exists only
/// so the components layer has no dependency on it.
private enum ThumbnailDecoder {

    static func image(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        if data.isEmpty { return nil }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let clamped = max(1, Int(maxPixelSize.rounded()))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: clamped
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

// No `#Preview` here: both views take a SwiftData `Attachment`, and previews in this layer are
// restricted to pure value types. Exercise these from the feature-level previews that already
// build a preview `ModelContainer`.
