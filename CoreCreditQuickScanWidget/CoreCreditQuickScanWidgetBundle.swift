//
//  CoreCreditQuickScanWidgetBundle.swift
//  CoreCreditQuickScanWidget
//
//  Entry point for the widget extension. One widget today; add further widgets to `body`.
//

import SwiftUI
import WidgetKit

@main
struct CoreCreditQuickScanWidgetBundle: WidgetBundle {

    var body: some Widget {
        QuickScanWidget()
    }
}
