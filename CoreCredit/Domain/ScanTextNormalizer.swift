//
//  ScanTextNormalizer.swift
//  CoreCredit
//
//  Pure domain layer. Foundation only.
//
//  ## Why this file exists
//
//  Hardware scanners and Vision both hand back strings that are *nearly* right. A keyboard-wedge
//  scanner reading a GS1-128 label emits `<GS>` (U+001D) between fields and sometimes an `EOT`
//  (U+0004) at the end; those characters are invisible, so the symptom on the shop floor is a part
//  number that "looks fine" but never matches anything. OCR contributes a different failure: `O`
//  for `0`, `I` for `1`, `S` for `5`.
//
//  This file deals with both — and deals with them **separately**:
//
//  - Control characters are *removed*, because they are never part of a part number.
//  - Character confusions are *offered as alternatives*, never applied. Silently turning `SO5` into
//    `505` would be the app inventing a part number, which is precisely the thing that must never
//    happen without a human tap.
//
//  Everything here preserves leading zeros, hyphens, slashes and letters. An identifier is a
//  string. It is never parsed as a number, and no transformation in this file can make `007`
//  become `7`.
//

import Foundation

enum ScanTextNormalizer {

    // MARK: - Control characters

    /// NUL, the start of the C0 range.
    private static let c0RangeStart: Unicode.Scalar = "\u{0000}"

    /// US (unit separator) — the last C0 control. The GS1 separators scanners emit live inside
    /// this range: GS `U+001D`, RS `U+001E`, US `U+001F`, and EOT `U+0004`.
    private static let c0RangeEnd: Unicode.Scalar = "\u{001F}"

    /// DEL.
    private static let deleteScalar: Unicode.Scalar = "\u{007F}"

    /// Start of the C1 range.
    private static let c1RangeStart: Unicode.Scalar = "\u{0080}"

    /// End of the C1 range.
    private static let c1RangeEnd: Unicode.Scalar = "\u{009F}"

    /// Every C0 and C1 control character, DEL included.
    ///
    /// Built explicitly rather than reusing `CharacterSet.controlCharacters`, which also contains
    /// the Unicode *format* characters (soft hyphen, bidi marks, joiners). Those are a different
    /// problem with a different answer, and quietly deleting them here would be a surprise.
    ///
    /// Note what is **not** in this set: space, hyphen, slash, period and every digit and letter.
    /// A part number keeps its shape.
    static let scannerControlCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: ScanTextNormalizer.c0RangeStart...ScanTextNormalizer.c0RangeEnd)
        set.insert(charactersIn: ScanTextNormalizer.deleteScalar...ScanTextNormalizer.deleteScalar)
        set.insert(charactersIn: ScanTextNormalizer.c1RangeStart...ScanTextNormalizer.c1RangeEnd)
        return set
    }()

    /// Removes control characters, then trims whitespace from both ends.
    ///
    /// Inner spaces, hyphens, slashes, letters and leading zeros are preserved exactly. Newlines
    /// and tabs are C0 controls, so they are removed by the same pass rather than being collapsed
    /// into spaces — a line break inside a scanned payload is scanner noise, not formatting.
    ///
    /// `stripControlCharacters("03\u{001D}-1887\u{0004}")` == `"03-1887"`.
    static func stripControlCharacters(_ value: String) -> String {
        let pieces = value.components(separatedBy: scannerControlCharacters)
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Identifiers

    /// Uppercases, collapses every run of whitespace to a single space, and trims.
    ///
    /// **Does not** remove leading zeros, hyphens or slashes: `"  03-1887 "` becomes `"03-1887"`,
    /// `"a/12"` becomes `"A/12"`, and `"007"` stays `"007"`. Uppercasing is done with
    /// `String.uppercased()`, which is locale-independent, so a device set to Turkish cannot turn
    /// `i` into `İ` inside a part number.
    static func normalizedIdentifier(_ value: String) -> String {
        let stripped = stripControlCharacters(value)
        var collapsed = ""
        var hasContent = false
        var pendingSpace = false

        for character in stripped {
            if character.isWhitespace {
                if hasContent { pendingSpace = true }
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.append(character)
            hasContent = true
        }

        return collapsed.uppercased()
    }

    /// The character-confusion pairs OCR actually gets wrong on parts labels.
    ///
    /// Each entry is a *single* substitution, applied one at a time, so `"S05"` offers `"505"` and
    /// `"SO5"` but never a double swap. Lowercase letters map onto their digit so a lowercase read
    /// still produces useful alternatives.
    private static func confusionSubstitution(for character: Character) -> Character? {
        switch character {
        case "O": return "0"
        case "0": return "O"
        case "I": return "1"
        case "1": return "I"
        case "S": return "5"
        case "5": return "S"
        case "o": return "0"
        case "i": return "1"
        case "s": return "5"
        default: return nil
        }
    }

    /// Single-substitution `O`/`0`, `I`/`1`, `S`/`5` variants of `value`.
    ///
    /// Deterministic by construction: the string is scanned left to right and one variant is
    /// emitted per substitutable position, in that order. The input itself is never returned, and
    /// duplicates (which a repeated character pattern can produce) are dropped. At most `limit`
    /// variants come back.
    ///
    /// `confusionAlternatives(for: "O3-1S87")` == `["03-1S87", "O3-IS87", "O3-1587"]` — one variant
    /// per substitutable position, in left-to-right order.
    ///
    /// These are **offered**, never applied. The review sheet shows them as chips the user can tap.
    static func confusionAlternatives(for value: String, limit: Int = 4) -> [String] {
        guard limit > 0, !value.isEmpty else { return [] }

        var characters = Array(value)
        var results: [String] = []
        var seen: Set<String> = [value]

        for index in characters.indices {
            let original = characters[index]
            guard let replacement = confusionSubstitution(for: original) else { continue }

            characters[index] = replacement
            let variant = String(characters)
            characters[index] = original

            guard seen.insert(variant).inserted else { continue }
            results.append(variant)
            if results.count >= limit { break }
        }

        return results
    }

    // MARK: - Shape tests

    /// `true` when every character is an ASCII digit and the string is not empty.
    ///
    /// ASCII on purpose: `Character.isNumber` is also true for `½` and for Eastern Arabic digits,
    /// neither of which is a barcode payload.
    static func isAllDigits(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Separators that appear inside real parts-catalogue numbers.
    private static let identifierSeparators: Set<Character> = ["-", "/", ".", "_"]

    /// `true` when the value contains at least one digit **and** at least one letter or separator.
    ///
    /// That combination is what distinguishes a catalogue number (`03-1887`, `A1234B`, `12/450`)
    /// from a quantity, a price, or a bare product code. A string of digits alone is not an
    /// identifier as far as this app is concerned — on an invoice it is far more often a quantity
    /// or a UPC.
    static func looksLikeIdentifier(_ value: String) -> Bool {
        let cleaned = stripControlCharacters(value)
        guard !cleaned.isEmpty else { return false }
        guard cleaned.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        return cleaned.contains(where: { $0.isLetter || identifierSeparators.contains($0) })
    }
}
