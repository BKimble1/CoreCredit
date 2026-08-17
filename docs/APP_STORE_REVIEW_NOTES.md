# App Store review notes — CoreCredit (draft)

Paste the "For the reviewer" section into *App Store Connect → App Review Information → Notes*.
Everything above it is context for the owner and should not be submitted.

---

## Owner checklist before submitting

- [ ] Replace the placeholder bundle identifier and both product identifiers
      (`CoreCredit/App/AppConfiguration.swift`).
- [ ] Create the two auto-renewable subscriptions in App Store Connect in one subscription
      group, with the identifiers and prices below, and get them to **Ready to Submit**.
- [ ] Replace the placeholder support and privacy URLs with live pages.
- [ ] Add the 1024×1024 app icon.
- [ ] Confirm the privacy answers in `docs/PRIVACY.md` still match the shipped build.

---

## For the reviewer

**What CoreCredit does**

CoreCredit is a record-keeping tool for independent auto-repair shops. When a shop buys a
replacement part, the supplier adds a refundable "core charge" for the old part. The shop must
return the old part to that supplier before a deadline, and then confirm that the supplier
actually issued the credit. CoreCredit tracks how much of that refundable money is still
outstanding, which items are overdue, and which credits came back short.

All data is stored locally on the device. There is **no account, no sign-in, and no server**.
The app works fully offline; you can enable Airplane Mode and use every feature except
purchasing.

**How to test the main flow (about two minutes, no special setup)**

1. On first launch, tap through the short explanation, enter any shop name, and finish. You can
   skip the optional first vendor step.
2. Go to **Settings → Vendors → +** and add a vendor named `NAPA` with a 30-day return window.
   Save.
3. Go to **Cores → +**. Enter part name `Alternator`, part number `03-1887`, expected credit
   `86.50`, invoice `INV-552`, repair order `1024`. Choose vendor `NAPA`. Save.
4. The **Dashboard** now shows `$86.50` under "Money at risk", with a due date 30 days out.
5. Open the item and tap **Mark ready to return**.
6. Go to **Returns**, tap **Create return batch** on the NAPA group, select the item, enter
   reference `RET-991`, and confirm. The item moves to "Returned — awaiting credit" and
   **stays** in Money at risk — that is intentional; the money has not arrived yet.
7. Tap **Record credit** on that item, enter `86.50` and reference `CM-8841`, and save. The item
   becomes **Credited** and Money at risk drops to `$0.00`.
8. To see the dispute path, repeat with a credit of `75.00` instead. The app shows an `$11.50`
   shortfall, moves the item to **Disputed**, and offers **Export dispute packet**, which
   produces a PDF through the standard share sheet.

**Scanner behaviour in the Simulator**

The barcode scanner uses VisionKit's `DataScannerViewController`, which requires camera
hardware. **On the Simulator the app detects this and shows a manual-entry field instead**,
including a "Use sample barcode" button. No camera permission is requested and nothing is
blocked. The same manual fallback appears if camera access is denied or the device is
unsupported — scanning is always optional, and every field can be typed by hand.

Optional OCR (Vision text recognition on a photo of an invoice) only ever produces
**suggestions**, which are shown in editable fields for the user to confirm or reject. Nothing
recognised is written to a record automatically.

**In-app purchase — how to reach the paywall**

The free tier allows up to **5 unresolved core items** at a time. "Unresolved" means Awaiting
old core, Ready to return, Returned — awaiting credit, or Disputed. Items that are **Credited**
or **Written off** are closed and do not count.

To reach the paywall: create five core items and leave them open, then attempt to create a
sixth. The paywall appears at that point. It can also be opened voluntarily from
**Settings → Subscription**.

Two auto-renewable subscriptions, in one subscription group:

| Product identifier | Intended price |
|---|---|
| `com.example.corecredit.pro.monthly` | US $14.99 / month |
| `com.example.corecredit.pro.annual`  | US $119.99 / year |

Prices shown in the app are read from StoreKit and are never hard-coded.
**Restore Purchases** and **Manage Subscription** are both in Settings → Subscription and on the
paywall. There are no external payment links and no steering of any kind.

**The free limit never locks existing data.** A free user who already has records keeps full
access to viewing, editing, adding photos, recording credits, archiving, and exporting them.
The subscription gates only the creation of a *sixth simultaneously unresolved* item.

**Permissions**

- **Camera** — requested only when the user taps a scan or photo control, with the purpose
  string shown in the Info tab. Declining leaves manual entry fully available.
- **Notifications** — requested only from **Settings → Notifications**, when the user turns on
  deadline reminders. Never requested at launch or during onboarding.
- The app does **not** request Photo Library access (it uses `PhotosPicker`, which does not
  require it), and does not use location, contacts, calendar, microphone, Bluetooth, tracking,
  or background modes.

**Privacy**

No analytics SDK, no advertising SDK, no third-party SDK of any kind, and no network calls to
any developer-operated server. The only network activity is Apple's own StoreKit traffic for
subscriptions. The privacy manifest is included at
`CoreCredit/Resources/PrivacyInfo.xcprivacy`, declaring no tracking and no collected data
types. See `docs/PRIVACY.md`.

**Not financial advice**

The About screen states plainly that CoreCredit is an organisational record — not accounting
advice, and not a guarantee that any vendor will honour a return.
