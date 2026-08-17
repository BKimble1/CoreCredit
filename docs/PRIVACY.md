# Privacy — CoreCredit

This document records what the shipped code actually does, so the App Store privacy answers can
be given honestly and re-checked whenever the app changes.

**The rule for this codebase: never claim a privacy property the implementation contradicts.**
If telemetry, crash reporting, or any network client is ever added, this file and the App Store
answers must change in the same commit.

---

## What the app stores, and where

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Shop profile (name, optional phone/email/address, currency) | Local SwiftData store | No |
| Vendors, storage bins | Local SwiftData store | No |
| Core items (part, amounts, references, dates, status, notes) | Local SwiftData store | No |
| Return batches and their references | Local SwiftData store | No |
| Evidence photos (part, box, invoice, receipt) | Local SwiftData store, external-storage attribute | No |
| Event timeline | Local SwiftData store | No |
| Reminder settings | Local SwiftData store (on `ShopProfile`) | No |
| Last-known subscription entitlement | `UserDefaults` on device | No |
| Generated PDF / CSV / JSON exports | App-controlled `Caches/CoreCreditExports`, swept after 24 h | Only when the user shares one |

Nothing is transmitted to the developer. There is no developer-operated server, no account, and
no sign-in.

---

## Network activity

The app makes **no network requests of its own**. The only network traffic is Apple's, on the
app's behalf:

- **StoreKit 2** — loading subscription products, purchasing, restoring, and refreshing
  entitlements. Handled entirely by Apple; the app never sees payment details.
- Tapping the Privacy or Support link opens a URL in the system browser, which the user
  initiates deliberately.

Verification is on-device StoreKit 2 signature verification. There is no receipt-forwarding
server.

---

## Third-party SDKs

**None.** The app links only Apple frameworks: SwiftUI, Observation, SwiftData, Vision,
VisionKit, Core Image, ImageIO, UserNotifications, PDFKit, StoreKit, PhotosUI, AVFoundation
(camera authorization only), UIKit, and Foundation. There is no analytics SDK, no advertising
SDK, no crash reporter, and no dependency manager.

---

## Permissions actually requested

| Permission | When | If declined |
|---|---|---|
| Camera | Only when the user taps a scan or photo control | Manual entry remains fully available; the app explains and offers a Settings link |
| Notifications | Only from Settings → Notifications, when enabling deadline reminders | Reminders are off and the app says so plainly; nothing else is affected |

**Not requested:** Photo Library (`PhotosPicker` needs no permission), location, contacts,
calendar, reminders, microphone, Bluetooth, Health, Motion, App Tracking Transparency.
No background modes and no remote push notifications.

Usage strings are set in the target's build settings (`INFOPLIST_KEY_NSCameraUsageDescription`)
and are purpose-specific.

---

## Privacy manifest

`CoreCredit/Resources/PrivacyInfo.xcprivacy` declares:

- `NSPrivacyTracking` — `false`
- `NSPrivacyTrackingDomains` — empty
- `NSPrivacyCollectedDataTypes` — empty
- `NSPrivacyAccessedAPITypes` — the required-reason APIs the app genuinely uses:
  - File timestamp — reason `C617.1` (managing files the app itself created: exports)
  - User defaults — reason `CA92.1` (access limited to the app itself: cached entitlement)
  - Disk space — reason `E174.1` (writing an export and reporting a failure to the user)

---

## Suggested App Store Connect answers

With the current implementation, every data-type question can be answered **"Data Not
Collected."** The shop's business records never reach the developer, so they are not "collected"
in Apple's sense.

- Does this app collect data? → **No**
- Does this app use data for tracking? → **No**

**Caveat to keep honest:** the user's records are included in their own iCloud or Finder device
backup, because they live in the app's container. That is Apple's backup, not a transmission to
the developer, and does not change the answer — but the About screen says so anyway rather than
implying the data exists nowhere else.

---

## What would change these answers

Adding any of the following would make the current answers false:

- an analytics or crash-reporting SDK
- a developer-operated sync backend or receipt-validation server
- CloudKit sharing, or any multi-device sync
- an email/support form that posts content anywhere other than the user's own mail client
- any advertising or attribution SDK

None of these exist in Version 1, and adding one is a deliberate decision that must update this
document, `PrivacyInfo.xcprivacy`, the About screen copy, and the App Store answers together.
