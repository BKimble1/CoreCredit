//
//  CSVLedgerExporter.swift
//  CoreCredit
//
//  Pure string building — no file system, no UIKit — so the whole exporter is unit-testable.
//

import Foundation

/// Renders the core ledger as RFC 4180 CSV.
///
/// # Money
///
/// Every amount is written with `Money.plainDecimalString`, which is built from integer division
/// on `Int64` cents. No `Double`, no `NumberFormatter`, no locale grouping separators — a file
/// exported on a German iPhone still opens correctly in a US spreadsheet, and `$86.50` is always
/// exactly `86.50`.
///
/// # Dates
///
/// ISO-8601 calendar dates (`yyyy-MM-dd`) produced by an `en_US_POSIX` formatter, so the output
/// does not change when the device language does.
///
/// # Spreadsheet formula injection
///
/// A cell whose text begins with `=`, `+`, `-`, `@`, a tab, or a carriage return is interpreted as
/// a *formula* by Excel, Numbers, and Google Sheets. A vendor reference typed as `=cmd|…` would
/// therefore execute rather than display. Text columns are defused by prefixing a single quote,
/// which spreadsheets strip on display. Amount columns are **not** defused — a negative
/// discrepancy legitimately starts with `-` and must stay numeric.
enum CSVLedgerExporter {

    /// Column order. Fixed: importers and tests depend on it.
    static let headerRow: [String] = [
        "Part",
        "Part Number",
        "Vendor",
        "Status",
        "Expected Credit",
        "Actual Credit",
        "Difference",
        "Invoice",
        "Repair Order",
        "Credit Reference",
        "Bin",
        "Received",
        "Due",
        "Returned",
        "Credited",
        "Notes"
    ]

    /// RFC 4180 record separator. The specification calls for CRLF, and every spreadsheet on every
    /// platform reads it correctly.
    static let lineTerminator = "\r\n"

    /// Builds the whole file, header row first.
    ///
    /// - Parameters:
    ///   - items: rows, already filtered and sorted by the caller.
    ///   - currencyCode: the shop's currency. Recorded here for signature stability and for the
    ///     accompanying UI copy; the amount columns themselves are intentionally written
    ///     unlocalised and currency-symbol-free so they import as plain numbers.
    static func makeCSV(items: [CoreItemExportSnapshot], currencyCode: String) -> String {
        let dateFormatter = makeDateFormatter()

        var lines: [String] = []
        lines.reserveCapacity(items.count + 1)
        lines.append(headerRow.map { escape($0) }.joined(separator: ","))

        for item in items {
            let difference = RiskCalculator.discrepancy(for: item)

            let fields: [String] = [
                defused(item.partName),
                defused(item.partNumber),
                defused(item.vendorName ?? ""),
                defused(item.status.displayName),
                item.expectedCredit.plainDecimalString,
                item.actualCredit?.plainDecimalString ?? "",
                difference?.plainDecimalString ?? "",
                defused(item.invoiceReference),
                defused(item.repairOrderReference),
                defused(item.creditReference),
                defused(item.binLabel ?? ""),
                isoDate(item.receivedDate, formatter: dateFormatter),
                isoDate(item.dueDate, formatter: dateFormatter),
                isoDate(item.returnedDate, formatter: dateFormatter),
                isoDate(item.creditedDate, formatter: dateFormatter),
                defused(item.notes)
            ]

            lines.append(fields.map { escape($0) }.joined(separator: ","))
        }

        // Trailing terminator: RFC 4180 permits it and most importers prefer it.
        return lines.joined(separator: lineTerminator) + lineTerminator
    }

    /// RFC 4180 field quoting, and nothing else.
    ///
    /// A field containing a comma, a double quote, or a line break is wrapped in double quotes and
    /// its own double quotes are doubled. Everything else is returned untouched — including
    /// amounts, which must stay numeric.
    static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")

        guard needsQuoting else { return field }

        let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"" + doubled + "\""
    }

    // MARK: - Private

    /// Neutralises a leading formula trigger in a **text** field.
    ///
    /// Prefixing with an apostrophe is the standard defence: spreadsheets treat the cell as literal
    /// text and hide the apostrophe, while a plain text viewer shows one harmless extra character.
    /// Applied before `escape(_:)`, and never to a numeric column.
    private static func defused(_ field: String) -> String {
        guard let first = field.first else { return field }
        let triggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        guard triggers.contains(first) else { return field }
        return "'" + field
    }

    private static func isoDate(_ date: Date?, formatter: DateFormatter) -> String {
        guard let date else { return "" }
        return formatter.string(from: date)
    }

    /// A locale-independent `yyyy-MM-dd` formatter.
    ///
    /// `en_US_POSIX` guarantees the pattern means what it says (a Buddhist or Japanese calendar
    /// preference on the device cannot change the year), while the time zone stays the device's own
    /// so the printed day matches the day the user actually recorded.
    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
