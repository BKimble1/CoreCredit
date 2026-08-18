//
//  ScanCoreIntent.swift
//  CoreCredit
//
//  "Scan a Core" as a system-level action: Shortcuts, Siri, and the Action Button.
//

import AppIntents
import Foundation

/// Brings CoreCredit forward on a new core charge with the scanner already open.
///
/// # Why it opens the app instead of doing the work
///
/// The whole point of this intent is a viewfinder. A camera, a live preview, a review step, and an
/// editable form are not things an intent can run in the background, so `openAppWhenRun` is `true`
/// and `perform()` does the only thing worth doing out of process: it says where the app should
/// land. `DeepLinkRouterRegistry` holds that request if the app is still launching, which is the
/// normal case for the Action Button on a cold device.
///
/// # It lands on the same surface as everything else
///
/// `DeepLink.scan` is the one route every external entry point uses — this intent, the Quick Scan
/// widget, and a `corecredit://scan` URL alike — and `MainTabView` answers all of them with the
/// create editor and the unified **Scan core** sheet in front of it. There is no separate
/// Shortcut-only scanner to keep in step.
///
/// # It writes nothing
///
/// Running this intent creates no record. It opens the ordinary unsaved draft — the same one the
/// Dashboard's "Scan core" button opens — and the free-tier limit is still checked by
/// `CoreEditorModel.save(using:vendor:bin:tier:)` before anything reaches the store.
struct ScanCoreIntent: AppIntent {

    /// "Scan core" — the same words the widget, the Dashboard action, the intake form's action,
    /// and the capture sheet's own navigation title use. One name for one thing.
    static var title: LocalizedStringResource { "Scan core" }

    /// Written as one string literal, not a concatenation: `LocalizedStringResource` is built from
    /// a *literal*, and `"a" + "b"` is a `String`, which will not convert to one.
    static var description: IntentDescription {
        IntentDescription(
            "Opens a new core charge on the Scan core screen. Nothing is saved until you tap Save.",
            categoryName: "Cores"
        )
    }

    /// The app has to be in front: this action is a camera and a form.
    static var openAppWhenRun: Bool { true }

    init() { }

    /// Records the request and returns. Every decision about tabs, sheets, and the editor stays in
    /// the app shell, which is the only place that knows whether a draft is already open.
    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouterRegistry.deliver(.scan)
        return .result()
    }
}

/// The shortcuts CoreCredit offers without the owner having to build one.
///
/// The phrases all name the app through `\(.applicationName)`, which is required: Siri matches a
/// spoken phrase against the app it belongs to, and a phrase without the app name is rejected at
/// build time rather than quietly ignored.
struct CoreCreditShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanCoreIntent(),
            phrases: [
                "Scan core in \(.applicationName)",
                "Scan a core with \(.applicationName)",
                "Log a core in \(.applicationName)"
            ],
            shortTitle: "Scan core",
            systemImageName: "barcode.viewfinder"
        )
    }
}
