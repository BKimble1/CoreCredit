//
//  ImageProcessor.swift
//  CoreCredit
//
//  Capture layer — bounded, orientation-correct image preparation for attachments.
//
//  A shop photographs a greasy invoice on a 48-megapixel camera; the ledger has to stay small
//  enough to sync, back up, and export. Everything stored by the app passes through here first:
//  downsampled to `AppConfiguration.attachmentMaxDimension`, re-encoded as JPEG at
//  `AppConfiguration.attachmentJPEGQuality`, with EXIF orientation baked into the pixels.
//
//  Downsampling uses ImageIO's thumbnail path rather than decoding a full `UIImage` and redrawing
//  it: ImageIO decodes straight to the target size, so a 48 MP photo never has to exist in memory
//  at full resolution. The `async` entry points hand that work to a detached task, so no caller
//  can accidentally block the main actor with it.
//

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A downsampled, re-encoded image ready to be stored on an `Attachment`.
struct ProcessedImage: Equatable, Sendable {

    /// JPEG data, already downsampled and compressed.
    var data: Data

    /// Width in pixels **after** the orientation transform was applied.
    var pixelWidth: Int

    /// Height in pixels **after** the orientation transform was applied.
    var pixelHeight: Int

    /// Convenience for `Attachment.byteCount`.
    var byteCount: Int { data.count }

    init(data: Data, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Everything that can go wrong preparing an image, as a presentable state.
enum ImageProcessingError: LocalizedError, Equatable {

    /// The data is empty, truncated, or not an image format the system can decode.
    case invalidImage

    /// The system refused to produce JPEG data from a decoded image.
    case encodingFailed

    /// The encoded result is still implausibly large — treated as a failure rather than writing
    /// tens of megabytes into the store.
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That photo couldn't be read. Try taking it again."
        case .encodingFailed:
            return "That photo couldn't be saved. Try taking it again."
        case .tooLarge:
            return "That photo is too large to attach. Try taking it again."
        }
    }
}

/// Downsampling, re-encoding, and thumbnailing for attachment images.
///
/// Every member is free of actor isolation, and the two `async` entry points move the decode and
/// encode onto a detached task — the main actor is driving a form and a camera preview while this
/// runs.
enum ImageProcessor {

    /// Hard ceiling on the encoded result. A 2000 px JPEG at quality 0.72 lands around 300–600 KB;
    /// anything past 16 MB means something pathological came out of the encoder.
    private static let maximumEncodedByteCount = 16 * 1024 * 1024

    /// Upper bound on a requested edge length, so a bad caller cannot ask ImageIO for a
    /// multi-gigabyte bitmap.
    private static let maximumRequestedPixelSize = 10_000

    // MARK: - Preparation

    /// Downsamples and re-encodes image data for storage.
    ///
    /// - Parameters:
    ///   - data: Any image format the system can decode (HEIC, JPEG, PNG …).
    ///   - maxDimension: Longest edge of the result, in pixels. Smaller images are never upscaled.
    ///   - quality: JPEG compression quality, 0…1.
    /// - Throws: `ImageProcessingError.invalidImage` when the data cannot be decoded,
    ///   `.encodingFailed` when JPEG encoding fails, `.tooLarge` when the result is implausible.
    static func prepare(data: Data,
                        maxDimension: CGFloat = AppConfiguration.attachmentMaxDimension,
                        quality: CGFloat = AppConfiguration.attachmentJPEGQuality) async throws -> ProcessedImage {
        let maxPixelSize = pixelSize(from: maxDimension)
        let compressionQuality = clampedQuality(quality)
        let task = Task.detached(priority: .userInitiated) {
            try ImageProcessor.process(data: data, maxPixelSize: maxPixelSize, quality: compressionQuality)
        }
        return try await task.value
    }

    /// Downsamples and re-encodes an already-decoded image.
    ///
    /// The image is first serialised losslessly, which carries `imageOrientation` into the JPEG's
    /// EXIF, and the shared data path then bakes that orientation into the pixels. `UIImage` is not
    /// `Sendable`, so the serialisation happens here rather than inside the detached task; the
    /// enclosing function is non-isolated and `async`, so it does not run on the main actor either.
    static func prepare(image: UIImage,
                        maxDimension: CGFloat = AppConfiguration.attachmentMaxDimension,
                        quality: CGFloat = AppConfiguration.attachmentJPEGQuality) async throws -> ProcessedImage {
        guard let lossless = image.jpegData(compressionQuality: 1.0) else {
            throw ImageProcessingError.invalidImage
        }
        return try await prepare(data: lossless, maxDimension: maxDimension, quality: quality)
    }

    /// A small decoded image for attachment strips and previews.
    ///
    /// Synchronous and non-throwing on purpose: it is called from view bodies, where the only
    /// sensible failure is "show the placeholder". Returns `nil` rather than a broken image.
    static func thumbnail(from data: Data,
                          maxDimension: CGFloat = AppConfiguration.thumbnailMaxDimension) -> UIImage? {
        guard let image = try? downsampledImage(data: data, maxPixelSize: pixelSize(from: maxDimension)) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    /// A solid-colour JPEG, synthesised in code.
    ///
    /// Tests, previews, and the simulator's "use a test image" path need real image bytes without
    /// shipping fixture files. `hue` is 0…1 and wraps, so callers can spread several placeholders
    /// across the colour wheel. Returns empty `Data` only if UIKit refuses to encode, which keeps
    /// the signature non-throwing for preview code.
    static func placeholderJPEGData(width: Int, height: Int, hue: Double) -> Data {
        let pixelWidth = min(max(width, 1), maximumRequestedPixelSize)
        let pixelHeight = min(max(height, 1), maximumRequestedPixelSize)
        let size = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor(hue: normalizedHue(hue), saturation: 0.55, brightness: 0.78, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    // MARK: - Work performed off the main actor

    /// The whole pipeline for one image. Called only from a detached task.
    private static func process(data: Data, maxPixelSize: Int, quality: CGFloat) throws -> ProcessedImage {
        let image = try downsampledImage(data: data, maxPixelSize: maxPixelSize)
        let encoded = try encodeJPEG(image, quality: quality)
        guard encoded.count <= maximumEncodedByteCount else { throw ImageProcessingError.tooLarge }
        return ProcessedImage(data: encoded, pixelWidth: image.width, pixelHeight: image.height)
    }

    /// Decodes straight to the target size with ImageIO.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` is the option that preserves orientation: it
    /// applies the EXIF transform while decoding, so a photo taken in portrait does not come back
    /// on its side. `kCGImageSourceCreateThumbnailFromImageAlways` ignores any small embedded
    /// preview, and ImageIO never upscales past the original pixel size.
    private static func downsampledImage(data: Data, maxPixelSize: Int) throws -> CGImage {
        guard !data.isEmpty else { throw ImageProcessingError.invalidImage }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            throw ImageProcessingError.invalidImage
        }
        guard CGImageSourceGetCount(source) > 0 else { throw ImageProcessingError.invalidImage }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageProcessingError.invalidImage
        }
        return image
    }

    /// Encodes a `CGImage` as JPEG through ImageIO, so no `UIImage` is needed off the main actor.
    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData,
                                                                UTType.jpeg.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw ImageProcessingError.encodingFailed
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.encodingFailed }

        let encoded = buffer as Data
        guard !encoded.isEmpty else { throw ImageProcessingError.encodingFailed }
        return encoded
    }

    // MARK: - Input clamping

    /// Turns a requested edge length into a sane pixel count. Non-finite or non-positive requests
    /// fall back to one pixel rather than trapping in the `Int` conversion.
    private static func pixelSize(from dimension: CGFloat) -> Int {
        guard dimension.isFinite, dimension >= 1 else { return 1 }
        let rounded = dimension.rounded()
        guard rounded < CGFloat(maximumRequestedPixelSize) else { return maximumRequestedPixelSize }
        return Int(rounded)
    }

    /// Keeps JPEG quality inside 0…1; a non-finite value falls back to the configured default.
    private static func clampedQuality(_ quality: CGFloat) -> CGFloat {
        guard quality.isFinite else { return AppConfiguration.attachmentJPEGQuality }
        return min(max(quality, 0), 1)
    }

    /// Wraps an arbitrary hue into 0…1 so callers can pass 1.5 or -0.25 without surprises.
    private static func normalizedHue(_ hue: Double) -> CGFloat {
        guard hue.isFinite else { return 0 }
        var wrapped = hue.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        return CGFloat(wrapped)
    }
}
