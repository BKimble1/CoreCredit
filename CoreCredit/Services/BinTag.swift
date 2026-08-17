//
//  BinTag.swift
//  CoreCredit
//
//  Capture layer — the printed shelf label and the payload its QR code carries.
//
//  A bin tag is a physical object: it gets taped to a shelf next to a greasy alternator and read
//  again weeks later, possibly by someone who has never opened the app. So the printed side
//  carries everything a human needs (part, number, vendor, bin, what it is worth), while the QR
//  carries only a short deep link. Stuffing the whole record into the symbol would double its
//  module count and halve the odds of a clean scan.
//

import Foundation
import UIKit

/// What a bin tag knows about one core.
///
/// `Codable` so the same value can be logged or embedded in an export; the QR itself encodes only
/// `encodedString`.
struct BinTagPayload: Codable, Equatable, Sendable {

    /// Payload schema version, so a future tag format can be told apart from this one.
    var version: Int

    /// The core this tag belongs to. This is the only field the QR carries.
    var itemID: UUID

    var partName: String
    var partNumber: String

    /// Empty string rather than `nil`, because the printed side renders a missing vendor as a
    /// skipped row and never as the word "nil".
    var vendorName: String

    var binLabel: String
    var expectedCents: Int64

    /// Current payload version written by this build.
    private static let currentVersion = 1

    /// URL host used in `encodedString`.
    private static let itemHost = "item"

    init(item: some CoreItemRepresenting) {
        self.version = BinTagPayload.currentVersion
        self.itemID = item.identifier
        self.partName = item.partName
        self.partNumber = item.partNumber
        self.vendorName = item.vendorName ?? ""
        self.binLabel = item.binLabel ?? ""
        self.expectedCents = item.expectedCredit.cents
    }

    /// `"corecredit://item/<uuid>"`.
    ///
    /// Short on purpose: 36 characters of UUID plus a 20-character prefix fits in a low-density
    /// symbol that still scans at "H" error correction after a year on a shelf. The other fields
    /// of this struct are for the printed text, **not** for the code.
    var encodedString: String {
        AppConfiguration.urlScheme + "://" + BinTagPayload.itemHost + "/" + itemID.uuidString
    }

    /// Parses a scanned string back into an item identifier.
    ///
    /// Tolerates junk by design — a scanner will happily hand over a vendor's own barcode, a
    /// shipping label, or an empty string. Anything that is not one of this app's item links
    /// returns `nil`, and the caller falls back to search.
    static func itemID(fromEncodedString string: String) -> UUID? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme,
              scheme.caseInsensitiveCompare(AppConfiguration.urlScheme) == .orderedSame else {
            return nil
        }
        guard let host = components.host,
              host.caseInsensitiveCompare(BinTagPayload.itemHost) == .orderedSame else {
            return nil
        }
        let identifier = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !identifier.isEmpty else { return nil }
        return UUID(uuidString: identifier)
    }
}

/// Raised when PDF generation produces nothing usable. Kept local to this file so the capture
/// layer never has to reach into the export layer's error type.
enum BinTagRenderingError: LocalizedError, Equatable {
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .renderingFailed:
            return "The bin tag couldn't be created. Try again."
        }
    }
}

/// Draws a 4×6-inch shelf label as PDF data, ready to share or print.
///
/// Colours are fixed black/grey on white rather than semantic UIKit colours: a PDF has no trait
/// collection to resolve against, and a "label"-coloured tag would print white-on-white for a
/// shop running the app in dark mode.
@MainActor
struct BinTagRenderer {

    /// 4×6 inches at 72 dpi, the standard thermal label stock.
    private static let pageSize = CGSize(width: 288, height: 432)
    private static let margin: CGFloat = 18
    private static let rowSpacing: CGFloat = 5
    private static let labelColumnWidth: CGFloat = 74
    /// Single-line height reserved for one "label / value" row.
    private static let detailRowHeight: CGFloat = 18
    private static let qrSide: CGFloat = 140

    /// Renders the label.
    ///
    /// Every optional field is allowed to be empty: missing rows are skipped rather than printed
    /// blank, an unnamed part falls back to "Untitled core", and a `nil` `qrImage` is replaced by
    /// the item's short identifier so the tag is still usable by hand.
    ///
    /// - Throws: `BinTagRenderingError.renderingFailed` if the renderer yields no data.
    static func makePDFData(item: some CoreItemRepresenting,
                            shopName: String,
                            currencyCode: String,
                            qrImage: UIImage?) throws -> Data {
        let pageRect = CGRect(origin: .zero, size: pageSize)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Bin tag — " + displayName(for: item),
            kCGPDFContextCreator as String: AppConfiguration.displayName
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let data = renderer.pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(pageRect)
            drawLabel(item: item, shopName: shopName, currencyCode: currencyCode,
                      qrImage: qrImage, pageRect: pageRect)
        }

        guard !data.isEmpty else { throw BinTagRenderingError.renderingFailed }
        return data
    }

    // MARK: - Layout

    /// Draws the whole label.
    ///
    /// The QR block is positioned **first**, pinned to the bottom of the page, and the text is
    /// then laid out downwards into the space above it. Anything that would collide with the code
    /// is dropped rather than overprinted, and the drop order is deliberate: the part name, the
    /// core charge, and the code always render; the optional detail rows are what give way when a
    /// part name runs to three lines.
    private static func drawLabel(item: some CoreItemRepresenting,
                                  shopName: String,
                                  currencyCode: String,
                                  qrImage: UIImage?,
                                  pageRect: CGRect) {
        let contentWidth = pageRect.width - (margin * 2)
        let contentBottom = pageRect.height - margin
        let captionHeight: CGFloat = 12
        let qrRect = CGRect(x: margin + ((contentWidth - qrSide) / 2),
                            y: contentBottom - captionHeight - 4 - qrSide,
                            width: qrSide,
                            height: qrSide)
        let textLimit = qrRect.minY - 6
        var cursorY = margin

        // Shop name / header strip.
        let trimmedShopName = shopName.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = trimmedShopName.isEmpty ? AppConfiguration.displayName : trimmedShopName
        cursorY += drawParagraph(header.uppercased(),
                                 font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                                 color: UIColor.darkGray,
                                 alignment: .left,
                                 in: CGRect(x: margin, y: cursorY, width: contentWidth, height: 16))
        cursorY += 4

        // Hairline under the header.
        UIColor(white: 0.75, alpha: 1).setFill()
        UIRectFill(CGRect(x: margin, y: cursorY, width: contentWidth, height: 0.75))
        cursorY += 12

        // Part name — the one thing readable from across the parts room. Capped at two lines so a
        // long description cannot push the money or the code off the label.
        cursorY += drawParagraph(displayName(for: item),
                                 font: UIFont.systemFont(ofSize: 26, weight: .bold),
                                 color: UIColor.black,
                                 alignment: .left,
                                 in: CGRect(x: margin, y: cursorY, width: contentWidth, height: 58))
        cursorY += 8

        // Expected credit — why anyone bothers returning the core.
        cursorY += drawParagraph("CORE CHARGE",
                                 font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                                 color: UIColor.darkGray,
                                 alignment: .left,
                                 in: CGRect(x: margin, y: cursorY, width: contentWidth, height: 14))
        cursorY += 2
        cursorY += drawParagraph(item.expectedCredit.formatted(currencyCode: currencyCode),
                                 font: UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold),
                                 color: UIColor.black,
                                 alignment: .left,
                                 in: CGRect(x: margin, y: cursorY, width: contentWidth, height: 32))
        cursorY += 8

        // Detail rows. Empty values are skipped so the tag never prints a dangling label, and rows
        // that would reach the code are left off entirely.
        let rows: [(String, String)] = [
            ("Part no.", item.partNumber),
            ("Vendor", item.vendorName ?? ""),
            ("Bin", item.binLabel ?? ""),
            ("Invoice", item.invoiceReference),
            ("RO", item.repairOrderReference)
        ]
        for row in rows {
            let value = row.1.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard cursorY + detailRowHeight <= textLimit else { break }
            cursorY += drawDetailRow(label: row.0,
                                     value: value,
                                     originY: cursorY,
                                     contentWidth: contentWidth)
            cursorY += rowSpacing
        }

        if let qrImage {
            qrImage.draw(in: qrRect)
        } else {
            UIColor(white: 0.6, alpha: 1).setStroke()
            let outline = UIBezierPath(rect: qrRect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            _ = drawParagraph("No code",
                              font: UIFont.systemFont(ofSize: 12, weight: .regular),
                              color: UIColor.darkGray,
                              alignment: .center,
                              in: CGRect(x: qrRect.minX, y: qrRect.midY - 8,
                                         width: qrRect.width, height: 16))
        }

        // Short identifier, so a tag with a damaged code can still be looked up by hand.
        let shortID = String(item.identifier.uuidString.prefix(8))
        _ = drawParagraph("ID " + shortID,
                          font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                          color: UIColor.darkGray,
                          alignment: .center,
                          in: CGRect(x: margin, y: qrRect.maxY + 2,
                                     width: contentWidth, height: captionHeight))
    }

    /// One "label / value" line, clamped to a single row so the layout stays predictable.
    /// Returns the height it consumed.
    private static func drawDetailRow(label: String,
                                      value: String,
                                      originY: CGFloat,
                                      contentWidth: CGFloat) -> CGFloat {
        let valueWidth = contentWidth - labelColumnWidth
        let labelHeight = drawParagraph(label,
                                        font: UIFont.systemFont(ofSize: 11, weight: .regular),
                                        color: UIColor.darkGray,
                                        alignment: .left,
                                        in: CGRect(x: margin, y: originY,
                                                   width: labelColumnWidth, height: detailRowHeight))
        let valueHeight = drawParagraph(value,
                                        font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                                        color: UIColor.black,
                                        alignment: .left,
                                        in: CGRect(x: margin + labelColumnWidth, y: originY,
                                                   width: valueWidth, height: detailRowHeight))
        return max(labelHeight, valueHeight)
    }

    /// Draws wrapped text inside `rect` and returns the height actually used, clamped to the
    /// rect so a very long part name can never push the QR code off the page.
    @discardableResult
    private static func drawParagraph(_ text: String,
                                      font: UIFont,
                                      color: UIColor,
                                      alignment: NSTextAlignment,
                                      in rect: CGRect) -> CGFloat {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return 0 }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

        let measured = attributed.boundingRect(
            with: CGSize(width: rect.width, height: rect.height),
            options: options,
            context: nil
        )
        let height = min(ceil(measured.height), rect.height)
        let drawRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        attributed.draw(with: drawRect, options: options, context: nil)
        return height
    }

    /// Part name with the same fallback the rest of the app uses.
    private static func displayName(for item: some CoreItemRepresenting) -> String {
        let trimmed = item.partName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled core" : trimmed
    }
}
