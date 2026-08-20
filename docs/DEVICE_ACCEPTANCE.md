# CoreCredit — physical-device acceptance checklist

Everything a simulator cannot prove. **None of it has been performed.** Nothing in this file may be
reported as passing until somebody has done it on real hardware and written the date next to it.

Automated tests cover the deterministic layer: money arithmetic, status rules, due dates,
reconciliation, entitlement, search, ranking, deduplication, backup encode/decode/restore, palette
contrast, deep-link parsing, and the launch-screen configuration. They cannot cover a camera, a
notification, a widget on a Home Screen, Siri, VoiceOver, a keyboard, or a real purchase.

Run this on **at least one iPhone and one iPad**, in **both appearances**. Record the device, the
iOS version, and the build number at the top of each pass.

```
Device / iOS / build: ______________________________________
Tester / date:        ______________________________________
```

---

## 1. Live scanning — the camera path

| # | Check | Pass |
|---|---|---|
| 1.1 | Scan core opens on **Live** with a working viewfinder | ☐ |
| 1.2 | A Code 128 or Code 39 part-number barcode reads first time, in shop lighting | ☐ |
| 1.3 | Exactly **one** success haptic per accepted read — not one per frame | ☐ |
| 1.4 | The preview **freezes** on a read; it does not keep hunting behind the result | ☐ |
| 1.5 | The same code held in frame does **not** fire repeatedly (cooldown + dedup) | ☐ |
| 1.6 | A UPC/EAN off a box is offered as a **barcode value**, never as a part number | ☐ |
| 1.7 | *Resume scanning* restarts the camera and discards the frozen read | ☐ |
| 1.8 | Nothing reaches the form until *Use these details* → review → *Apply* | ☐ |

## 2. Tapped live text

| # | Check | Pass |
|---|---|---|
| 2.1 | Printed text on an invoice is **highlighted** while barcodes still scan | ☐ |
| 2.2 | Highlighted text does **nothing** until tapped — the camera never chooses | ☐ |
| 2.3 | A tapped line reaches the review sheet, not the form | ☐ |
| 2.4 | A tapped money amount does **not** start pre-selected | ☐ |
| 2.5 | Barcode decode rate is not visibly degraded by text recognition being on | ☐ |

## 3. Document scanning and OCR

| # | Check | Pass |
|---|---|---|
| 3.1 | The Document segment opens the system document camera | ☐ |
| 3.2 | Page-edge detection and perspective correction work on a real invoice | ☐ |
| 3.3 | Multi-page capture (3+ pages) completes and all pages are read | ☐ |
| 3.4 | A core charge is found and outranks the invoice **total** | ☐ |
| 3.5 | Only high-confidence suggestions start ticked | ☐ |
| 3.6 | Cancelling the camera lands on an explanation, never a blank sheet | ☐ |
| 3.7 | On hardware without a document camera, the fallback explanation appears | ☐ |

## 4. Permissions — denial and recovery

| # | Check | Pass |
|---|---|---|
| 4.1 | First scan prompts for camera with the purpose string from the Info tab | ☐ |
| 4.2 | **Declining** leaves manual entry fully usable — nothing is blocked | ☐ |
| 4.3 | The denied state offers *Open Settings* and it opens this app's page | ☐ |
| 4.4 | Granting access in Settings and returning restores the viewfinder | ☐ |
| 4.5 | Notifications are **never** requested at launch or during onboarding | ☐ |
| 4.6 | Declining notifications is stated plainly; nothing else stops working | ☐ |

## 5. Evidence photos

| # | Check | Pass |
|---|---|---|
| 5.1 | Part, box, invoice, and receipt photos attach and display | ☐ |
| 5.2 | PhotosPicker requires **no** photo-library permission prompt | ☐ |
| 5.3 | *Read details from the latest photo* produces suggestions, not commits | ☐ |
| 5.4 | Photos survive relaunch, and a dispute packet contains them | ☐ |

## 6. Notifications

| # | Check | Pass |
|---|---|---|
| 6.1 | Enabling reminders in Settings requests permission at that moment | ☐ |
| 6.2 | *Send a test reminder* arrives on the lock screen | ☐ |
| 6.3 | A real due-soon reminder fires at the configured hour | ☐ |
| 6.4 | Tapping a reminder opens **that core** | ☐ |
| 6.5 | Settling a core cancels its pending reminders | ☐ |
| 6.6 | With *Show detail* off, no money appears on the lock screen | ☐ |
| 6.7 | Tapping a notification while the app is **closed** launches it without crashing | ☐ |
| 6.8 | Tapping the test reminder — which carries no route — opens the app and does nothing else | ☐ |
| 6.9 | *View Item*, *Scan Core*, and *Snooze 1 Day* each act once, from the lock screen | ☐ |

> 6.7 and 6.8 are the crash that killed build 38. The notification delegate was written in its
> `async` form, which let UserNotifications call UIKit back on a background thread during the
> launch a tap causes. It reproduces on a device and not in the simulator, so it has to be walked
> here. See `NotificationResponder` and the `notification delegate` repository invariant.

## 7. Widget, Shortcut, Siri, Action Button

| # | Check | Pass |
|---|---|---|
| 7.1 | The Quick Scan widget can be added in every declared family | ☐ |
| 7.2 | The widget renders correctly on the Home Screen and Lock Screen | ☐ |
| 7.3 | Tapping it opens **Scan core** over a new unsaved draft | ☐ |
| 7.4 | "Scan core in CoreCredit" works as a Siri phrase | ☐ |
| 7.5 | The App Shortcut appears in Shortcuts without being created by hand | ☐ |
| 7.6 | Assigned to the Action Button, it opens the same surface from a cold start | ☐ |
| 7.7 | Cancelling from any of these leaves the form, and writes nothing | ☐ |

## 8. Deep links

| # | Check | Pass |
|---|---|---|
| 8.1 | A printed bin-tag QR opens that core, scanned with the **system** camera | ☐ |
| 8.2 | The same link works on a **cold** start, not only when the app is running | ☐ |
| 8.3 | A tag for a deleted core does nothing rather than showing an empty screen | ☐ |

## 9. Purchase, restore, expiry — StoreKit sandbox

| # | Check | Pass |
|---|---|---|
| 9.1 | The paywall shows both products with **Apple's** prices, not hard-coded ones | ☐ |
| 9.2 | A sandbox purchase of the monthly product unlocks Pro | ☐ |
| 9.3 | A sandbox purchase of the annual product unlocks Pro | ☐ |
| 9.4 | *Restore Purchases* restores on a second device / after reinstall | ☐ |
| 9.5 | A sandbox subscription **expiring** returns the app to Free | ☐ |
| 9.6 | After expiry every existing record is still viewable, editable, exportable | ☐ |
| 9.7 | Only the creation of a **sixth unresolved** core is blocked | ☐ |
| 9.8 | *Manage Subscription* opens Apple's sheet | ☐ |
| 9.9 | With no network, cached entitlement keeps Pro rather than demoting | ☐ |
| 9.10 | **Cancelling** the App Store sheet leaves the app on Free, charges nothing, shows no error | ☐ |
| 9.11 | Tapping a plan twice quickly starts **one** purchase — both rows disable while it runs | ☐ |
| 9.12 | *Restore Purchases* with no subscription says so plainly instead of doing nothing visible | ☐ |
| 9.13 | Turning **auto-renew off** in Apple's sheet keeps Pro until the paid period actually ends | ☐ |
| 9.14 | Settings → Subscription reads **"Current period ends"** and the date matches Apple's own Subscriptions screen | ☐ |
| 9.15 | Ask to Buy (a managed child account) shows "Waiting for approval", not a failure | ☐ |
| 9.16 | With products unavailable (Airplane Mode from cold), the paywall shows a message **and a working Retry** | ☐ |

> **9.14 is the row that answers a question already asked once.** A monthly subscription bought in
> a test environment shows a period ending the same day or the next one, because Apple accelerates
> them: a sandbox month is **5 minutes** by default, and in TestFlight *every* duration renews in
> **1 day**. That is the environment, not a bug — and the word "Renews" comes from Apple's screen,
> never from CoreCredit, which says "Current period ends" and prints
> `Transaction.expirationDate` verbatim. What this row is checking is that the two screens agree.
> A real monthly period can only be seen in production. See `docs/RELEASE.md` §5.

## 10. Appearance and type

| # | Check | Pass |
|---|---|---|
| 10.1 | App opens in **Light** on a device set to Dark | ☐ |
| 10.2 | Settings → Appearance switches Light / Dark / Match device immediately | ☐ |
| 10.3 | The choice survives a relaunch | ☐ |
| 10.4 | Cards are clearly distinguishable from the background in **both** | ☐ |
| 10.5 | Every screen at the **largest** accessibility type size: no clipping | ☐ |
| 10.6 | Money never truncates at any type size | ☐ |
| 10.7 | Increase Contrast and Bold Text remain legible | ☐ |
| 10.8 | Reduce Motion: no unexpected movement | ☐ |
| 10.9 | The launch screen shows the mark on brand blue — **no white flash** | ☐ |

## 11. VoiceOver

| # | Check | Pass |
|---|---|---|
| 11.1 | Reading order on Dashboard, Cores, Returns, Settings is sensible | ☐ |
| 11.2 | Money is spoken as words, not punctuation | ☐ |
| 11.3 | Status is announced by name, never by colour alone | ☐ |
| 11.4 | Every control has a label and, where useful, a hint | ☐ |
| 11.5 | The scan review sheet is fully operable | ☐ |
| 11.6 | The rotor moves between section headers | ☐ |

## 12. Keyboard and layout

| # | Check | Pass |
|---|---|---|
| 12.1 | **Save core** stays visible above the keyboard while typing | ☐ |
| 12.2 | Nothing on any tab scrolls underneath the tab bar | ☐ |
| 12.3 | The last row of every root screen is reachable and tappable | ☐ |
| 12.4 | Optional sections stay open when they hold a value or an error | ☐ |
| 12.5 | iPad regular width: sidebar + detail, no nested navigation bars | ☐ |
| 12.6 | Smallest supported iPhone width: no horizontal truncation | ☐ |

## 13. Export and restore — with a real shared file

The one workflow that crosses process boundaries and cannot be simulated end to end.

| # | Check | Pass |
|---|---|---|
| 13.1 | CSV export opens the share sheet and the file opens in a spreadsheet app | ☐ |
| 13.2 | JSON backup export shares to Files / iCloud Drive / AirDrop | ☐ |
| 13.3 | Ledger PDF and a dispute packet render correctly | ☐ |
| 13.4 | **Restore** picks the shared backup through the file importer | ☐ |
| 13.5 | The preflight shows the right counts and money before anything changes | ☐ |
| 13.6 | Cancelling the preflight leaves the ledger **completely unchanged** | ☐ |
| 13.7 | Confirming replaces the ledger; cores, vendors, bins, returns, history all return | ☐ |
| 13.8 | Money is exact to the cent after the restore | ☐ |
| 13.9 | Choosing a **non-backup** JSON file is refused, and nothing is deleted | ☐ |
| 13.10 | Reminders are rescheduled for the restored deadlines | ☐ |
| 13.11 | Evidence photos are **absent** after restore, as the app said they would be | ☐ |
| 13.12 | Restoring onto a **second device** reproduces the ledger | ☐ |

---

## Known limits to confirm rather than fix

These are deliberate. Confirm the behaviour matches the documentation rather than filing them.

- A returned core **stays** in Money at risk until a credit is recorded.
- A returned-but-uncredited core past its due date still reads as overdue.
- A $0.00 credit is allowed and produces a full-value dispute.
- Deleting a vendor or bin does **not** delete cores; they survive vendor-less.
- Evidence photos are not in a backup file and cannot be restored from one.
- Reminder preferences are not in a backup file; the device's own settings are kept.

## Sign-off

A build may go to TestFlight with this incomplete. It may **not** go to public App Store review
with sections 1–4, 6, 7, 9, or 13 unchecked: those are the paths where a failure costs a shop money
or data rather than convenience.

```
Sections completed: ______   Blocking failures: ______
Signed:             ______________________  Date: __________
```
