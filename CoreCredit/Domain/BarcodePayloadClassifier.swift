//
//  BarcodePayloadClassifier.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only — no Vision, no VisionKit. The symbology arrives as the
//  `VNBarcodeSymbology.rawValue` string, so this file (and its tests) never need the framework.
//
//  ## The mistake this file exists to prevent
//
//  A UPC on a box is a *product* code: it identifies "this SKU from this brand". A manufacturer
//  part number is what the vendor's credit department matches a returned core against. They are
//  not the same number, and pre-filling the part-number field with a UPC produces a return the
//  vendor rejects weeks later.
//
//  So the rule here is blunt: a numeric linear symbology (UPC-A/E, EAN-8/13, ITF-14, GS1 DataBar)
//  **never** produces a part-number candidate. Only an alphanumeric linear symbology (Code 39,
//  Code 128 — the kind printed on a parts bin label), or an unambiguous GS1 AI 240/241 element
//  ("additional product identification", which is exactly what a part number is), may.
//
//  The raw payload is always offered as its own `.barcode` candidate so it can be stored verbatim
//  next to — never instead of — the confirmed part number.
//

import Foundation

/// One symbol read, as handed over by the scanner.
struct BarcodeScanInput: Equatable, Sendable {

    /// The decoded string exactly as the symbol carried it, control characters and all. GS1
    /// separators must survive into here or the payload can no longer be parsed.
    var payload: String

    /// `VNBarcodeSymbology.rawValue`, e.g. `"VNBarcodeSymbologyCode128"`.
    var symbology: String

    var source: ScanSource

    init(payload: String, symbology: String, source: ScanSource = .liveBarcode) {
        self.payload = payload
        self.symbology = symbology
        self.source = source
    }
}

/// The families of symbology this app treats differently.
enum BarcodeSymbologyClass: String, Sendable {

    /// UPC-A/E, EAN-8/13, ITF-14, GS1 DataBar. A **product** code, not a part number.
    case linearNumeric

    /// Code 39, Code 93, Code 128, Codabar. May carry a manufacturer part number.
    case linearAlphanumeric

    /// QR, DataMatrix, PDF417, Aztec, and their micro variants.
    case twoDimensional

    /// Anything the app has not been taught about.
    case unknown

    /// Ordered longest-token-first so `Code39FullASCII` is not swallowed by `Code39`, and so
    /// `MicroPDF417` is not read as `PDF417`. First match wins.
    ///
    /// Matching is on a lowercased form of `VNBarcodeSymbology.rawValue` with the
    /// `vnbarcodesymbology` prefix removed, so both `"VNBarcodeSymbologyCode128"` and a bare
    /// `"code128"` classify identically.
    private static let tokens: [(token: String, symbologyClass: BarcodeSymbologyClass)] = [
        ("code39fullascii", .linearAlphanumeric),
        ("code39checksum", .linearAlphanumeric),
        ("interleaved2of5", .linearNumeric),
        ("micropdf417", .twoDimensional),
        ("datamatrix", .twoDimensional),
        ("gs1databar", .linearNumeric),
        ("databar", .linearNumeric),
        ("code128", .linearAlphanumeric),
        ("codabar", .linearAlphanumeric),
        ("microqr", .twoDimensional),
        ("pdf417", .twoDimensional),
        ("code39", .linearAlphanumeric),
        ("code93", .linearAlphanumeric),
        ("code11", .linearAlphanumeric),
        ("i2of5", .linearNumeric),
        ("itf14", .linearNumeric),
        ("aztec", .twoDimensional),
        ("ean13", .linearNumeric),
        ("upca", .linearNumeric),
        ("upce", .linearNumeric),
        ("ean8", .linearNumeric),
        ("itf", .linearNumeric),
        ("msi", .linearNumeric),
        ("ean", .linearNumeric),
        ("upc", .linearNumeric),
        ("qr", .twoDimensional)
    ]

    /// Matches on `VNBarcodeSymbology.rawValue`, case-insensitively.
    static func classify(_ symbologyRawValue: String) -> BarcodeSymbologyClass {
        let lowercased = symbologyRawValue.lowercased()
        let trimmed = lowercased.hasPrefix("vnbarcodesymbology")
            ? String(lowercased.dropFirst("vnbarcodesymbology".count))
            : lowercased
        guard !trimmed.isEmpty else { return .unknown }

        for entry in tokens where trimmed.contains(entry.token) {
            return entry.symbologyClass
        }
        return .unknown
    }

    var displayName: String {
        switch self {
        case .linearNumeric: return "Numeric product code"
        case .linearAlphanumeric: return "Alphanumeric barcode"
        case .twoDimensional: return "2-D code"
        case .unknown: return "Barcode"
        }
    }
}

/// One GS1 element string: an Application Identifier and the value that belongs to it.
struct GS1Element: Equatable, Sendable {

    /// The AI itself, e.g. `"01"` or `"240"`. Kept as a string — AIs have leading zeros.
    var applicationIdentifier: String

    /// The value, exactly as it appeared in the payload.
    var value: String

    init(applicationIdentifier: String, value: String) {
        self.applicationIdentifier = applicationIdentifier
        self.value = value
    }
}

/// A deliberately timid GS1 element-string parser.
///
/// ## What "unambiguous" means here
///
/// A GS1 payload is only self-describing when either of these holds:
///
/// **(a) explicit separators are present** — an FNC1 / GS (`U+001D`) somewhere in the payload, or a
/// leading AIM symbology identifier such as `]C1`. Variable-length fields end at a separator, so
/// with separators present the structure can be walked without guessing.
///
/// **(b) every element uses a known fixed-length AI and the payload is consumed exactly.** No
/// variable-length AI is allowed in this mode, because its end would have to be guessed.
///
/// Anything else returns `nil`. In particular the parser **must not** strip a prefix merely
/// because it looks like an AI:
///
/// - `"012345678905"` (a 12-digit UPC-A) → `nil`. It *starts* with `01`, but AI 01 needs 14 digits
///   and only 10 remain. A guess here would delete the first two digits of a product code.
/// - `"10012345678902"` (a 14-digit ITF-14) → `nil`. AI 10 is variable-length, and without a
///   separator its end is unknowable.
/// - `"00123456789012345675"` → `[00: "123456789012345675"]`. Twenty characters, consumed exactly
///   by one fixed-length AI.
/// - `"0109521234543213\u{001D}10LOT42\u{001D}240PN-4471"` → three elements. Separators present, so
///   the variable-length AI 10 and AI 240 fields are delimited rather than guessed.
enum GS1Parser {

    /// AIs whose value length is fixed by the standard. The `Int` is the length of the **value**,
    /// not counting the AI digits themselves.
    ///
    /// `00` SSCC (18), `01`/`02` GTIN (14), `11`–`17` dates (6), `20` variant (2),
    /// `310n`/`320n` net weight (6), `410`–`417` GLNs (13), `8017`/`8018` GSRN (18).
    static let fixedLengthAIs: [String: Int] = [
        "00": 18,
        "01": 14,
        "02": 14,
        "11": 6,
        "12": 6,
        "13": 6,
        "15": 6,
        "16": 6,
        "17": 6,
        "20": 2,
        "310": 6, "3100": 6, "3101": 6, "3102": 6, "3103": 6, "3104": 6, "3105": 6,
        "3200": 6, "3201": 6, "3202": 6, "3203": 6, "3204": 6, "3205": 6,
        "410": 13,
        "411": 13,
        "412": 13,
        "413": 13,
        "414": 13,
        "415": 13,
        "416": 13,
        "417": 13,
        "8017": 18,
        "8018": 18
    ]

    /// AIs whose value runs until the next separator. The `Int` is the standard's maximum length,
    /// used only as a sanity check — a longer run means the payload was not what it claimed.
    ///
    /// `240`/`241` are "additional product identification" and "customer part number": on an
    /// automotive label those *are* the manufacturer part number, which is why they are the only
    /// AIs allowed to produce a part-number candidate.
    static let variableLengthAIs: [String: Int] = [
        "10": 20,
        "21": 20,
        "22": 20,
        "30": 8,
        "37": 8,
        "240": 30,
        "241": 30,
        "242": 6,
        "243": 20,
        "250": 30,
        "251": 30,
        "253": 30,
        "254": 20,
        "400": 30,
        "401": 30,
        "402": 17,
        "403": 30,
        "8004": 30,
        "8020": 25,
        "8200": 70,
        "90": 30,
        "91": 90,
        "92": 90,
        "93": 90,
        "94": 90,
        "95": 90,
        "96": 90,
        "97": 90,
        "98": 90,
        "99": 90
    ]

    /// The characters a scanner emits in place of FNC1: GS, RS, US. These *separate fields*.
    private static let separatorCharacters: Set<Character> = ["\u{001D}", "\u{001E}", "\u{001F}"]

    /// Characters a keyboard-wedge scanner appends to *end a transmission* — EOT, ETX, NUL — plus
    /// whitespace. They are trimmed before parsing and never treated as field separators: a
    /// trailing EOT on a plain Code 128 label must not make the payload look like GS1.
    private static let transmissionTerminators: CharacterSet =
        CharacterSet(charactersIn: "\u{0000}\u{0003}\u{0004}").union(.whitespacesAndNewlines)

    /// AIM symbology identifiers that mean "the payload that follows is a GS1 element string".
    private static let gs1SymbologyIdentifiers = ["]C1", "]e0", "]d2", "]Q3", "]J1"]

    /// AI lengths to try, longest first, so `3100` is preferred over `310` and `410` over `41`.
    private static let applicationIdentifierLengths = [4, 3, 2]

    /// Parses a payload into elements, or returns `nil` rather than guessing.
    ///
    /// See the type-level documentation for what counts as unambiguous, with worked examples.
    static func parse(_ payload: String) -> [GS1Element]? {
        var working = payload.trimmingCharacters(in: transmissionTerminators)
        guard !working.isEmpty else { return nil }

        var sawSymbologyIdentifier = false
        for identifier in gs1SymbologyIdentifiers where working.hasPrefix(identifier) {
            working = String(working.dropFirst(identifier.count))
            sawSymbologyIdentifier = true
            break
        }

        let characters = Array(working)
        guard !characters.isEmpty else { return nil }

        // Explicit separators — or an AIM identifier that promises them — are what license
        // variable-length fields. Without either, only fixed-length AIs may be read.
        let hasExplicitSeparators = sawSymbologyIdentifier
            || characters.contains(where: { separatorCharacters.contains($0) })

        var elements: [GS1Element] = []
        var index = 0

        while index < characters.count {
            if separatorCharacters.contains(characters[index]) {
                index += 1
                continue
            }

            guard let identifier = readApplicationIdentifier(characters, from: index) else { return nil }
            index += identifier.count

            if let length = fixedLengthAIs[identifier] {
                // A fixed-length field that runs past the end of the payload means the leading
                // digits only *looked* like an AI. That is the UPC case, and it must not parse.
                guard index + length <= characters.count else { return nil }
                let value = String(characters[index..<(index + length)])
                guard value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                elements.append(GS1Element(applicationIdentifier: identifier, value: value))
                index += length
                continue
            }

            guard let maximum = variableLengthAIs[identifier] else { return nil }
            guard hasExplicitSeparators else { return nil }

            var end = index
            while end < characters.count, !separatorCharacters.contains(characters[end]) {
                end += 1
            }
            let value = String(characters[index..<end])
            guard !value.isEmpty, value.count <= maximum else { return nil }
            elements.append(GS1Element(applicationIdentifier: identifier, value: value))
            index = end
        }

        // The loop only ends when the payload is exhausted, and every branch that could not
        // consume its field returned `nil`, so reaching here means the payload parsed exactly.
        guard !elements.isEmpty else { return nil }
        return elements
    }

    /// Reads the AI starting at `index`, longest known match first, or `nil` when no known AI
    /// starts there. AIs are always digits.
    private static func readApplicationIdentifier(_ characters: [Character], from index: Int) -> String? {
        for length in applicationIdentifierLengths {
            guard index + length <= characters.count else { continue }
            let candidate = String(characters[index..<(index + length)])
            guard candidate.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            if fixedLengthAIs[candidate] != nil || variableLengthAIs[candidate] != nil {
                return candidate
            }
        }
        return nil
    }
}

/// Turns one scanned symbol into ranked candidates.
enum BarcodePayloadClassifier {

    /// AIs that carry a manufacturer / customer part number.
    private static let partNumberApplicationIdentifiers: Set<String> = ["240", "241"]

    /// The payload itself is a machine-verified read (linear symbologies carry a check digit), so
    /// the `.barcode` candidate is high confidence. It fills no intake field on its own, so a high
    /// band here cannot pre-fill anything: `ScanCandidateKind.barcode.coreItemField` is `nil`.
    private static let barcodeConfidence = 0.95

    /// A GS1 AI 240/241 value is *labelled* as a part number by the standard, which is the
    /// strongest evidence available — but it stays inside the `.medium` band on purpose so it can
    /// never start ticked in the review sheet.
    private static let gs1PartNumberConfidence = 0.78

    /// A Code 39 / Code 128 payload that mixes digits with letters or separators looks like a
    /// catalogue number. Still `.medium`: the label might equally be a bin code or a serial.
    private static let alphanumericPartNumberConfidence = 0.70

    /// An all-digit Code 39 / Code 128 payload. It may be a part number, but it may just as easily
    /// be a product code printed in an alphanumeric symbology, so it scores lower.
    private static let numericAlphanumericPartNumberConfidence = 0.55

    /// Candidates for one scanned symbol, highest confidence first.
    ///
    /// Always emits a `.barcode` candidate carrying the raw payload. Emits an additional
    /// `.partNumber` candidate **only** when the symbology class is `.linearAlphanumeric`, or when
    /// GS1 parsing unambiguously yields AI 240/241. A numeric UPC/EAN/ITF payload never produces
    /// one — its `reason` says so in as many words.
    static func candidates(for input: BarcodeScanInput) -> [ScanCandidate] {
        let symbologyClass = BarcodeSymbologyClass.classify(input.symbology)
        let normalizedPayload = ScanTextNormalizer.stripControlCharacters(input.payload)

        var results: [ScanCandidate] = []

        results.append(ScanCandidate(
            kind: .barcode,
            rawValue: input.payload,
            normalizedValue: normalizedPayload,
            confidence: barcodeConfidence,
            source: input.source,
            reason: barcodeReason(for: symbologyClass, symbology: input.symbology),
            barcodeSymbology: input.symbology
        ))

        // GS1 parsing runs against the *raw* payload: stripping control characters first would
        // delete the very separators that make the structure unambiguous.
        if let elements = GS1Parser.parse(input.payload) {
            for element in elements {
                guard partNumberApplicationIdentifiers.contains(element.applicationIdentifier) else {
                    continue
                }
                let identifier = ScanTextNormalizer.normalizedIdentifier(element.value)
                guard !identifier.isEmpty else { continue }
                let reason = "GS1 field \(element.applicationIdentifier) carries the manufacturer part number"
                results.append(ScanCandidate(
                    kind: .partNumber,
                    rawValue: element.value,
                    normalizedValue: identifier,
                    confidence: gs1PartNumberConfidence,
                    source: input.source,
                    reason: reason,
                    barcodeSymbology: input.symbology,
                    alternatives: ScanTextNormalizer.confusionAlternatives(for: identifier)
                ))
            }
        } else if symbologyClass == .linearAlphanumeric {
            let identifier = ScanTextNormalizer.normalizedIdentifier(input.payload)
            if !identifier.isEmpty {
                let allDigits = ScanTextNormalizer.isAllDigits(identifier)
                var confidence = alphanumericPartNumberConfidence
                var reason = "Alphanumeric barcode, the kind a parts label uses for the manufacturer part number"
                if allDigits {
                    confidence = numericAlphanumericPartNumberConfidence
                    reason = "Alphanumeric barcode carrying only digits — it may be a part number or a product code"
                }
                results.append(ScanCandidate(
                    kind: .partNumber,
                    rawValue: input.payload,
                    normalizedValue: identifier,
                    confidence: confidence,
                    source: input.source,
                    reason: reason,
                    barcodeSymbology: input.symbology,
                    alternatives: ScanTextNormalizer.confusionAlternatives(for: identifier)
                ))
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.normalizedValue < rhs.normalizedValue
        }
    }

    /// The sentence shown under the barcode row. It names the symbology class, and for a numeric
    /// symbology it states plainly that the number is a product code.
    private static func barcodeReason(for symbologyClass: BarcodeSymbologyClass,
                                      symbology: String) -> String {
        switch symbologyClass {
        case .linearNumeric:
            return "Read from a numeric product code (UPC/EAN/ITF). That identifies the product, not the manufacturer part number."
        case .linearAlphanumeric:
            return "Read from an alphanumeric barcode (Code 39/Code 128)."
        case .twoDimensional:
            return "Read from a 2-D code (QR/DataMatrix/PDF417/Aztec)."
        case .unknown:
            return symbology.isEmpty
                ? "Read from an unrecognised symbology."
                : "Read from an unrecognised symbology (\(symbology))."
        }
    }
}
