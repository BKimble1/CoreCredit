//
//  PhotoAssistScenario.swift
//  CoreCredit
//
//  Scripted photo-assist fixtures for UI tests. Inert in a shipping build: nothing here is
//  constructed unless `LaunchOptions.isUITesting` is set, which only a launch argument can do.
//
//  ## Why this exists at all
//
//  The fusion rules are pure and are tested directly, with no fixtures and no screens, in
//  `PhotoAssistFusionTests`. What those tests cannot reach is the *screens*: the progress state,
//  the conflict presentation, the apology when nothing was identified, and the path from a
//  suggestion to the form. Reaching those in a UI test would otherwise need a camera, a photo
//  library with known contents, and on one branch a LiDAR scanner — none of which exist on a
//  simulator running in CI.
//
//  So a scenario scripts what the recognisers *say they saw*, and everything downstream of that —
//  the fusion, the capping, the conflict detection, the review sheet — is the real implementation
//  doing its real job. The seam is deliberately as early as possible: only the pixels are fake.
//

import Foundation

/// A scripted set of photographs, chosen to reach one screen state each.
enum PhotoAssistScenario: String, CaseIterable, Sendable {

    /// Two photographs that agree: a label with a part number and barcode, and an invoice with a
    /// core charge. The ordinary happy path.
    case success

    /// Two labels bearing *different* part numbers. Both must survive, neither may start ticked.
    case conflict

    /// A photograph of a bare casting with no legible text and a weak visual guess. The apology.
    case noMatch

    /// The success fixtures on a device that reports scene depth.
    case depth

    init?(named raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        case "success": self = .success
        case "conflict": self = .conflict
        case "nomatch", "no-match", "none": self = .noMatch
        case "depth", "lidar": self = .depth
        default: return nil
        }
    }

    /// Whether this scenario's device claims a depth sensor.
    var reportsSceneDepth: Bool { self == .depth }

    /// How many photographs the sample-photo action adds.
    var photoCount: Int { scripts.count }

    /// What each scripted photograph "contains", in order.
    ///
    /// Every photograph is distinguished by a single leading byte, which is also the whole of its
    /// image data. `ScriptedPhotoRecognizer` keys off that byte; nothing else in the app cares what
    /// is in a photograph, because nothing else in the app decodes one.
    var scripts: [PhotoAssistScript] {
        switch self {
        case .success, .depth:
            return [
                PhotoAssistScript(
                    shot: .label,
                    lines: ["ALTERNATOR", "PART NO 03-1887"],
                    barcodes: [ScriptedBarcode(payload: "03-1887",
                                               symbology: "VNBarcodeSymbologyCode128")],
                    classification: ClassifiedLabel(identifier: "alternator", confidence: 0.62)
                ),
                PhotoAssistScript(
                    shot: .invoice,
                    lines: ["NAPA AUTO PARTS", "INVOICE #INV-552", "CORE CHARGE 86.50",
                            "TOTAL 341.20"],
                    barcodes: [],
                    classification: nil
                ),
            ]

        case .conflict:
            return [
                PhotoAssistScript(
                    shot: .label,
                    lines: ["PART NO 03-1887"],
                    barcodes: [],
                    classification: nil
                ),
                PhotoAssistScript(
                    shot: .label,
                    lines: ["PART NO 03-9921"],
                    barcodes: [],
                    classification: nil
                ),
            ]

        case .noMatch:
            return [
                PhotoAssistScript(
                    shot: .part,
                    lines: [],
                    barcodes: [],
                    classification: ClassifiedLabel(identifier: "metal", confidence: 0.21)
                ),
            ]
        }
    }
}

/// One scripted photograph.
struct PhotoAssistScript: Equatable, Sendable {
    var shot: PhotoAssistShot?
    var lines: [String]
    var barcodes: [ScriptedBarcode]
    var classification: ClassifiedLabel?
}

struct ScriptedBarcode: Equatable, Sendable {
    var payload: String
    var symbology: String
}

/// Stand-in image bytes. One byte per photograph, which is all the scripted recognisers need.
enum PhotoAssistFixture {

    /// The bytes for photograph `index` of a scenario.
    static func imageData(at index: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: index &+ 1)])
    }

    /// Which scripted photograph these bytes stand for, or `nil` for anything else.
    static func index(of data: Data) -> Int? {
        guard data.count == 1, let byte = data.first, byte >= 1 else { return nil }
        return Int(byte) - 1
    }
}

/// A `TextRecognizing` that answers from a script rather than from pixels.
///
/// Substituted for `StubTextRecognizer` only when a photo-assist scenario is set, so no other UI
/// test's expectations change. Anything it is handed that is not a scripted fixture falls through
/// to the ordinary stub behaviour, which keeps the rest of the capture surface working in the same
/// launch.
struct ScriptedPhotoRecognizer: TextRecognizing {

    var scenario: PhotoAssistScenario
    var fallback: StubTextRecognizer

    init(scenario: PhotoAssistScenario, fallback: StubTextRecognizer) {
        self.scenario = scenario
        self.fallback = fallback
    }

    func recognizeLines(in imageData: Data) async throws -> [RecognizedLine] {
        guard let index = PhotoAssistFixture.index(of: imageData),
              index < scenario.scripts.count else {
            return try await fallback.recognizeLines(in: imageData)
        }
        let script = scenario.scripts[index]
        guard script.lines.isEmpty == false else { return [] }
        return script.lines.map { text in
            RecognizedLine(text: text, confidence: 0.92, page: index)
        }
    }

    func recognizeBarcodes(in imageData: Data) async throws -> [ScanResult] {
        guard let index = PhotoAssistFixture.index(of: imageData),
              index < scenario.scripts.count else {
            return try await fallback.recognizeBarcodes(in: imageData)
        }
        return scenario.scripts[index].barcodes.map {
            ScanResult(payload: $0.payload, symbology: $0.symbology)
        }
    }
}

/// An `ImageClassifying` that answers from the same script.
struct ScriptedPhotoClassifier: ImageClassifying {

    var scenario: PhotoAssistScenario

    init(scenario: PhotoAssistScenario) {
        self.scenario = scenario
    }

    func classify(imageData: Data) async throws -> [ClassifiedLabel] {
        guard let index = PhotoAssistFixture.index(of: imageData),
              index < scenario.scripts.count,
              let label = scenario.scripts[index].classification else {
            return []
        }
        return [label]
    }
}
