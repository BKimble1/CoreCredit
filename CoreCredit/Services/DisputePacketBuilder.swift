//
//  DisputePacketBuilder.swift
//  CoreCredit
//
//  The product's whole promise in one file: the PDF a shop hands a vendor when a core credit is
//  short or never arrived.
//

import Foundation
import UIKit

// MARK: - Page geometry

/// US Letter at 72 dpi, with a half-inch margin and a reserved strip for the running footer.
///
/// Named with a `Packet` prefix so it cannot collide with any other file's private helpers.
private enum PacketPage {
    static let width: CGFloat = 612
    static let height: CGFloat = 792
    static let margin: CGFloat = 48

    /// Vertical space kept clear at the bottom of every page for the footer rule and text.
    static let footerReserve: CGFloat = 28

    static var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    static var contentWidth: CGFloat { width - margin * 2 }
    static var contentTop: CGFloat { margin }
    static var contentBottom: CGFloat { height - margin - footerReserve }
    static var contentHeight: CGFloat { contentBottom - contentTop }
}

// MARK: - Style

/// Fonts and colours for the printed page.
///
/// Every colour is a fixed sRGB value, never a dynamic system colour. A PDF has no trait
/// environment, so `UIColor.label` could resolve to its dark-mode white and render invisibly on
/// white paper.
///
/// Fonts are derived from `UIFont.preferredFont(forTextStyle:)` — so the packet respects the
/// reader's Dynamic Type preference — but each size is clamped to a print-sane range, so a device
/// set to the largest accessibility size still produces a document that fits on a page.
@MainActor
private enum PacketStyle {

    private static func size(_ style: UIFont.TextStyle, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let base = UIFont.preferredFont(forTextStyle: style).pointSize
        if base < minimum { return minimum }
        if base > maximum { return maximum }
        return base
    }

    // Type
    static var shopName: UIFont { UIFont.systemFont(ofSize: size(.title2, minimum: 17, maximum: 20), weight: .bold) }
    static var documentTitle: UIFont { UIFont.systemFont(ofSize: size(.title3, minimum: 15, maximum: 18), weight: .semibold) }
    static var sectionLabel: UIFont { UIFont.systemFont(ofSize: size(.caption1, minimum: 9, maximum: 10.5), weight: .semibold) }
    static var calloutTitle: UIFont { UIFont.systemFont(ofSize: size(.headline, minimum: 13, maximum: 15), weight: .semibold) }
    static var body: UIFont { UIFont.systemFont(ofSize: size(.footnote, minimum: 10, maximum: 11.5), weight: .regular) }
    static var bodyBold: UIFont { UIFont.systemFont(ofSize: size(.footnote, minimum: 10, maximum: 11.5), weight: .semibold) }
    static var footnote: UIFont { UIFont.systemFont(ofSize: size(.caption1, minimum: 8.5, maximum: 10), weight: .regular) }
    static var money: UIFont { UIFont.monospacedDigitSystemFont(ofSize: size(.footnote, minimum: 10, maximum: 11.5), weight: .semibold) }
    static var tableHeader: UIFont { UIFont.systemFont(ofSize: size(.caption1, minimum: 8.5, maximum: 10), weight: .semibold) }
    static var tableBody: UIFont { UIFont.systemFont(ofSize: size(.caption1, minimum: 9, maximum: 10.5), weight: .regular) }
    static var tableMoney: UIFont { UIFont.monospacedDigitSystemFont(ofSize: size(.caption1, minimum: 9, maximum: 10.5), weight: .regular) }

    // Ink
    static var paper: UIColor { UIColor(red: 1, green: 1, blue: 1, alpha: 1) }
    static var ink: UIColor { UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1) }
    static var secondary: UIColor { UIColor(red: 0.38, green: 0.40, blue: 0.44, alpha: 1) }
    static var hairline: UIColor { UIColor(red: 0.80, green: 0.81, blue: 0.84, alpha: 1) }
    static var accent: UIColor { UIColor(red: 0.52, green: 0.34, blue: 0.04, alpha: 1) }
    static var alertInk: UIColor { UIColor(red: 0.54, green: 0.11, blue: 0.11, alpha: 1) }
    static var alertFill: UIColor { UIColor(red: 0.99, green: 0.93, blue: 0.92, alpha: 1) }
    static var positiveInk: UIColor { UIColor(red: 0.09, green: 0.36, blue: 0.21, alpha: 1) }
    static var positiveFill: UIColor { UIColor(red: 0.92, green: 0.97, blue: 0.93, alpha: 1) }
    static var cautionFill: UIColor { UIColor(red: 1.00, green: 0.96, blue: 0.89, alpha: 1) }
    static var neutralFill: UIColor { UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1) }
    static var zebraFill: UIColor { UIColor(red: 0.972, green: 0.974, blue: 0.980, alpha: 1) }
}

// MARK: - Text measuring and drawing

/// Attributed-string helpers. Measuring and drawing use the same options, so a block always lands
/// in exactly the rectangle it was measured for.
@MainActor
private enum PacketText {

    static let drawingOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func make(_ string: String,
                     font: UIFont,
                     color: UIColor,
                     alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0, string.length > 0 else { return 0 }
        let bounding = string.boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: drawingOptions,
            context: nil
        )
        return ceil(bounding.height)
    }

    static func draw(_ string: NSAttributedString, in rect: CGRect) {
        string.draw(with: rect, options: drawingOptions, context: nil)
    }

    /// Splits a run of text into pieces that each fit inside `maxHeight`.
    ///
    /// Without this, a five-thousand-character note would be measured as one block taller than a
    /// page and silently clipped. Splitting on word boundaries keeps the text readable across the
    /// page break.
    static func chunks(of text: String, font: UIFont, width: CGFloat, maxHeight: CGFloat) -> [String] {
        guard width > 0, maxHeight > 0, !text.isEmpty else { return [] }

        let whole = make(text, font: font, color: PacketStyle.ink)
        if height(of: whole, width: width) <= maxHeight {
            return [text]
        }

        var pieces: [String] = []
        var current = ""

        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + String(word)
            let candidateHeight = height(of: make(candidate, font: font, color: PacketStyle.ink), width: width)
            if candidateHeight > maxHeight && !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }

        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [text] : pieces
    }
}

// MARK: - Table column

/// One cell in a fixed-width table row.
private struct PacketColumn {
    var text: String
    var width: CGFloat
    var alignment: NSTextAlignment
    var font: UIFont
    var color: UIColor
}

// MARK: - Page writer

/// A top-down cursor over a multi-page PDF.
///
/// Every drawing call measures first, asks `ensure(_:)` whether the block still fits, starts a new
/// page when it does not, and only then draws. Nothing is ever clipped or written over the footer.
@MainActor
private final class PacketPageWriter {

    private let context: UIGraphicsPDFRendererContext
    private let footerText: String
    private let continuationHeader: String

    /// 1-based page number of the page currently being written.
    private(set) var pageIndex = 0

    /// Current baseline for the next block, in page coordinates.
    private(set) var y: CGFloat = 0

    /// Gap between table columns.
    private let columnGutter: CGFloat = 8

    /// Width of the label column in `labeledRow(label:value:)`.
    private let labelColumnWidth: CGFloat = 128

    /// Padding above and below the text in a table row.
    private let rowVerticalPadding: CGFloat = 4

    init(context: UIGraphicsPDFRendererContext, footerText: String, continuationHeader: String) {
        self.context = context
        self.footerText = footerText
        self.continuationHeader = continuationHeader
    }

    // MARK: Pages

    /// Starts the first page. Must be called exactly once, before any drawing.
    func beginDocument() {
        newPage()
    }

    func newPage() {
        context.beginPage()
        pageIndex += 1
        y = PacketPage.contentTop

        // PDF pages are transparent by default; painting the sheet white keeps the document
        // looking the same in every viewer and when printed.
        context.cgContext.setFillColor(PacketStyle.paper.cgColor)
        context.cgContext.fill(PacketPage.bounds)

        drawFooter()
        if pageIndex > 1 {
            drawContinuationHeader()
        }
    }

    /// Starts a new page when `height` will not fit under the current cursor.
    func ensure(_ height: CGFloat) {
        guard pageIndex > 0 else {
            newPage()
            return
        }
        if y + height > PacketPage.contentBottom {
            newPage()
        }
    }

    /// Adds vertical space without a page-fit check — the next measured block will break if needed.
    func space(_ amount: CGFloat) {
        y += amount
    }

    // MARK: Blocks

    /// Draws a run of text, honouring embedded newlines and breaking across pages when necessary.
    @discardableResult
    func text(_ string: String,
              font: UIFont,
              color: UIColor,
              indent: CGFloat = 0,
              alignment: NSTextAlignment = .left,
              spacingAfter: CGFloat = 4) -> CGFloat {
        guard !string.isEmpty else { return 0 }

        let width = max(PacketPage.contentWidth - indent, 1)
        let paragraphs = string.components(separatedBy: "\n")
        var drawn: CGFloat = 0

        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.isEmpty {
                let gap = font.lineHeight * 0.5
                y += gap
                drawn += gap
                continue
            }

            for chunk in PacketText.chunks(of: paragraph,
                                           font: font,
                                           width: width,
                                           maxHeight: PacketPage.contentHeight) {
                let attributed = PacketText.make(chunk, font: font, color: color, alignment: alignment)
                let height = PacketText.height(of: attributed, width: width)
                ensure(height)
                PacketText.draw(
                    attributed,
                    in: CGRect(x: PacketPage.margin + indent, y: y, width: width, height: height)
                )
                y += height
                drawn += height
            }

            if index < paragraphs.count - 1 {
                y += 2
                drawn += 2
            }
        }

        y += spacingAfter
        return drawn
    }

    /// A horizontal hairline across the content width.
    func rule(thickness: CGFloat = 0.5, color: UIColor? = nil, spacingAfter: CGFloat = 8) {
        ensure(thickness + spacingAfter)
        let rect = CGRect(x: PacketPage.margin, y: y, width: PacketPage.contentWidth, height: thickness)
        context.cgContext.setFillColor((color ?? PacketStyle.hairline).cgColor)
        context.cgContext.fill(rect)
        y += thickness + spacingAfter
    }

    /// A small capitalised section heading with a rule under it.
    ///
    /// Reserves enough height for the heading plus the first row of its section, so a heading can
    /// never be orphaned at the foot of a page.
    func sectionHeader(_ title: String) {
        ensure(72)
        y += 10
        text(title.uppercased(), font: PacketStyle.sectionLabel, color: PacketStyle.accent, spacingAfter: 3)
        rule(thickness: 0.75, spacingAfter: 9)
    }

    /// A label on the left and its value on the right. Empty values print an em dash so a reader
    /// can tell "not recorded" from "accidentally omitted".
    func labeledRow(label: String,
                    value: String,
                    valueFont: UIFont? = nil,
                    valueColor: UIColor? = nil) {
        let valueWidth = max(PacketPage.contentWidth - labelColumnWidth - columnGutter, 1)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let labelString = PacketText.make(label, font: PacketStyle.body, color: PacketStyle.secondary)
        let valueString = PacketText.make(
            trimmedValue.isEmpty ? "—" : trimmedValue,
            font: valueFont ?? PacketStyle.bodyBold,
            color: trimmedValue.isEmpty ? PacketStyle.secondary : (valueColor ?? PacketStyle.ink)
        )

        let labelHeight = PacketText.height(of: labelString, width: labelColumnWidth)
        let valueHeight = PacketText.height(of: valueString, width: valueWidth)
        let rowHeight = max(labelHeight, valueHeight)

        ensure(rowHeight + 6)
        PacketText.draw(
            labelString,
            in: CGRect(x: PacketPage.margin, y: y, width: labelColumnWidth, height: labelHeight)
        )
        PacketText.draw(
            valueString,
            in: CGRect(x: PacketPage.margin + labelColumnWidth + columnGutter,
                       y: y,
                       width: valueWidth,
                       height: valueHeight)
        )
        y += rowHeight + 6
    }

    /// A tinted box carrying the single most important sentence on the page.
    func callout(title: String, message: String, fill: UIColor, textColor: UIColor) {
        let inset: CGFloat = 12
        let innerWidth = max(PacketPage.contentWidth - inset * 2, 1)

        let titleString = PacketText.make(title, font: PacketStyle.calloutTitle, color: textColor)
        let titleHeight = PacketText.height(of: titleString, width: innerWidth)

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageString = PacketText.make(trimmedMessage, font: PacketStyle.body, color: textColor)
        let messageHeight = trimmedMessage.isEmpty ? 0 : PacketText.height(of: messageString, width: innerWidth)

        var boxHeight = inset * 2 + titleHeight
        if messageHeight > 0 { boxHeight += messageHeight + 5 }

        ensure(boxHeight + 12)

        let box = CGRect(x: PacketPage.margin, y: y, width: PacketPage.contentWidth, height: boxHeight)
        let path = UIBezierPath(roundedRect: box, cornerRadius: 8)
        context.cgContext.setFillColor(fill.cgColor)
        context.cgContext.addPath(path.cgPath)
        context.cgContext.fillPath()

        var innerY = box.minY + inset
        PacketText.draw(
            titleString,
            in: CGRect(x: box.minX + inset, y: innerY, width: innerWidth, height: titleHeight)
        )
        innerY += titleHeight

        if messageHeight > 0 {
            innerY += 5
            PacketText.draw(
                messageString,
                in: CGRect(x: box.minX + inset, y: innerY, width: innerWidth, height: messageHeight)
            )
        }

        y += boxHeight + 12
    }

    /// The exact height `row(_:background:separator:)` will consume.
    ///
    /// Callers that need to repeat a table heading after a page break measure first, `ensure(_:)`
    /// the height themselves, and only then draw — otherwise the row would break the page on its
    /// own and land under no heading at all.
    func measureRow(_ columns: [PacketColumn], separator: Bool = true) -> CGFloat {
        var tallest: CGFloat = 0
        for column in columns {
            let usableWidth = max(column.width - columnGutter, 1)
            let string = PacketText.make(
                column.text,
                font: column.font,
                color: column.color,
                alignment: column.alignment
            )
            tallest = max(tallest, PacketText.height(of: string, width: usableWidth))
        }
        return tallest + rowVerticalPadding * 2 + (separator ? 0.5 : 0)
    }

    /// One table row. Column widths must sum to at most the content width.
    func row(_ columns: [PacketColumn], background: UIColor? = nil, separator: Bool = true) {
        guard !columns.isEmpty else { return }

        var strings: [NSAttributedString] = []
        var heights: [CGFloat] = []
        for column in columns {
            let usableWidth = max(column.width - columnGutter, 1)
            let string = PacketText.make(
                column.text,
                font: column.font,
                color: column.color,
                alignment: column.alignment
            )
            strings.append(string)
            heights.append(PacketText.height(of: string, width: usableWidth))
        }

        let rowHeight = heights.max() ?? 0
        ensure(rowHeight + rowVerticalPadding * 2 + (separator ? 0.5 : 0))

        if let background {
            let rect = CGRect(
                x: PacketPage.margin,
                y: y,
                width: PacketPage.contentWidth,
                height: rowHeight + rowVerticalPadding * 2
            )
            context.cgContext.setFillColor(background.cgColor)
            context.cgContext.fill(rect)
        }

        var x = PacketPage.margin
        for (index, column) in columns.enumerated() {
            let usableWidth = max(column.width - columnGutter, 1)
            PacketText.draw(
                strings[index],
                in: CGRect(x: x, y: y + rowVerticalPadding, width: usableWidth, height: heights[index])
            )
            x += column.width
        }

        y += rowHeight + rowVerticalPadding * 2

        if separator {
            let rect = CGRect(x: PacketPage.margin, y: y, width: PacketPage.contentWidth, height: 0.5)
            context.cgContext.setFillColor(PacketStyle.hairline.cgColor)
            context.cgContext.fill(rect)
            y += 0.5
        }
    }

    /// A captioned evidence photo, scaled to fit and never distorted.
    ///
    /// The caption and its image are measured as one block, so a caption is never stranded at the
    /// foot of a page with its photo overleaf.
    func image(_ image: UIImage, caption: String) {
        let naturalSize = image.size
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }

        let maxWidth = PacketPage.contentWidth
        let maxHeight: CGFloat = 320

        // A single scale factor for both axes preserves the aspect ratio; capping it at 1 stops a
        // small photo being blown up into a blur.
        let fitScale = min(maxWidth / naturalSize.width, maxHeight / naturalSize.height)
        let scale = min(fitScale, 1)
        let drawnWidth = max(naturalSize.width * scale, 1)
        let drawnHeight = max(naturalSize.height * scale, 1)

        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionString = PacketText.make(trimmedCaption, font: PacketStyle.footnote, color: PacketStyle.secondary)
        let captionHeight = trimmedCaption.isEmpty ? 0 : PacketText.height(of: captionString, width: maxWidth)

        let blockHeight = captionHeight + (captionHeight > 0 ? 4 : 0) + drawnHeight + 14
        ensure(blockHeight)

        if captionHeight > 0 {
            PacketText.draw(
                captionString,
                in: CGRect(x: PacketPage.margin, y: y, width: maxWidth, height: captionHeight)
            )
            y += captionHeight + 4
        }

        let frame = CGRect(x: PacketPage.margin, y: y, width: drawnWidth, height: drawnHeight)
        image.draw(in: frame)

        context.cgContext.setStrokeColor(PacketStyle.hairline.cgColor)
        context.cgContext.setLineWidth(0.5)
        context.cgContext.stroke(frame)

        y += drawnHeight + 14
    }

    // MARK: Furniture

    private func drawFooter() {
        let trimmed = footerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageText = "Page " + String(pageIndex)
        let footerLine = trimmed.isEmpty ? pageText : trimmed + "   ·   " + pageText

        let attributed = PacketText.make(footerLine, font: PacketStyle.footnote, color: PacketStyle.secondary, alignment: .center)
        let height = PacketText.height(of: attributed, width: PacketPage.contentWidth)
        let footerY = PacketPage.height - PacketPage.margin - height

        let lineRect = CGRect(x: PacketPage.margin, y: footerY - 8, width: PacketPage.contentWidth, height: 0.5)
        context.cgContext.setFillColor(PacketStyle.hairline.cgColor)
        context.cgContext.fill(lineRect)

        PacketText.draw(
            attributed,
            in: CGRect(x: PacketPage.margin, y: footerY, width: PacketPage.contentWidth, height: height)
        )
    }

    private func drawContinuationHeader() {
        let trimmed = continuationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let attributed = PacketText.make(trimmed, font: PacketStyle.footnote, color: PacketStyle.secondary)
        let height = PacketText.height(of: attributed, width: PacketPage.contentWidth)
        PacketText.draw(
            attributed,
            in: CGRect(x: PacketPage.margin, y: y, width: PacketPage.contentWidth, height: height)
        )
        y += height + 6

        let lineRect = CGRect(x: PacketPage.margin, y: y, width: PacketPage.contentWidth, height: 0.5)
        context.cgContext.setFillColor(PacketStyle.hairline.cgColor)
        context.cgContext.fill(lineRect)
        y += 14
    }
}

// MARK: - Builder

/// Renders the two PDFs CoreCredit produces.
///
/// - `makePDFData(item:shop:images:generatedAt:)` — the **dispute packet**: everything a parts
///   manager needs to settle one short-paid core, on paper, without opening the app.
/// - `makeLedgerPDFData(items:shop:summary:generatedAt:)` — the **ledger report**: a compact
///   portfolio-level view, totals first, then one row per core.
///
/// `@MainActor` because UIKit text measurement and `UIGraphicsPDFRenderer` belong there. Errors
/// are thrown as `ExportError.renderingFailed`; nothing here traps.
@MainActor
enum DisputePacketBuilder {

    /// Ledger table column widths — Part, Vendor, Status, Due, Charge, Credited.
    /// They sum to 516 pt, exactly the content width of a US Letter page at a half-inch margin.
    private static let ledgerColumnWidths: [CGFloat] = [156, 92, 88, 62, 60, 58]

    // MARK: Dispute packet

    /// Builds the multi-page dispute packet for a single core.
    ///
    /// Sections, in order: shop letterhead, document title and generation stamp, vendor and part
    /// identification, the financial summary with the discrepancy stated in plain English, key
    /// dates, the status timeline, notes, and the evidence photos.
    ///
    /// - Parameters:
    ///   - item: the frozen core item.
    ///   - shop: letterhead details.
    ///   - images: captioned photo data, already downsized by `SnapshotBuilder.evidenceImages`.
    ///     Anything that cannot be decoded is skipped rather than failing the export.
    ///   - generatedAt: the stamp printed under the title.
    /// - Throws: `ExportError.renderingFailed` when the renderer produces no bytes.
    static func makePDFData(item: CoreItemExportSnapshot,
                            shop: ShopProfileSnapshot,
                            images: [(caption: String, data: Data)],
                            generatedAt: Date) throws -> Data {

        let currencyCode = shop.currencyCode
        let dayFormatter = makeFormatter(dateFormat: "d MMMM yyyy")
        let stampFormatter = makeFormatter(dateFormat: "d MMM yyyy 'at' h:mm a")
        let eventFormatter = makeFormatter(dateFormat: "d MMM yyyy, h:mm a")

        let documentTitle = "Core Credit Dispute Packet"
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = documentInfo(title: documentTitle + " — " + item.displayTitle)

        let renderer = UIGraphicsPDFRenderer(bounds: PacketPage.bounds, format: format)

        // Decode up front so a corrupt attachment cannot interrupt the drawing pass.
        let photographs: [(caption: String, image: UIImage)] = images.compactMap { entry -> (caption: String, image: UIImage)? in
            guard let decoded = UIImage(data: entry.data) else { return nil }
            return (caption: entry.caption, image: decoded)
        }

        let data = renderer.pdfData { context in
            let writer = PacketPageWriter(
                context: context,
                footerText: shop.displayName + "   ·   " + documentTitle,
                continuationHeader: documentTitle + " (continued) — " + item.displayTitle
            )
            writer.beginDocument()

            drawLetterhead(
                writer: writer,
                shop: shop,
                documentTitle: documentTitle,
                generatedAt: generatedAt,
                stampFormatter: stampFormatter
            )
            drawIdentification(writer: writer, item: item)
            drawFinancialSummary(writer: writer, item: item, currencyCode: currencyCode)
            drawKeyDates(writer: writer, item: item, formatter: dayFormatter)
            drawTimeline(writer: writer, item: item, currencyCode: currencyCode, formatter: eventFormatter)
            drawNotes(writer: writer, item: item)
            drawEvidence(writer: writer, photographs: photographs)
        }

        guard !data.isEmpty else {
            throw ExportError.renderingFailed("The dispute packet could not be rendered.")
        }
        return data
    }

    // MARK: Ledger report

    /// Builds the compact portfolio report: the `RiskSummary` totals, then one row per core.
    ///
    /// - Throws: `ExportError.renderingFailed` when the renderer produces no bytes.
    static func makeLedgerPDFData(items: [CoreItemExportSnapshot],
                                  shop: ShopProfileSnapshot,
                                  summary: RiskSummary,
                                  generatedAt: Date) throws -> Data {

        let currencyCode = shop.currencyCode
        let shortFormatter = makeFormatter(dateFormat: "d MMM yyyy")
        let stampFormatter = makeFormatter(dateFormat: "d MMM yyyy 'at' h:mm a")

        // The report is a snapshot taken at `generatedAt`, so "overdue" is judged against that
        // moment on the device's own calendar.
        let calendar = Calendar.current

        let documentTitle = "Core Ledger Report"
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = documentInfo(title: documentTitle + " — " + shop.displayName)

        let renderer = UIGraphicsPDFRenderer(bounds: PacketPage.bounds, format: format)

        let data = renderer.pdfData { context in
            let writer = PacketPageWriter(
                context: context,
                footerText: shop.displayName + "   ·   " + documentTitle,
                continuationHeader: documentTitle + " (continued)"
            )
            writer.beginDocument()

            drawLetterhead(
                writer: writer,
                shop: shop,
                documentTitle: documentTitle,
                generatedAt: generatedAt,
                stampFormatter: stampFormatter
            )
            drawPortfolioSummary(writer: writer, summary: summary, currencyCode: currencyCode)
            drawLedgerTable(
                writer: writer,
                items: items,
                summary: summary,
                currencyCode: currencyCode,
                formatter: shortFormatter,
                generatedAt: generatedAt,
                calendar: calendar
            )
        }

        guard !data.isEmpty else {
            throw ExportError.renderingFailed("The ledger report could not be rendered.")
        }
        return data
    }

    // MARK: - Sections

    private static func drawLetterhead(writer: PacketPageWriter,
                                       shop: ShopProfileSnapshot,
                                       documentTitle: String,
                                       generatedAt: Date,
                                       stampFormatter: DateFormatter) {
        writer.text(shop.displayName, font: PacketStyle.shopName, color: PacketStyle.ink, spacingAfter: 3)

        let contact = shop.contactSummary
        if !contact.isEmpty {
            writer.text(contact, font: PacketStyle.footnote, color: PacketStyle.secondary, spacingAfter: 1)
        }
        for line in shop.addressLines {
            writer.text(line, font: PacketStyle.footnote, color: PacketStyle.secondary, spacingAfter: 1)
        }

        writer.space(10)
        writer.rule(thickness: 1.2, color: PacketStyle.ink, spacingAfter: 12)

        writer.text(documentTitle, font: PacketStyle.documentTitle, color: PacketStyle.ink, spacingAfter: 3)
        writer.text(
            "Generated " + stampFormatter.string(from: generatedAt),
            font: PacketStyle.footnote,
            color: PacketStyle.secondary,
            spacingAfter: 12
        )
    }

    private static func drawIdentification(writer: PacketPageWriter, item: CoreItemExportSnapshot) {
        writer.sectionHeader("Vendor and part")
        writer.labeledRow(label: "Vendor", value: item.vendorName ?? "")
        writer.labeledRow(label: "Part", value: item.displayTitle)
        writer.labeledRow(label: "Part number", value: item.partNumber)
        writer.labeledRow(label: "Invoice", value: item.invoiceReference)
        writer.labeledRow(label: "Repair order", value: item.repairOrderReference)
        writer.labeledRow(label: "Storage bin", value: item.binLabel ?? "")
        writer.labeledRow(label: "Return batch", value: item.returnBatchReference ?? "")
        writer.labeledRow(label: "Return method", value: item.returnMethod?.displayName ?? "")
        writer.labeledRow(label: "Current status", value: item.status.displayName)
    }

    private static func drawFinancialSummary(writer: PacketPageWriter,
                                             item: CoreItemExportSnapshot,
                                             currencyCode: String) {
        writer.sectionHeader("Credit summary")

        writer.labeledRow(
            label: "Core charge invoiced",
            value: item.expectedCredit.formatted(currencyCode: currencyCode),
            valueFont: PacketStyle.money
        )

        if let actual = item.actualCredit {
            writer.labeledRow(
                label: "Credit received",
                value: actual.formatted(currencyCode: currencyCode),
                valueFont: PacketStyle.money
            )
            writer.labeledRow(label: "Credit reference", value: item.creditReference)
        } else {
            writer.labeledRow(label: "Credit received", value: "None recorded")
        }

        writer.space(4)

        let callout = discrepancyCallout(for: item, currencyCode: currencyCode)
        writer.callout(
            title: callout.title,
            message: callout.message,
            fill: callout.fill,
            textColor: callout.textColor
        )
    }

    /// Turns `RiskCalculator.discrepancy` into the one sentence the whole packet exists to make.
    private static func discrepancyCallout(for item: CoreItemExportSnapshot,
                                           currencyCode: String)
        -> (title: String, message: String, fill: UIColor, textColor: UIColor) {

        let expectedText = item.expectedCredit.formatted(currencyCode: currencyCode)

        guard let difference = RiskCalculator.discrepancy(for: item) else {
            return (
                title: "No credit received",
                message: "No vendor credit has been recorded against this core charge. "
                    + expectedText + " remains outstanding.",
                fill: PacketStyle.cautionFill,
                textColor: PacketStyle.ink
            )
        }

        let receivedText = (item.actualCredit ?? .zero).formatted(currencyCode: currencyCode)

        if difference.isZero {
            return (
                title: "Credit matches the core charge",
                message: "The credit of " + receivedText + " matches the core charge in full. "
                    + "No further action is required.",
                fill: PacketStyle.positiveFill,
                textColor: PacketStyle.positiveInk
            )
        }

        if difference.isPositive {
            return (
                title: "Short by " + difference.formatted(currencyCode: currencyCode),
                message: "The core charge was " + expectedText + ". The credit received was "
                    + receivedText + ". "
                    + difference.formatted(currencyCode: currencyCode)
                    + " is still owed to this shop.",
                fill: PacketStyle.alertFill,
                textColor: PacketStyle.alertInk
            )
        }

        let overage = difference.magnitude
        return (
            title: "Over-credited by " + overage.formatted(currencyCode: currencyCode),
            message: "The core charge was " + expectedText + ". The credit received was "
                + receivedText + ", which is "
                + overage.formatted(currencyCode: currencyCode) + " more than invoiced.",
            fill: PacketStyle.neutralFill,
            textColor: PacketStyle.ink
        )
    }

    private static func drawKeyDates(writer: PacketPageWriter,
                                     item: CoreItemExportSnapshot,
                                     formatter: DateFormatter) {
        writer.sectionHeader("Key dates")
        writer.labeledRow(label: "Core received", value: formatter.string(from: item.receivedDate))
        writer.labeledRow(label: "Return due", value: formatted(item.dueDate, formatter))
        writer.labeledRow(label: "Returned to vendor", value: formatted(item.returnedDate, formatter))
        writer.labeledRow(label: "Credit issued", value: formatted(item.creditedDate, formatter))
    }

    private static func drawTimeline(writer: PacketPageWriter,
                                     item: CoreItemExportSnapshot,
                                     currencyCode: String,
                                     formatter: DateFormatter) {
        writer.sectionHeader("Status history")

        guard !item.events.isEmpty else {
            writer.text(
                "No history has been recorded for this core.",
                font: PacketStyle.body,
                color: PacketStyle.secondary,
                spacingAfter: 6
            )
            return
        }

        for event in item.events {
            writer.text(
                timelineLine(for: event, currencyCode: currencyCode, formatter: formatter),
                font: PacketStyle.body,
                color: PacketStyle.ink,
                spacingAfter: 5
            )
        }
    }

    /// `"12 Mar 2026, 9:15 AM — Credit recorded — Vendor issued $75.00 · Ref CM-4471"`
    private static func timelineLine(for event: CoreEventSnapshot,
                                     currencyCode: String,
                                     formatter: DateFormatter) -> String {
        var parts: [String] = [formatter.string(from: event.timestamp), event.type.displayName]

        var detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)

        if detail.isEmpty, let from = event.fromStatus, let to = event.toStatus {
            detail = from.displayName + " → " + to.displayName
        }

        if let amount = event.amount {
            let amountText = amount.formatted(currencyCode: currencyCode)
            detail = detail.isEmpty ? amountText : detail + " (" + amountText + ")"
        }

        let reference = event.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty {
            detail = detail.isEmpty ? "Ref " + reference : detail + " · Ref " + reference
        }

        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " — ")
    }

    private static func drawNotes(writer: PacketPageWriter, item: CoreItemExportSnapshot) {
        let notes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        writer.sectionHeader("Notes")
        writer.text(notes, font: PacketStyle.body, color: PacketStyle.ink, spacingAfter: 6)
    }

    private static func drawEvidence(writer: PacketPageWriter,
                                     photographs: [(caption: String, image: UIImage)]) {
        guard !photographs.isEmpty else { return }

        writer.sectionHeader("Evidence photographs")
        for photograph in photographs {
            writer.image(photograph.image, caption: photograph.caption)
        }
    }

    // MARK: - Ledger sections

    private static func drawPortfolioSummary(writer: PacketPageWriter,
                                             summary: RiskSummary,
                                             currencyCode: String) {
        writer.sectionHeader("Portfolio")

        writer.callout(
            title: "Money at risk: " + summary.moneyAtRisk.formatted(currencyCode: currencyCode),
            message: String(summary.unresolvedCount) + " unresolved "
                + (summary.unresolvedCount == 1 ? "core" : "cores") + ", of which "
                + String(summary.overdueCount) + " "
                + (summary.overdueCount == 1 ? "is" : "are") + " past the return deadline ("
                + summary.overdueAmount.formatted(currencyCode: currencyCode) + ").",
            fill: summary.overdueCount > 0 ? PacketStyle.alertFill : PacketStyle.neutralFill,
            textColor: summary.overdueCount > 0 ? PacketStyle.alertInk : PacketStyle.ink
        )

        for bucket in summary.agingBuckets {
            writer.labeledRow(
                label: bucket.bucket.displayName,
                value: String(bucket.count) + " " + (bucket.count == 1 ? "core" : "cores")
                    + "   ·   " + bucket.amount.formatted(currencyCode: currencyCode),
                valueFont: PacketStyle.money
            )
        }
    }

    private static func drawLedgerTable(writer: PacketPageWriter,
                                        items: [CoreItemExportSnapshot],
                                        summary: RiskSummary,
                                        currencyCode: String,
                                        formatter: DateFormatter,
                                        generatedAt: Date,
                                        calendar: Calendar) {
        writer.sectionHeader("Cores")

        guard !items.isEmpty else {
            writer.text(
                "There are no cores in this report.",
                font: PacketStyle.body,
                color: PacketStyle.secondary,
                spacingAfter: 6
            )
            return
        }

        drawLedgerHeaderRow(writer: writer)
        var lastPageIndex = writer.pageIndex

        for (offset, item) in items.enumerated() {
            let overdue = RiskCalculator.isOverdue(item, now: generatedAt, calendar: calendar)

            var partText = item.displayTitle
            let partNumber = item.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partNumber.isEmpty {
                partText += "\n" + partNumber
            }

            let columns: [PacketColumn] = [
                PacketColumn(text: partText,
                             width: ledgerColumnWidths[0],
                             alignment: .left,
                             font: PacketStyle.tableBody,
                             color: PacketStyle.ink),
                PacketColumn(text: item.vendorName ?? "—",
                             width: ledgerColumnWidths[1],
                             alignment: .left,
                             font: PacketStyle.tableBody,
                             color: PacketStyle.ink),
                PacketColumn(text: item.status.shortName,
                             width: ledgerColumnWidths[2],
                             alignment: .left,
                             font: PacketStyle.tableBody,
                             color: item.status == .disputed ? PacketStyle.alertInk : PacketStyle.ink),
                PacketColumn(text: item.dueDate.map { formatter.string(from: $0) } ?? "—",
                             width: ledgerColumnWidths[3],
                             alignment: .left,
                             font: PacketStyle.tableBody,
                             color: overdue ? PacketStyle.alertInk : PacketStyle.secondary),
                PacketColumn(text: item.expectedCredit.formatted(currencyCode: currencyCode),
                             width: ledgerColumnWidths[4],
                             alignment: .right,
                             font: PacketStyle.tableMoney,
                             color: PacketStyle.ink),
                PacketColumn(text: item.actualCredit.map { $0.formatted(currencyCode: currencyCode) } ?? "—",
                             width: ledgerColumnWidths[5],
                             alignment: .right,
                             font: PacketStyle.tableMoney,
                             color: PacketStyle.secondary)
            ]

            // Measure first so a row that will not fit takes its column headings with it onto the
            // next page, instead of appearing under a bare page break.
            let rowHeight = writer.measureRow(columns)
            writer.ensure(rowHeight)
            if writer.pageIndex != lastPageIndex {
                lastPageIndex = writer.pageIndex
                drawLedgerHeaderRow(writer: writer)
                writer.ensure(rowHeight)
            }

            writer.row(columns, background: offset.isMultiple(of: 2) ? nil : PacketStyle.zebraFill)
        }

        writer.space(6)
        writer.labeledRow(
            label: "Total money at risk",
            value: summary.moneyAtRisk.formatted(currencyCode: currencyCode),
            valueFont: PacketStyle.money
        )
    }

    private static func drawLedgerHeaderRow(writer: PacketPageWriter) {
        let titles = ["Part", "Vendor", "Status", "Due", "Charge", "Credited"]
        let alignments: [NSTextAlignment] = [.left, .left, .left, .left, .right, .right]

        var columns: [PacketColumn] = []
        for (index, title) in titles.enumerated() {
            columns.append(
                PacketColumn(
                    text: title.uppercased(),
                    width: ledgerColumnWidths[index],
                    alignment: alignments[index],
                    font: PacketStyle.tableHeader,
                    color: PacketStyle.secondary
                )
            )
        }
        writer.row(columns, background: nil, separator: true)
    }

    // MARK: - Helpers

    /// PDF metadata, so the file identifies itself in Finder, Files, and Preview.
    private static func documentInfo(title: String) -> [String: Any] {
        [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: AppConfiguration.displayName + " " + AppConfiguration.versionDisplayString
        ]
    }

    private static func formatted(_ date: Date?, _ formatter: DateFormatter) -> String {
        guard let date else { return "" }
        return formatter.string(from: date)
    }

    /// A fresh formatter per document. Month names and clock format follow the device's locale, so
    /// the packet reads naturally to whoever printed it — but the calendar is pinned to Gregorian
    /// so a business document can never come out carrying a non-Gregorian era year.
    private static func makeFormatter(dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = dateFormat
        return formatter
    }
}
