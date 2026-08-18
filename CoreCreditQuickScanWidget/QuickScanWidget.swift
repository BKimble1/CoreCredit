//
//  QuickScanWidget.swift
//  CoreCreditQuickScanWidget
//
//  A static launcher. The widget reads no app data — no SwiftData store, no app group, no
//  network — it only deep-links into CoreCredit so a tech can start a core without hunting
//  for the app icon first.
//

import SwiftUI
import WidgetKit

// MARK: - Copy

/// Every user-facing string in the widget, in one place.
private enum QuickScanCopy {

    /// Matches the app's icon language: the `barcode.viewfinder` mark.
    static let symbolName = "barcode.viewfinder"

    /// "Scan core", the same words the App Shortcut, the Dashboard action, the intake form's own
    /// action, and the capture sheet's own title use. One name for one thing.
    static let title: LocalizedStringKey = "Scan core"
    static let hint: LocalizedStringKey = "Opens CoreCredit's Scan core screen to start a new core."
    static let configurationName: LocalizedStringKey = "Scan core"
    static let configurationDescription: LocalizedStringKey =
        "Opens CoreCredit's Scan core screen so you can start a new core in one tap."
}

// MARK: - Timeline entry

/// The widget renders fixed copy, so the entry carries nothing beyond the date `TimelineEntry`
/// requires.
struct QuickScanEntry: TimelineEntry {
    let date: Date
}

// MARK: - Provider

/// Produces one entry and never asks to be reloaded.
///
/// There is no data behind this widget — it is a launcher — so a reload could not change what is
/// on screen. `.never` keeps it off the system's refresh budget entirely, leaving that budget for
/// widgets that actually have something to say.
struct QuickScanProvider: TimelineProvider {

    func placeholder(in context: Context) -> QuickScanEntry {
        QuickScanEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickScanEntry) -> Void) {
        completion(QuickScanEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickScanEntry>) -> Void) {
        let timeline = Timeline(entries: [QuickScanEntry(date: Date())], policy: .never)
        completion(timeline)
    }
}

// MARK: - Views

/// Chooses a layout per family. Every declared family has its own branch; `default` repeats the
/// small layout so an undeclared family added later still renders something sensible rather than
/// an empty rectangle.
struct QuickScanEntryView: View {

    @Environment(\.widgetFamily) private var family

    let entry: QuickScanEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
        case .accessoryCircular:
            circularBody
        case .accessoryRectangular:
            rectangularBody
        case .accessoryInline:
            inlineBody
        default:
            smallBody
        }
    }

    // MARK: Home Screen

    /// Symbol over label, high contrast, no gradients. The whole widget is the tap target because
    /// `widgetURL` is applied to this view by the configuration.
    private var smallBody: some View {
        VStack(spacing: 8) {
            Image(systemName: QuickScanCopy.symbolName)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.blue)

            Text(QuickScanCopy.title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QuickScanCopy.title))
        .accessibilityHint(Text(QuickScanCopy.hint))
    }

    // MARK: Lock Screen accessories

    /// The system renders accessory families monochrome, so the symbol carries no colour of its
    /// own. `AccessoryWidgetBackground` is the standard translucent disc behind a circular
    /// complication; it is only valid inside accessory families, which is why it appears here and
    /// not in `smallBody`.
    private var circularBody: some View {
        ZStack {
            AccessoryWidgetBackground()

            Image(systemName: QuickScanCopy.symbolName)
                .font(.title2)
        }
        .containerBackground(Color.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QuickScanCopy.title))
        .accessibilityHint(Text(QuickScanCopy.hint))
    }

    private var rectangularBody: some View {
        HStack(spacing: 6) {
            Image(systemName: QuickScanCopy.symbolName)
                .font(.headline)

            Text(QuickScanCopy.title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(Color.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QuickScanCopy.title))
        .accessibilityHint(Text(QuickScanCopy.hint))
    }

    /// Inline accessories render as a single line of text with one symbol, styled by the system.
    /// Fonts, colours, and layout modifiers are ignored there, so none are applied.
    private var inlineBody: some View {
        Label(QuickScanCopy.title, systemImage: QuickScanCopy.symbolName)
            .containerBackground(Color.clear, for: .widget)
    }
}

// MARK: - Widget

struct QuickScanWidget: Widget {

    /// Stable across releases: changing it would orphan every widget a shop has already placed.
    static let kind = "CoreCreditQuickScan"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickScanProvider()) { entry in
            QuickScanEntryView(entry: entry)
                .widgetURL(QuickScanLinks.scanURL)
        }
        .configurationDisplayName(QuickScanCopy.configurationName)
        .description(QuickScanCopy.configurationDescription)
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
