# App Store review notes — CoreCredit (draft)

Paste the "For the reviewer" section into *App Store Connect → App Review Information → Notes*.
Everything above it is context for the owner and should not be submitted.

---

## Owner checklist before submitting

- [x] Bundle identifier and both product identifiers are set
      (`CoreCredit/App/AppConfiguration.swift`, matching `StoreKit/CoreCredit.storekit`).
- [ ] Create the two auto-renewable subscriptions in App Store Connect in one subscription
      group, with the identifiers and prices below, and get them to **Ready to Submit**.
      Until they exist there, StoreKit returns no products and the paywall shows its retry
      state — a missing product is silent, never an error.
- [x] Publish the support and legal pages and point the app at them:
      - Support: <https://corecredit.idlery.com/support>
      - Privacy: <https://corecredit.idlery.com/privacy>
      - Terms:   <https://corecredit.idlery.com/terms>

      They are static pages on the owner's own domain. The exact HTML is generated into
      `docs/legal-public/` from the JSON the app reads on device, so the published wording and the
      on-device wording cannot drift. **The addresses above have not been fetched from this
      repository** — the session that set them could not reach the host — so open all three in a
      browser before submitting. An earlier build pointed at `bkimble1.github.io/CoreCredit-Legal`,
      which was verified over HTTPS anonymously on 2026-08-17; those pages still exist, and the
      generated HTML is host-independent, so either origin can serve it.
- [x] Set the publisher, support address, and territory: **Idlery Services LLC**,
      **support@idlery.com**, **United States only** for Version 1. No individual's name and no
      postal address appears in the app, the bundled documents, or the published pages.
- [x] Add the 1024×1024 app icon (`AppIcon.appiconset/AppIcon.png` is real artwork).
- [ ] Confirm the privacy answers in `docs/PRIVACY.md` still match the shipped build.
- [ ] Look at the app in **Light and Dark appearance**, at an accessibility text size, on a small
      iPhone and on an iPad, before submitting.

      Partly done: device captures of the running app exist in the repository root — `Dashboard.png`
      and `Cores.png` (iPhone, light) and `IMG_0309/0313/0314/0315.PNG` (iPad landscape, light,
      dated Wed Aug 19). They show the shipping layout: the iPhone tab bar, the iPad
      sidebar-and-detail split, Money at risk, the status badges, and the overdue treatment. Every
      status is carried by an icon and a word as well as a colour.

      What those captures do **not** cover, and what this box is still about: **Dark appearance**,
      **accessibility text sizes**, and a **small (compact) iPhone**. Do those three before
      submitting.

---

## For the reviewer

**Publisher and availability**

CoreCredit is published by **Idlery Services LLC**. Support is **support@idlery.com**. Version 1
is offered in the **United States** storefront only.

- Support: <https://corecredit.idlery.com/support>
- Privacy Policy: <https://corecredit.idlery.com/privacy>
- Terms of Use: <https://corecredit.idlery.com/terms>

The Privacy Policy and Terms of Use are also readable **inside the app**, with no connection, at
Settings → Legal. The published pages are generated from the same text, so the two cannot differ.

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
   `86.50`, and choose vendor `NAPA`. **References**, **Storage bin**, **Evidence**, and **Notes**
   are optional and stay folded away until you tap their headings — open **References** if you want
   to add invoice `INV-552` and repair order `1024`. Tap **Save core** in the bar at the bottom.
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

**Scanning — one screen, two modes**

Everything that starts a scan — the Home Screen widget, the "Scan core" Shortcut / Action Button,
the Dashboard's Scan core button, and the intake form's own — opens the same screen, titled **Scan
core**, with a **Live / Document** selector at the top.

- **Live** uses VisionKit's `DataScannerViewController` for barcodes, and also highlights printed
  text. Highlighted text does nothing until the user taps a specific line — the camera never
  chooses for them.
- **Document** uses `VNDocumentCameraViewController` for an invoice or a return receipt: it finds
  the page edges, flattens the page, and allows several pages.

Both run entirely on device, and **neither can create or change a record**. Everything they read
becomes a *suggestion* on a confirmation screen, in editable fields, with the raw reading shown
underneath it; only values the user ticks are copied into the form, and only the form's own **Save**
writes anything. Values the app is not confident about start switched **off**.

**In the Simulator** neither camera exists. The app detects this rather than failing: Live shows a
manual-entry field and a "Use sample barcode" button, and Document says plainly that this device has
no document camera. No camera permission is requested in either case, and nothing is blocked. The
same fallbacks appear if camera access is denied or the hardware is unsupported — scanning is always
optional, and every field can be typed by hand.

**Restoring a backup**

Settings → Data & export → **Restore from backup** reads a JSON backup the app itself wrote. It
is a **replace-all** operation, stated in those words before it runs: the file is decoded and
checked first, a summary of what it contains is shown alongside how much is on the device now, and
nothing is deleted until that is confirmed. An empty, damaged, non-CoreCredit, or newer-format file
is refused and nothing changes. A failed restore rolls back and leaves the existing records intact.

Evidence photographs are **not** stored in a backup file and are not restored; the app says so in
the footer, in the confirmation, and in the bundled Local Data and Backup document. The device's
own notification settings are kept rather than overwritten, because the file does not carry them.

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
| `com.blakekimble.corecredit.pro.monthly` | US $14.99 / month |
| `com.blakekimble.corecredit.pro.annual`  | US $119.99 / year |

Prices shown in the app are read from StoreKit and are never hard-coded.
**Restore Purchases** and **Manage Subscription** are both in Settings → Subscription and on the
paywall. There are no external payment links and no steering of any kind.

**The free limit never locks existing data.** A free user who already has records keeps full
access to viewing, editing, adding photos, recording credits, archiving, and exporting them.
The subscription gates only the creation of a *sixth simultaneously unresolved* item.

**Permissions**

CoreCredit asks for exactly two things. Each is requested only after a deliberate action, each has
a working alternative, and neither blocks any other part of the app.

- **Camera — where the prompt is reached.** **Dashboard → Scan core** (the Home Screen widget, the
  "Scan core" Shortcut / Action Button, and the intake form's own scan button all open the same
  screen). On a device that has never been asked, that screen shows a short explanation —
  *"CoreCredit uses the camera to scan barcodes. Continue to the iOS permission request, or type
  the number below."* — above a single button labelled **Continue**. Pressing Continue is what
  presents the iOS camera alert. Nothing before that point touches the camera: there is no prompt
  at launch and none during onboarding.
- **The custom action says Continue.** Its visible label and its accessibility label are both
  "Continue"; the accessibility hint states that it opens the iOS camera permission alert. The same
  is true of the notification screen described below. Neither pre-permission screen uses Allow,
  Enable, Grant, or Yes, and neither imitates or pressures the affirmative choice in Apple's dialog.
- **Manual entry remains available.** The "Type it in" field and its **Use this number** button are
  on that same screen in *every* state, including this one. A reviewer who declines camera access,
  or who never presses Continue at all, can type a part number and carry on through the whole flow.
  Scanning is a convenience, never a requirement.
- **Recovering a declined permission.** iOS offers its alert once per install, so a user who has
  already declined is never asked again. The screen says so plainly and offers **Open Settings**,
  which deep-links to CoreCredit's own page in the Settings app, where camera access can be turned
  back on. Where the camera is restricted by MDM or parental controls, no request action is offered
  at all, because none could succeed — only the explanation and manual entry.
- **Notifications follow the same neutral pattern.** Requested only from **Settings →
  Notifications**, and only by an intentional action: turning on "Remind me about core deadlines",
  or pressing the **Continue** button in that screen's Permission section. Opening Settings, or the
  Notifications screen itself, only *reads* the current status and never prompts. A device that has
  already denied notifications is offered **Open the Settings app** instead of a second request.
  Notifications are not required to use any other part of CoreCredit.
- The app does **not** request Photo Library access (it uses `PhotosPicker`, which does not
  require it), and does not use location, contacts, calendar, microphone, Bluetooth, tracking,
  or background modes.

**What changed in this build** (in response to submission `c53826ac-ebd3-4cc4-9ef5-df185143a175`)

The previous build's camera pre-permission button was labelled "Allow camera access" and was
rejected under guideline 5.1.1(iv). It now reads **Continue**, as recommended. The notification
screen's equivalent button carried the same shape of wording and was changed to **Continue** in the
same pass. Nothing else changed: camera access is still requested only after the user opens Scan
core and presses Continue, manual barcode entry still works without it, and a user who previously
declined is still offered a link to Settings rather than another prompt. No data is transmitted by
the scanning feature — barcode and document recognition run entirely on device.

**Privacy**

No analytics SDK, no advertising SDK, no third-party SDK of any kind, and no network calls to
any developer-operated server. The only network activity is Apple's own StoreKit traffic for
subscriptions. The privacy manifest is included at
`CoreCredit/Resources/PrivacyInfo.xcprivacy`, declaring no tracking and no collected data
types. See `docs/PRIVACY.md`.

**Not financial advice**

The About screen states plainly that CoreCredit is an organisational record — not accounting
advice, and not a guarantee that any vendor will honour a return.
