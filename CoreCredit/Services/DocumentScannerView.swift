//
//  DocumentScannerView.swift
//  CoreCredit
//
//  Capture layer — the system document camera, wrapped so SwiftUI can present it.
//
//  ## Why this exists next to the photo picker
//
//  An invoice is not a snapshot. It is a rectangle of small print, photographed at an angle, in a
//  parts room lit by one fluorescent tube. `UIImagePickerController` hands back exactly what the
//  lens saw — keystoned, with the bench and the coffee cup around the edges — and Vision then has
//  to read 8-point type off a trapezoid.
//
//  `VNDocumentCameraViewController` is the same camera every scanning app on iOS uses: it finds the
//  page edges live, corrects the perspective, crops to the paper, and lets the technician keep
//  shooting to add page two and page three. What comes back is a flat, deskewed page per shot —
//  which is the difference between reading a core charge and guessing at one.
//
//  ## What this file does and does not do
//
//  It converts each captured page to JPEG bytes and hands the array back. That is all. It stores
//  nothing, uploads nothing, and never writes to a record: the pages go to
//  `TextRecognizing.recognizePages(_:)`, the recognised lines become ranked candidates, and a person
//  taps to accept them.
//
//  The camera permission is requested by the system when this controller is presented — that is,
//  only when the user deliberately opens the document scanner. Nothing here asks for anything at
//  launch, and nothing here touches the photo library.
//

import Foundation
import SwiftUI
import UIKit
import VisionKit

/// Multi-page document capture with edge detection and perspective correction.
///
/// Present it only when `DocumentScannerView.isSupported` is `true`; on hardware that cannot run the
/// document camera — and in the simulator — the caller must fall back to the photo picker or to
/// typing the details in.
@MainActor
struct DocumentScannerView: UIViewControllerRepresentable {

    /// Called on the main actor with one JPEG per captured page, in capture order. Never called
    /// with an empty array — a scan that produced no readable page is reported through `onError`.
    private let onScan: ([Data]) -> Void

    /// Called on the main actor when the user backs out. Nothing was captured; the draft is
    /// untouched.
    private let onCancel: () -> Void

    /// Called on the main actor with a user-facing sentence when the camera itself failed.
    private let onError: (String) -> Void

    init(onScan: @escaping ([Data]) -> Void,
         onCancel: @escaping () -> Void,
         onError: @escaping (String) -> Void) {
        self.onScan = onScan
        self.onCancel = onCancel
        self.onError = onError
    }

    /// Whether this device can run the document camera at all.
    ///
    /// Read at the point of use rather than cached: it is `false` in the simulator and on older
    /// hardware, and the caller needs a truthful answer before it offers the button.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    /// JPEG quality for the pages handed to recognition.
    ///
    /// Higher than `AppConfiguration.attachmentJPEGQuality` on purpose. These bytes are read by
    /// Vision and then discarded, so the usual storage trade-off does not apply, and JPEG ringing
    /// around 8-point type is exactly what turns an `8` into a `3`. A page the user chooses to keep
    /// as evidence still goes through `ImageProcessor` and is stored at the normal quality.
    private static let pageJPEGQuality: CGFloat = 0.9

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel, onError: onError)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        // Re-capture the closures so they never point at stale SwiftUI state.
        context.coordinator.onScan = onScan
        context.coordinator.onCancel = onCancel
        context.coordinator.onError = onError
    }

    // MARK: - Coordinator

    /// Delegate bridge.
    ///
    /// The callbacks hop to the main actor through a `Task` rather than calling straight back into
    /// SwiftUI, so a finished scan is never delivered in the middle of a view update. Cancel and
    /// failure are kept distinct all the way through: backing out of the camera is an ordinary
    /// outcome and must not raise an error banner, while a camera failure is something the user has
    /// to be told about so they can fall back to typing.
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {

        var onScan: ([Data]) -> Void
        var onCancel: () -> Void
        var onError: (String) -> Void

        /// Shown when the camera finished but produced nothing usable — a scan of a blank surface,
        /// or pages the system could not encode.
        private static let emptyScanMessage =
            "Nothing was captured from that scan. Try again, or type the details in."

        /// Shown when the document camera itself reported a failure.
        private static let failureMessage =
            "The document scanner stopped. Try again, or type the details in."

        init(onScan: @escaping ([Data]) -> Void,
             onCancel: @escaping () -> Void,
             onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let pages = Coordinator.pageData(from: scan)
                if pages.isEmpty {
                    self.onError(Coordinator.emptyScanMessage)
                } else {
                    self.onScan(pages)
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            Task { @MainActor [weak self] in
                self?.onCancel()
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: any Error) {
            let detail = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.onError(detail.isEmpty ? Coordinator.failureMessage
                                            : Coordinator.failureMessage + " (" + detail + ")")
            }
        }

        // MARK: Private

        /// Encodes every page of a finished scan, in capture order.
        ///
        /// `pageCount` bounds the loop, so no index handed to `imageOfPage(at:)` can ever be out of
        /// range. A page the system refuses to encode is skipped rather than fatal — losing page
        /// three is annoying, losing the invoice is not acceptable.
        ///
        /// Each iteration is wrapped in an autorelease pool: a five-page scan off a 48-megapixel
        /// camera is a lot of `UIImage` to keep alive at once, and without draining between pages
        /// they all pile up until the callback returns.
        @MainActor
        private static func pageData(from scan: VNDocumentCameraScan) -> [Data] {
            let count = scan.pageCount
            guard count > 0 else { return [] }

            var pages: [Data] = []
            pages.reserveCapacity(count)

            for index in 0..<count {
                autoreleasepool {
                    let image = scan.imageOfPage(at: index)
                    let quality = DocumentScannerView.pageJPEGQuality
                    if let data = image.jpegData(compressionQuality: quality), !data.isEmpty {
                        pages.append(data)
                    }
                }
            }

            return pages
        }
    }
}
