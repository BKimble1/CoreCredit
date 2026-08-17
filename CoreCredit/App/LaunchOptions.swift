//
//  LaunchOptions.swift
//  CoreCredit
//
//  How the app is configured before a single view exists.
//

import Foundation

/// Which fixture the **in-memory** store is filled with when the app launches under test.
///
/// Seeding is only ever performed against an in-memory store (see `AppEnvironment.bootstrap()`),
/// so no scenario can touch a real shop's ledger even if the flag is passed by accident.
enum SeedScenario: String, Sendable, CaseIterable, Hashable {

    /// Seed nothing. A genuine first launch: no shop profile, so onboarding is shown.
    case none

    /// An onboarded shop with no vendors, bins, or cores — the empty-ledger states.
    case empty

    /// The demonstration ledger, which holds exactly five unresolved cores: the free tier's limit,
    /// so the very next "Add core" is the one that hits the paywall.
    case fiveUnresolved

    /// The acceptance-walkthrough fixture: NAPA, a 30-day window, one alternator core.
    case walkthrough
}

/// Everything the app needs to know about *how* it was launched.
///
/// This is the only place launch arguments are interpreted. Every screen and service reads the
/// parsed value from `AppEnvironment`, so nothing else in the app inspects `ProcessInfo`.
///
/// # Why parsing is total
///
/// These arguments arrive from a UI test runner, from a scheme, and — occasionally — from a
/// developer typing them by hand. Malformed input is therefore expected rather than exceptional:
/// an unknown value falls back to the documented default, a value flag at the very end of the
/// array reads nothing, and no input of any shape can trap. A shop tool that cannot be crashed by
/// a stray command-line argument is worth the handful of guards below.
///
/// # Recognised launch arguments
///
/// | Argument | Effect |
/// |---|---|
/// | `-uiTesting` | in-memory store, stub scanner/notifications/StoreKit, animations off |
/// | `-uiTestSeed <none\|empty\|fiveUnresolved\|walkthrough>` | seeds the in-memory store |
/// | `-uiTestTier <free\|pro>` | forces the stub entitlement |
/// | `-uiTestStoreKitFailure` | `StubSubscriptionEngine(simulateLoadFailure: true)` |
/// | `-uiTestScannerPayload <string>` | manual-entry field pre-filled / stub scan result |
/// | `-uiTestSkipOnboarding` | marks the seeded profile as onboarded |
///
/// Each argument also has an environment-variable mirror (`UITESTING`, `UITEST_SEED`,
/// `UITEST_TIER`, `UITEST_STOREKIT_FAILURE`, `UITEST_SCANNER_PAYLOAD`,
/// `UITEST_SKIP_ONBOARDING`) for harnesses that cannot set arguments. Arguments always win.
///
/// The value-carrying flags only change behaviour in combination with `-uiTesting`: passing
/// `-uiTestTier pro` on its own deliberately does **not** swap the real App Store engine for the
/// stub, because a launch argument must never be able to hand out a paid entitlement in a
/// shipping build.
struct LaunchOptions: Equatable, Sendable {

    /// True when the app is being driven by `CoreCreditUITests`. Implies every determinism switch.
    var isUITesting: Bool

    /// Open the SwiftData store in memory, so the run leaves nothing behind.
    var useInMemoryStore: Bool

    /// Which fixture to insert once the in-memory store is open.
    var seedScenario: SeedScenario

    /// Forces the stub engine's tier. `nil` means "whatever the engine reports".
    var forcedTier: SubscriptionTier?

    /// Makes the stub engine fail product loading, so the paywall's retry path is reachable.
    var simulateStoreKitFailure: Bool

    /// Turns off SwiftUI animation, so UI tests are not racing a transition.
    var disableAnimations: Bool

    /// Uses the recording notification scheduler, so no permission prompt can ever appear.
    var disableNotifications: Bool

    /// Pre-fills the scanner's manual-entry field and backs the stub recogniser's barcode result.
    var stubScannerPayload: String?

    /// Starts on the main tab bar even when no onboarded shop profile exists.
    var skipOnboarding: Bool

    /// A deep link to deliver as though the system had opened it, e.g. `corecredit://scan`.
    ///
    /// UI tests cannot ask the springboard to open a custom scheme without driving Safari, which
    /// is slow and flaky. Handing the URL in at launch exercises the *cold-start* path — the one
    /// where the link arrives before the shell exists — which is exactly the path worth testing.
    /// Ignored unless `isUITesting` is set, so it can never affect a shipping build.
    var deepLink: String?

    /// Forces the stubbed notification authorization state under UI testing.
    ///
    /// The denied and not-determined branches of the notification settings screen are otherwise
    /// unreachable from a UI test: real authorization cannot be revoked from inside the process,
    /// and `RecordingNotificationScheduler` reports `.authorized` by default. `nil` keeps that
    /// default. Ignored unless `isUITesting` is set.
    var notificationAuthorization: NotificationAuthorizationStatus?

    init(isUITesting: Bool = false,
         useInMemoryStore: Bool = false,
         seedScenario: SeedScenario = SeedScenario.none,
         forcedTier: SubscriptionTier? = nil,
         simulateStoreKitFailure: Bool = false,
         disableAnimations: Bool = false,
         disableNotifications: Bool = false,
         stubScannerPayload: String? = nil,
         skipOnboarding: Bool = false,
         deepLink: String? = nil,
         notificationAuthorization: NotificationAuthorizationStatus? = nil) {
        self.isUITesting = isUITesting
        self.useInMemoryStore = useInMemoryStore
        self.seedScenario = seedScenario
        self.forcedTier = forcedTier
        self.simulateStoreKitFailure = simulateStoreKitFailure
        self.disableAnimations = disableAnimations
        self.disableNotifications = disableNotifications
        self.stubScannerPayload = stubScannerPayload
        self.skipOnboarding = skipOnboarding
        self.deepLink = deepLink
        self.notificationAuthorization = notificationAuthorization
    }

    /// A normal launch: on-disk store, real services, no fixtures.
    static let `default` = LaunchOptions()

    // MARK: - Parsing

    /// Reads the launch arguments and environment into a value. Never throws, never traps.
    static func parse(_ arguments: [String] = ProcessInfo.processInfo.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        var options = LaunchOptions.default

        // Environment first, so an explicit launch argument always overrides it.
        applyEnvironment(environment, to: &options)
        applyArguments(arguments, to: &options)

        // `-uiTesting` is the master switch: everything a test needs to be deterministic.
        if options.isUITesting {
            options.useInMemoryStore = true
            options.disableAnimations = true
            options.disableNotifications = true
        }

        return options
    }

    // MARK: - Arguments

    /// The flags this app owns. Used both to dispatch and to recognise where a value ends, so
    /// `-uiTestScannerPayload -uiTestSkipOnboarding` treats the second flag as a flag rather than
    /// swallowing it as a payload.
    private enum Flag {
        static let uiTesting = "-uiTesting"
        static let seed = "-uiTestSeed"
        static let tier = "-uiTestTier"
        static let storeKitFailure = "-uiTestStoreKitFailure"
        static let scannerPayload = "-uiTestScannerPayload"
        static let skipOnboarding = "-uiTestSkipOnboarding"
        static let deepLink = "-uiTestDeepLink"
        static let notificationAuthorization = "-uiTestNotificationAuthorization"

        static let all: Set<String> = [
            uiTesting, seed, tier, storeKitFailure, scannerPayload, skipOnboarding,
            deepLink, notificationAuthorization
        ]
    }

    /// Environment-variable names mirroring the launch arguments.
    private enum EnvironmentKey {
        static let uiTesting = "UITESTING"
        static let seed = "UITEST_SEED"
        static let tier = "UITEST_TIER"
        static let storeKitFailure = "UITEST_STOREKIT_FAILURE"
        static let scannerPayload = "UITEST_SCANNER_PAYLOAD"
        static let skipOnboarding = "UITEST_SKIP_ONBOARDING"
        static let deepLink = "UITEST_DEEP_LINK"
        static let notificationAuthorization = "UITEST_NOTIFICATION_AUTHORIZATION"
    }

    /// Maps a launch-argument value to an authorization state. An unrecognised value yields
    /// `nil`, which keeps the stub's default rather than guessing at what was meant.
    private static func notificationAuthorization(named raw: String) -> NotificationAuthorizationStatus? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "notdetermined", "not-determined": return .notDetermined
        case "denied": return .denied
        case "authorized": return .authorized
        case "provisional": return .provisional
        case "ephemeral": return .ephemeral
        default: return nil
        }
    }

    private static func applyArguments(_ arguments: [String], to options: inout LaunchOptions) {
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case Flag.uiTesting:
                options.isUITesting = true

            case Flag.seed:
                if let raw = value(after: index, in: arguments) {
                    options.seedScenario = seedScenario(named: raw)
                    index += 1
                }

            case Flag.tier:
                if let raw = value(after: index, in: arguments) {
                    options.forcedTier = tier(named: raw)
                    index += 1
                }

            case Flag.storeKitFailure:
                options.simulateStoreKitFailure = true

            case Flag.scannerPayload:
                if let raw = value(after: index, in: arguments) {
                    options.stubScannerPayload = payload(from: raw)
                    index += 1
                }

            case Flag.skipOnboarding:
                options.skipOnboarding = true

            case Flag.deepLink:
                if let raw = value(after: index, in: arguments) {
                    options.deepLink = raw
                    index += 1
                }

            case Flag.notificationAuthorization:
                if let raw = value(after: index, in: arguments) {
                    options.notificationAuthorization = notificationAuthorization(named: raw)
                    index += 1
                }

            default:
                // Anything else belongs to Xcode, XCTest, or the system. Leave it alone.
                break
            }

            index += 1
        }
    }

    /// The element after `index`, or `nil` when the flag is last in the array or is immediately
    /// followed by another CoreCredit flag. This is what makes a value flag at the end of the
    /// array harmless rather than an out-of-bounds read.
    private static func value(after index: Int, in arguments: [String]) -> String? {
        let next = index + 1
        guard next < arguments.count else { return nil }

        let candidate = arguments[next]
        guard !Flag.all.contains(candidate) else { return nil }
        return candidate
    }

    // MARK: - Environment

    private static func applyEnvironment(_ environment: [String: String], to options: inout LaunchOptions) {
        if let raw = environment[EnvironmentKey.uiTesting], isAffirmative(raw) {
            options.isUITesting = true
        }
        if let raw = environment[EnvironmentKey.seed] {
            options.seedScenario = seedScenario(named: raw)
        }
        if let raw = environment[EnvironmentKey.tier] {
            options.forcedTier = tier(named: raw)
        }
        if let raw = environment[EnvironmentKey.storeKitFailure], isAffirmative(raw) {
            options.simulateStoreKitFailure = true
        }
        if let raw = environment[EnvironmentKey.scannerPayload] {
            options.stubScannerPayload = payload(from: raw)
        }
        if let raw = environment[EnvironmentKey.deepLink], !raw.isEmpty {
            options.deepLink = raw
        }
        if let raw = environment[EnvironmentKey.notificationAuthorization], !raw.isEmpty {
            options.notificationAuthorization = notificationAuthorization(named: raw)
        }
        if let raw = environment[EnvironmentKey.skipOnboarding], isAffirmative(raw) {
            options.skipOnboarding = true
        }
    }

    // MARK: - Value interpretation

    /// Case-insensitive match against the documented scenarios. Anything unrecognised — including
    /// an empty string — falls back to the documented default of "seed nothing".
    private static func seedScenario(named raw: String) -> SeedScenario {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in SeedScenario.allCases {
            if candidate.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame {
                return candidate
            }
        }
        return SeedScenario.none
    }

    /// Case-insensitive match against the two tiers. Anything unrecognised means "do not force a
    /// tier", which leaves the engine's own answer in charge.
    private static func tier(named raw: String) -> SubscriptionTier? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == SubscriptionTier.free.rawValue { return .free }
        if trimmed == SubscriptionTier.pro.rawValue { return .pro }
        return nil
    }

    /// An all-whitespace payload is the same as no payload: the field should stay empty rather
    /// than be pre-filled with blanks.
    private static func payload(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let affirmativeValues: Set<String> = ["1", "true", "yes", "y", "on"]

    private static func isAffirmative(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return affirmativeValues.contains(trimmed)
    }
}
