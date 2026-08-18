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

## 14. AI Photo Assist (Beta) — Pro only

Everything below is **unperformed**. None of it can be: this feature was written on a machine with
no Swift compiler, and its recognition quality, its camera behaviour, and its LiDAR path have never
run on hardware of any kind. The automated suite covers the deterministic half — fusion, capping,
conflict detection, limits, duplicate rejection, staleness, and the Pro gate — and can say nothing
whatever about whether a photograph of a greasy alternator in a badly lit shop actually reads.

Run **section 14 in full on one LiDAR-capable iPhone or iPad and one iPhone without a LiDAR
scanner.** The two devices take genuinely different paths.

### 14.1 The gate

| # | Check | Pass |
|---|---|---|
| 14.1.1 | On **Free**, the row is visible on Scan core, shows a lock, and explains itself | ☐ |
| 14.1.2 | Tapping it on Free opens the paywall, not the feature | ☐ |
| 14.1.3 | Closing that paywall leaves the capture sheet open and unchanged | ☐ |
| 14.1.4 | A sandbox **monthly** purchase unlocks it | ☐ |
| 14.1.5 | A sandbox **annual** purchase unlocks it | ☐ |
| 14.1.6 | A sandbox subscription **expiring** re-locks it, and locks nothing else | ☐ |
| 14.1.7 | On Free, manual entry, Live scan, and Document scan all still work | ☐ |

### 14.2 Gathering photographs

| # | Check | Pass |
|---|---|---|
| 14.2.1 | *Choose from Photos* opens the picker with **no** photo-library permission prompt | ☐ |
| 14.2.2 | Several photos can be selected in one pass | ☐ |
| 14.2.3 | *Take photo* prompts for the camera **only on that tap**, never before | ☐ |
| 14.2.4 | Declining the camera leaves importing and manual entry fully usable | ☐ |
| 14.2.5 | The seventh photo is refused with a message naming the limit | ☐ |
| 14.2.6 | Two shots of the same view are refused as a duplicate | ☐ |
| 14.2.7 | Removing a thumbnail frees a slot, and a new photo can be added | ☐ |
| 14.2.8 | Removing a photo after a read clears the stale suggestions | ☐ |

### 14.3 Automatic capture — LiDAR/ARKit device only

| # | Check | Pass |
|---|---|---|
| 14.3.1 | The Auto control appears on this device, and **not** on the non-LiDAR one | ☐ |
| 14.3.2 | Holding steady collects a frame; moving does not | ☐ |
| 14.3.3 | "Hold steady" / "Captured" and the running count are all shown | ☐ |
| 14.3.4 | One steady hand does **not** fill all six slots (cooldown + duplicate rejection) | ☐ |
| 14.3.5 | Collection stops at six | ☐ |
| 14.3.6 | Switching Auto off ends the session immediately | ☐ |
| 14.3.7 | Closing the sheet ends it; backgrounding the app collects nothing | ☐ |
| 14.3.8 | A photo captured in portrait is **not** analysed sideways | ☐ |

### 14.4 Recognition quality — the part nobody can promise

| # | Check | Pass |
|---|---|---|
| 14.4.1 | A printed parts label reads correctly in ordinary shop light | ☐ |
| 14.4.2 | **Low light**: it either reads or says it could not — never a confident wrong answer | ☐ |
| 14.4.3 | A **reflective or dirty** metal casting does not produce a fabricated part number | ☐ |
| 14.4.4 | A **part-only** photo, with no label, offers a part *name* and no number | ☐ |
| 14.4.5 | A **box panel** photo reads its barcode, and the UPC does not become a part number | ☐ |
| 14.4.6 | An invoice with **several amounts** picks the core charge, not the total, tax, or freight | ☐ |
| 14.4.7 | The core charge arrives **unticked**, every time | ☐ |
| 14.4.8 | **Conflicting** photos of two different part numbers show both, ticked neither | ☐ |
| 14.4.9 | A vendor name matches an existing vendor; an unknown one is not silently created | ☐ |
| 14.4.10 | Nothing suggests a bin, a status, a due date, or a credit | ☐ |

### 14.5 Depth

| # | Check | Pass |
|---|---|---|
| 14.5.1 | LiDAR device: the capability line mentions the depth scanner | ☐ |
| 14.5.2 | Non-LiDAR device: it reads "Standard camera analysis" and everything still works | ☐ |
| 14.5.3 | A part held at arm's length and the same part across the room produce the **same** suggestions, differing only in the explanation | ☐ |
| 14.5.4 | No measurement appears anywhere, and none is written into notes | ☐ |

### 14.6 Memory and repetition

| # | Check | Pass |
|---|---|---|
| 14.6.1 | Six full-resolution photographs analyse without the app being killed | ☐ |
| 14.6.2 | Ten sessions back to back do not degrade or leak | ☐ |
| 14.6.3 | Closing mid-analysis returns to the scanner promptly, with no spinner left behind | ☐ |
| 14.6.4 | Repeated open/close of Auto capture does not leave the camera running | ☐ |

### 14.7 Accessibility

| # | Check | Pass |
|---|---|---|
| 14.7.1 | VoiceOver reads the guided shots, and says which are added | ☐ |
| 14.7.2 | VoiceOver announces analysis progress | ☐ |
| 14.7.3 | Each suggestion is announced with its confidence **and** where it came from | ☐ |
| 14.7.4 | Every thumbnail's remove action is reachable and at least 44pt | ☐ |
| 14.7.5 | Largest accessibility type size: nothing clips on any of these screens | ☐ |
| 14.7.6 | Light, Dark, and Match Device all render correctly | ☐ |

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
with sections 1–4, 6, 7, 9, 13, or 14 unchecked: those are the paths where a failure costs a shop
money or data rather than convenience. Section 14 is listed here because a fabricated part number or a
mis-read core charge is a wrong number in a ledger somebody reconciles against a vendor.

```
Sections completed: ______   Blocking failures: ______
Signed:             ______________________  Date: __________
```
