# Privacy — CoreCredit

CoreCredit is published by **Idlery Services LLC**. Support: **support@idlery.com**. Version 1
is distributed in the **United States** App Store storefront only. The published policy lives at
<https://corecredit.idlery.com/privacy> and is generated from the same JSON the app
reads on device, so the two cannot drift.

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
| A backup file chosen for restore | Read once, in memory, from wherever the user picked it | No — it is read, never copied or transmitted |

Nothing is transmitted to the developer. There is no developer-operated server, no account, and
no sign-in.

---

## Restoring a backup

Restoring reads a file the user chooses through the system file importer. The file is opened inside
a security scope, decoded in memory, validated, and — only after the user confirms — used to replace
the local store. It is never copied elsewhere, never uploaded, and never retained: CoreCredit has no
server to send it to.

A backup contains records, not images. **Evidence photographs are not in the file and are not
restored.** Reminder preferences are not in it either, so the device's existing notification
settings are kept rather than overwritten.

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

## AI Photo Assist

Added as a Pro feature. It changes nothing in this document's answers, and the reason is worth
stating precisely rather than assuring.

- **Photographs never leave the device.** They are held in memory for the life of one assist
  session and are released when the sheet closes. Nothing is uploaded, and nothing is written to
  the store by the assistant — it produces suggestions for an unsaved form, and only the form's own
  Save writes anything.
- **No photo-library permission is requested.** Importing uses `PhotosPicker`, which runs out of
  process; the app receives only the images the user picked and never gains library access.
- **The camera is requested only on the tap that needs it**, exactly as before this feature existed.
  Nothing is requested at launch or during onboarding.
- **Recognition is Apple's Vision framework, on-device.** Text, barcodes, image classification, and
  feature prints all run locally. No prompt, no image, no recognised text, and no diagnostic is sent
  anywhere, because the app makes no network requests of its own at all.
- **Depth, where the hardware has it,** is read from ARKit scene depth during the capture screen's
  own session and is discarded when that screen closes. No measurement is displayed, stored, or
  written into a note.
- **Automatic capture is bounded to the capture screen.** The AR session starts when that view is
  created and is paused when it is torn down; a paused session delivers no frames, so nothing is
  collected in the background.
- **No new data is collected**, so the privacy manifest and the App Store Connect answers below are
  unchanged.

---

## Third-party SDKs

**None.** The app links only Apple frameworks: SwiftUI, Observation, SwiftData, Vision,
VisionKit, ARKit and SceneKit (AI Photo Assist's optional depth and automatic capture, on
devices that have a LiDAR scanner), Core Image, ImageIO, UserNotifications, PDFKit, StoreKit,
PhotosUI, AVFoundation (camera authorization only), UIKit, and Foundation. There is no
analytics SDK, no advertising SDK, no crash reporter, and no dependency manager.

There is no Core ML model bundled with the app, no model downloaded at runtime, and no use of
Private Cloud Compute or any hosted model. AI Photo Assist's "AI" is Apple's on-device Vision
framework — the same one the document scanner already used — running on this device's own
silicon.

---

## Permissions actually requested

| Permission | When | If declined |
|---|---|---|
| Camera | Only when the user taps a scan or photo control | Manual entry remains fully available; the app explains and offers a Settings link |
| Notifications | Only from Settings → Notifications, when enabling deadline reminders | Reminders are off and the app says so plainly; nothing else is affected |

The **Scan core** screen's Live mode recognises barcodes *and* printed text in the camera preview.
Both are recognised entirely on device, by VisionKit and Vision; no frame, no transcript, and no
image ever leaves the device, and nothing is written to a record without a person confirming it on
the review screen. Recognised text is highlighted only — it is handed to the app when the user taps
a specific line, never because it came into frame.

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

  A disk-space declaration (`E174.1`) was removed: an audit found the app never calls a
  disk-space API, so declaring it would have over-stated what CoreCredit does. Declare only
  what the code actually uses.

The capture rework did not change any of this. Adding live text recognition adds an on-device Vision
pass, not a data flow: there is still no analytics, no crash reporter, no network client of the
app's own, and no stored image beyond the evidence photos the user deliberately attaches.

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
