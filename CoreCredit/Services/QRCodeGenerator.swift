//
//  QRCodeGenerator.swift
//  CoreCredit
//
//  Capture layer — QR rendering for printed bin tags.
//
//  The tag is taped to a shelf in a parts room and scanned months later, often with grease on it
//  and under bad light. That drives every choice here: the highest error-correction level, the
//  shortest possible payload (see `BinTagPayload.encodedString`), and a nearest-neighbour upscale
//  so the modules stay hard-edged instead of blurring into each other.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Renders a QR code for a short payload string.
enum QRCodeGenerator {

    /// Error-correction level `"H"` — roughly 30% of the symbol can be damaged and still decode.
    /// Worth the extra modules for a label that lives on a parts shelf.
    private static let correctionLevel = "H"

    /// A QR image for `payload`, or `nil` if it cannot be produced.
    ///
    /// - Parameters:
    ///   - payload: The string encoded into the symbol. Keep it short; `BinTagPayload` encodes a
    ///     `corecredit://item/<uuid>` URL rather than the whole record for exactly this reason.
    ///   - sideLength: Requested edge length in points for the rendered image.
    /// - Returns: An opaque black-on-white QR image, or `nil` when the payload is empty, the
    ///   filter produces nothing, or the context cannot rasterise the result. Never traps.
    static func image(for payload: String, sideLength: CGFloat = 512) -> UIImage? {
        guard !payload.isEmpty else { return nil }
        guard sideLength.isFinite, sideLength > 0 else { return nil }
        guard let message = payload.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = message
        filter.correctionLevel = correctionLevel

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else { return nil }

        // Nearest-neighbour sampling keeps module edges crisp when the tiny generated symbol is
        // blown up to label size; the default sampling would soften them into grey ramps.
        let scale = sideLength / extent.width
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // A local context rather than a shared one: bin tags are rendered rarely, and a stored
        // `CIContext` would be shared mutable state across actors for no measurable gain.
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
