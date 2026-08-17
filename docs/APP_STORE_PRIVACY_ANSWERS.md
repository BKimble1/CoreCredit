# App Store Connect privacy answers — CoreCredit

Recommended answers for the App Privacy questionnaire, plus the evidence behind each one.

Every answer below is grounded in the shipped code. Nothing here is aspirational: if a future
change makes one of these answers false, the change and this file must land in the same commit,
together with `CoreCredit/Resources/PrivacyInfo.xcprivacy` and the bundled documents in
`CoreCredit/Resources/Legal/`.

---

## The audit these answers rest on

Verified across every file in the app target:

| Claim | How it was checked | Result |
|---|---|---|
| No networking outside StoreKit | Search for `URLSession`, `URLRequest`, `NWConnection`, `CFNetwork` | No hits |
| No analytics, tracking, ads, or crash reporting | Search for Firebase / Crashlytics / Analytics style SDKs | No hits |
| No third-party dependencies | `packageProductDependencies` on every target | Empty |
| No account, no developer backend | No sign-in exists anywhere in the app | Confirmed |
| Records stay on device | SwiftData store and app container only | Confirmed |
| Scanner diagnostics | In-memory, most recent session only, no image bytes, never uploaded | Confirmed |
| Exports | Written to the app's Caches directory; leave only via the system Share Sheet, on the user's action | Confirmed |
| Notifications | Local `UNUserNotificationCenter` requests scheduled on device | Confirmed |
| Subscriptions | StoreKit 2, verified on device; no receipt-validation server | Confirmed |
| `UserDefaults` | Cached subscription entitlement only | Confirmed |
| File timestamps | Read only to sweep the app's own old exports | Confirmed |
| Sync | No CloudKit, no sync, no multi-device or multi-employee sharing | Confirmed |
| Disk space APIs | Search for `volumeAvailableCapacity`, `systemFreeSize` | **No hits — see below** |

---

## Recommended answers

### The two top-level questions

| Question | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **No** |
| Does this app use data for tracking? | **No** |

Answering "No" to the first question ends the questionnaire: no data types are declared.

### Why "Data Not Collected" is supportable

Apple's definition of *collect* is transmitting data off the device and retaining it beyond the
processing of a single request. CoreCredit transmits nothing. There is no developer-operated
server to transmit to, and no network client in the app to transmit with.

If the questionnaire is worked through category by category, every one of them is **Data Not
Collected**:

| Category | Answer | Why |
|---|---|---|
| Contact Info | Not collected | The shop profile is typed by the user and stays in the local store |
| Health & Fitness | Not collected | Not touched |
| Financial Info | Not collected | Core charges and credit amounts are local records; Apple handles payment, and the app never sees payment details |
| Location | Not collected | Never requested |
| Sensitive Info | Not collected | Not touched |
| Contacts | Not collected | Never requested |
| User Content | Not collected | Photos, receipts, OCR text, and notes stay in the app container |
| Browsing History | Not collected | Not applicable |
| Search History | Not collected | Ledger search is a local filter; nothing is logged or sent |
| Identifiers | Not collected | No user ID, no device ID, no advertising identifier is read or sent |
| Purchases | Not collected | Apple processes the purchase. The app stores only a local flag for the last known entitlement |
| Usage Data | Not collected | No analytics of any kind |
| Diagnostics | Not collected | Scanner diagnostics are in memory, on device, and are shared only if the user shares them |
| Other Data | Not collected | Nothing else leaves the device |

### Tracking

`NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty. The app contains no
advertising, attribution, or measurement software and never asks for App Tracking Transparency
permission, because there is nothing that would justify asking.

### Privacy manifest

`CoreCredit/Resources/PrivacyInfo.xcprivacy` declares:

- `NSPrivacyTracking` — `false`
- `NSPrivacyTrackingDomains` — empty
- `NSPrivacyCollectedDataTypes` — empty
- `NSPrivacyAccessedAPITypes` — two entries, each backed by real code:
  - **File timestamp, `C617.1`.** `ExportFileStore.cleanUpOldExports(olderThan:)` reads
    `contentModificationDateKey` on files in the app's own caches directory to delete generated
    exports older than 24 hours. The reason string covers timestamps of files inside the app
    container created by the app itself, which is exactly what happens.
  - **User defaults, `CA92.1`.** `EntitlementCache` stores the last known subscription entitlement
    so a paying shop is not locked out while offline. Access is limited to the app itself; there is
    no app group and no other reader.

**Removed: disk space, `E174.1`.** A repository-wide search finds no disk-space API in the app
target — no `volumeAvailableCapacity` key, no `systemFreeSize`, no free-space check before writing a
photo or an export. The entry described behaviour the code does not have, so it has been deleted.
If a free-space check is ever added, the entry must be restored in the same commit.

> `docs/PRIVACY.md` still lists the disk-space entry in its "Privacy manifest" section. That file
> was outside the scope of this change; its bullet should be deleted in a follow-up so the two
> documents agree.

---

## What would invalidate these answers

Any one of the following makes "Data Not Collected" false the day it ships:

- an analytics, attribution, measurement, or crash-reporting SDK, including a "free" one
- any network client of the app's own — `URLSession`, a web view that loads remote content, a
  feedback form that posts anywhere
- a developer-operated backend, sync service, or receipt-validation server
- CloudKit, iCloud sync, or any shared multi-device or multi-employee ledger
- an in-app support form that sends content anywhere other than the user's own mail client
- a third-party package dependency of any kind, since a dependency can collect data on its own
- reading a device or advertising identifier for any purpose

A caveat worth stating plainly, though it does not change the answers: the user's records are
included in their own iCloud or computer backup of the device, because they live in the app's
container. That is Apple's backup of the user's own device, not a transmission to the developer.
The bundled privacy policy says so rather than implying the data exists nowhere else.

---

## Owner actions still required before submission

The documents ship with explicit `[TO BE SUPPLIED BY OWNER - …]` markers. Nothing has been invented.

1. **Legal entity.** Name of the developer or company, and a postal address if one is required.
   Appears in `privacy-policy.json` ("Who is responsible, and how to get in touch"),
   `terms-of-use.json` ("Who provides CoreCredit, and how to get in touch"), and
   `docs/legal-public/support.html`.
2. **Governing law and venue.** Appears in `terms-of-use.json` ("Limits on responsibility").
   No jurisdiction has been chosen for you.
3. **Support email address and support page.** Appears in all three bundled documents and in
   `docs/legal-public/support.html`. Until one is set, the app shows no support address at all and
   says so.
4. **Published URLs.** Replace `supportURLString`, `privacyURLString`, `termsURLString`, and
   `supportEmail` in `CoreCredit/App/AppConfiguration.swift`. They are `example.com` stand-ins, and
   `AppConfiguration.isPlaceholder(_:)` keeps every one of them off the screen until they are real.
5. **Publish the pages.** `docs/legal-public/privacy.html`, `terms.html`, and `support.html` are the
   pages to host at those addresses. They are self-contained static HTML with no script, no external
   stylesheet, no web font, and no tracker. App Review checks that the privacy and support URLs
   resolve. The app never fetches them; the in-app documents are the copies that matter to users.
6. **App Store Connect fields.** Privacy Policy URL is mandatory. An auto-renewable subscription
   also requires a Terms of Use (EULA) link — use `terms.html`, or Apple's standard EULA.
   The paywall already shows the price from StoreKit `displayPrice`, the renewal disclosure, both
   documents, Restore Purchases, and Manage Subscription.
7. **Age rating.** Answer the rating questionnaire as a business tool. Do **not** enrol in the Kids
   Category: the bundled documents state the app is not intended for or directed to children.
8. **Re-run the audit before each submission.** The table at the top of this file is the checklist.
   If a search that returned "no hits" starts returning hits, the answers here are no longer true.
