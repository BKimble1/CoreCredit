//
//  LaunchSplashView.swift
//  CoreCredit
//
//  The load-in screen: the app's own mark on the brand blue, and a clean way off it.
//
//  ## Two layers, deliberately
//
//  iOS paints a **static** launch screen the instant the process starts, long before SwiftUI
//  exists. That is the layer that removes the white flash, and it is configured in
//  `Config/CoreCredit-Info.plist` under `UILaunchScreen`: `LaunchBackground` (the flat brand blue)
//  behind `LaunchMark` (the white mark, on a transparent square canvas). A static launch screen
//  cannot draw a gradient — it takes a colour and an image and nothing else.
//
//  This view is the **second** layer. It draws the same mark at the same proportion over a gradient
//  built around the same blue, so the handover from the static screen is a change of shading rather
//  than a change of picture, and then it fades away to reveal the app.
//
//  Both layers size the mark to 34% of the screen's short side, from one asset, so nothing has to
//  be kept in step by eye.
//
//  ## It never delays anything
//
//  The splash is an `.overlay`, not a layer in a `ZStack`: the app is built, laid out, and running
//  underneath it the whole time, and removing the overlay changes no other view's geometry. A deep
//  link that arrived at launch is consumed by `MainTabView` on appear, underneath, exactly as it
//  would have been — and the splash gets out of the way the moment one lands, because somebody who
//  tapped the Quick Scan widget wants a viewfinder rather than a logo. Nothing waits for this.
//

import SwiftUI

// MARK: - Colours

/// The load-in screen's palette, and the names of the two assets the static launch screen uses.
///
/// Deliberately **not** part of `Palette`. Everything in `Palette` adapts to light and dark and
/// carries a meaning inside the ledger — amber is "act now", green is "the money arrived". These
/// are the brand's own colours, taken from the app icon, and they are the same in both appearances
/// because a launch screen is the app introducing itself rather than a surface being read.
///
/// `middle` is the exact colour the `LaunchBackground` asset paints, which is what makes the
/// handover from the static launch screen invisible. `LaunchScreenTests` holds those two to each
/// other so the claim cannot quietly stop being true.
enum LaunchPalette {

    /// Asset catalog name of the flat colour the static launch screen paints.
    static let backgroundAssetName = "LaunchBackground"

    /// Asset catalog name of the white mark, on a transparent square canvas.
    static let markAssetName = "LaunchMark"

    /// Lifted a little, so the top of the screen reads as lit.
    static let top = Color(red: 0x1E / 255, green: 0x6B / 255, blue: 0xFF / 255)

    /// The icon's own blue, `#0053FD` — and the colour of the whole static launch screen.
    static let middle = Color(red: 0x00 / 255, green: 0x53 / 255, blue: 0xFD / 255)

    /// Deepened, so the screen has a floor.
    static let bottom = Color(red: 0x01 / 255, green: 0x3C / 255, blue: 0xC9 / 255)
}

// MARK: - The splash

/// The app's mark, centred on the brand gradient.
struct LaunchSplashView: View {

    /// A fade is the accessible substitute for motion, so the scale-in is what gets dropped —
    /// never the cross-fade, which is what makes the transition legible at all.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasAppeared = false

    init() { }

    /// The mark's longest side, as a fraction of the screen's short side.
    ///
    /// **Must stay equal to the fraction baked into `LaunchMark.imageset`.** The asset is a square
    /// canvas with the mark occupying this much of it, so drawing that canvas at the short side
    /// puts the mark at exactly the size the static launch screen puts it.
    static let markFraction: CGFloat = 0.34

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            Image(LaunchPalette.markAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(markScale)
                .opacity(hasAppeared ? 1 : 0.85)
        }
        .background {
            LaunchSplashView.gradient.ignoresSafeArea()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppConfiguration.displayName))
        .accessibilityAddTraits(.isImage)
        .onAppear {
            guard reduceMotion == false else {
                hasAppeared = true
                return
            }
            withAnimation(.easeOut(duration: LaunchSplash.settleDuration)) {
                hasAppeared = true
            }
        }
    }

    /// A restrained settle, from very slightly small to true size. Nothing bounces, nothing spins:
    /// this screen is in front of a technician for well under a second and its only job is to not
    /// be a white flash.
    private var markScale: CGFloat {
        if reduceMotion { return 1 }
        return hasAppeared ? 1 : 0.96
    }

    /// Centred on `LaunchBackground` — the exact blue the static launch screen paints flat — so the
    /// midpoint of this gradient and the whole of that screen are the same colour. The handover
    /// reads as the light coming up, not as one picture replacing another.
    static let gradient = LinearGradient(
        stops: [
            Gradient.Stop(color: LaunchPalette.top, location: 0),
            Gradient.Stop(color: LaunchPalette.middle, location: 0.5),
            Gradient.Stop(color: LaunchPalette.bottom, location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Timing

/// The load-in's timings, in one place so the host and the view cannot drift.
enum LaunchSplash {

    /// How long the mark takes to settle to full size.
    static let settleDuration: TimeInterval = 0.28

    /// How long the splash stays up before it starts leaving.
    ///
    /// Short on purpose. This is a launch screen, not an animation anyone asked to watch: the mark
    /// settles, it holds for a beat so the eye registers it, and it goes.
    static let dwellDuration: TimeInterval = 0.34

    /// How long the fade out takes.
    static let fadeDuration: TimeInterval = 0.3
}

// MARK: - Host

/// Puts the load-in screen over `content` and takes it away again.
///
/// # Why an overlay rather than a `ZStack`
///
/// A `ZStack` sizes itself to its largest child, so a full-screen splash that ignores the safe area
/// would grow the stack and re-lay-out the app underneath it — and the app would visibly settle as
/// the splash left. `.overlay` never affects the geometry of what it covers, so the first frame the
/// user sees after the fade is the same frame that was already there.
///
/// # A deep link cancels it outright
///
/// Somebody who tapped the Quick Scan widget wants a viewfinder, not a logo. `isEnabled` is read
/// live rather than captured once, because a real cold-start URL arrives through `onOpenURL`
/// *after* the scene exists — so the moment a link lands, the splash goes, before the scanner sheet
/// rises over it. The flag is latched once it turns off, or the splash would come back the instant
/// `MainTabView` consumed the link and `pending` returned to `nil`.
///
/// # It is skipped under `-uiTesting`
///
/// A UI test's first act is to query for a control, and a splash sitting over the app for a third
/// of a second is a race nobody needs in a suite that is meant to be deterministic. The same
/// launch flag that disables animations skips this, which is the rule the rest of the app already
/// follows. The consequence is recorded honestly: **no UI test exercises the splash.**
struct LaunchSplashHost<Content: View>: View {

    private let isEnabled: Bool
    private let content: Content

    /// Latched. Once the splash is done — by timing out, or by a deep link arriving — it is done
    /// for the life of the process.
    @State private var isFinished = false

    /// - Parameters:
    ///   - isEnabled: `false` renders `content` alone, with no splash and no delay. Read on every
    ///     update, so turning it off mid-splash takes the splash away immediately.
    ///   - content: The app.
    init(isEnabled: Bool, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.content = content()
    }

    var body: some View {
        content
            .overlay {
                if isEnabled && isFinished == false {
                    LaunchSplashView()
                        .transition(.opacity)
                }
            }
            .task {
                guard isEnabled, isFinished == false else {
                    isFinished = true
                    return
                }

                let dwell = LaunchSplash.settleDuration + LaunchSplash.dwellDuration
                // `Task.sleep` throws only on cancellation, which happens when the view goes away
                // — and a splash whose host has gone away has nothing left to dismiss. Swallowing
                // it here is the whole handling.
                try? await Task.sleep(for: .seconds(dwell))
                guard Task.isCancelled == false else { return }

                withAnimation(.easeInOut(duration: LaunchSplash.fadeDuration)) {
                    isFinished = true
                }
            }
            .onChange(of: isEnabled) { _, stillEnabled in
                // A link landed. No fade: the scanner is already on its way up, and animating a
                // logo out from underneath it would be two things moving for no reason.
                if stillEnabled == false {
                    isFinished = true
                }
            }
    }
}

#Preview("Load-in screen") {
    LaunchSplashView()
}

#Preview("Load-in over the app") {
    LaunchSplashHost(isEnabled: true) {
        VStack {
            Text("The app, already laid out underneath.")
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
