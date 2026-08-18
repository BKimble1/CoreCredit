# CoreCredit — handoff

## 1. The one thing to know first

This repository is authored on a Windows machine with **no Swift toolchain** — `swift`, `swiftc`,
`xcodebuild`, `xcrun`, and every simulator are absent, confirmed again at the start of the final
production sweep. **Codemagic performs every authoritative build.** Nothing below is claimed as
verified unless something actually executed and produced the result.

### What was executed during the final production sweep

| Check | How | Result |
|---|---|---|
| The three public legal URLs resolve over HTTPS, anonymously | `curl` | **pass** — `/support` 200 (7,652 B), `/privacy` 200 (12,448 B), `/terms` 200 (13,622 B) |
| GitHub Pages build for `BKimble1/CoreCredit-Legal` | Pages API | **built** |
| 12 repository invariants | `python3 scripts/verify_repository.py` | **all 12 hold** |
| The SwiftData guard actually catches a non-additive change | simulated a rename of `Vendor.name` | **pass** — failed with the freeze-the-schemas message, file restored |
| Legal pages match their generated source, and carry no tracker | in the invariant script | **pass** |
| Every WCAG ratio in `PaletteThemeTests` and `LaunchScreenTests` | independent implementation of the WCAG 2.1 formulas over the shipping hex | **0 failures** across light, dark, and both with Increase Contrast |
| Brace/paren balance, string- and comment-aware | custom Swift scanner | **pass** — all files |
| Banned constructs (`fatalError`, `try!`, `as!`, `TODO`) | invariant script | **pass** — zero |

### What was NOT executed, and therefore is not claimed

| Thing | State |
|---|---|
| Compiling any of the code written in this sweep | **not done** — no toolchain on this machine |
| `CoreCreditTests` | **not run in this sweep** |
| `CoreCreditUITests` | **still never executed anywhere** |
| Signed archive | **not produced** |
| TestFlight upload | **not performed** |
| Any screenshot of the running app | **none exists** |

The last authoritative *compile* was Codemagic's build of an earlier commit on `main`
(260 unit tests in 23 suites, all passing). Everything added since — the whole UX pass, the
appearance rework, the launch screen, backup restore, the barcode card, and the new test suites —
**has never been through a compiler.** Treat a first Codemagic run on this branch as the real
smoke test, and expect the usual first-compile class of error: SwiftUI modifier spellings, actor
isolation, and SwiftData API details.

### Why nothing was merged

The brief for this sweep says not to merge until the branch compiles and the complete automated
suite passes. Neither could be established from here: this machine has no toolchain, no Codemagic
API token is present, and GitHub reports **zero check runs** on the repository, so CI can neither
be triggered nor observed. Merging would have meant asserting a gate that had not been evaluated.
`main` is also wired to publish to TestFlight on push, so a merge is a release action, not an
integration one.

**The smallest owner action that unblocks everything:** open Codemagic, run
`corecredit-simulator-build` against `ux/final-polish-pass`, and fix or report what it says. That
workflow now runs the unit suite *and* the UI suite and gates on both.

---

## 2. Before TestFlight — owner-supplied values and actions

Everything below is centralised in **`CoreCredit/App/AppConfiguration.swift`** unless noted.

### Required

0. **Register the widget's App ID and provisioning profile — one time, in the Developer portal.**
   This is the only step in this list that blocks the TestFlight archive outright. Without it the
   build fails with *"CoreCreditQuickScanWidget requires a provisioning profile"*.

   Codemagic's managed signing (`ios_signing` in `codemagic.yaml`) takes exactly one
   `bundle_identifier` and creates the App ID and profile for that one only, so the embedded
   extension is not covered. Fetching signing files per target from a script does not work either:
   `app-store-connect fetch-signing-files` also wants to install a *certificate*, and fails with
   *"Cannot save Signing Certificates without certificate private key"* because that key lives in
   Codemagic rather than in this repository.

   Do this once:

   1. <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles** →
      **Identifiers** → **+** → *App IDs* → *App*
      - Description: `CoreCredit Quick Scan Widget`
      - Bundle ID: **Explicit**, `com.blakekimble.corecredit.widget`
      - Enable no capabilities — the widget needs none.
   2. **Profiles** → **+** → *App Store Connect* (distribution) → select that App ID → pick the
      same distribution certificate the app uses → name it something like
      `CoreCredit Quick Scan Widget App Store` → Generate.

   Nothing needs to be downloaded. Codemagic matches profiles by bundle-identifier prefix, so once
   this profile exists the existing `bundle_identifier: com.blakekimble.corecredit` picks up both
   the app and the extension on the next build.


1. **Apple Developer team — set.** `DEVELOPMENT_TEAM = 7GNFT94A9L` on all six build
   configurations, `CODE_SIGN_STYLE = Automatic`. Nothing to do.
2. **Bundle identifier — set.** `com.blakekimble.corecredit` (plus `.tests` / `.uitests`),
   matching `AppConfiguration.bundleIdentifier` and the Codemagic `ios_signing` block.
   App Store Connect Apple ID `6802336957`.
3. **Subscription product IDs — SET.** `com.blakekimble.corecredit.pro.monthly` and
   `com.blakekimble.corecredit.pro.annual`, matching in `AppConfiguration` and
   `StoreKit/CoreCredit.storekit`. The matching auto-renewable subscriptions must exist in App
   Store Connect in one group and reach **Ready to Submit**, or StoreKit returns nothing and the
   paywall shows its retry state — a missing product is silent, never an error.
   Prices: **US $14.99/month** and **US $119.99/year**, held only in the `.storekit` file and App
   Store Connect. There is no price string in any Swift source, by design.
   `subscriptionGroupIdentifier` is still the local `.storekit` number; nothing reads it.
4. **Support / privacy / terms URLs.** All three point at `example.com`. The About screen
   visibly marks them as placeholders; replace them with live pages.
5. **App icon — supplied.** `AppIcon.appiconset/AppIcon.png` is real 1024×1024 artwork
   (opaque, no alpha channel, metadata stripped) and `Contents.json` references it. Nothing is
   required here before submission; replace the PNG in place if the branding changes.
6. **Support email.** `AppConfiguration.supportEmail` is `support@example.com`.

### Recommended

7. **Review the working name.** "CoreCredit" is a working name. Display name is
   `INFOPLIST_KEY_CFBundleDisplayName` plus `AppConfiguration.displayName`.
8. **Verify the StoreKit scheme reference.** `StoreKit/CoreCredit.storekit` is wired into the
   shared scheme's Run and Test actions by a relative path. If Xcode does not pick it up, set it
   at *Edit Scheme → Run → Options → StoreKit Configuration*.
9. **App Store privacy answers** — draft in `docs/PRIVACY.md`. Re-check against the shipped
   build.
10. **Review notes** — draft in `docs/APP_STORE_REVIEW_NOTES.md`, including how to reach the
    paywall and how the scanner behaves in the Simulator.

---

## 3. Known limitations

Honest and specific. Nothing here is a P0 gap.

### Environment-constrained

- **Authored without a Swift toolchain** — every build and test run happens on Codemagic. The unit
  suite passes there; see §1 for exactly what that does and does not cover.

### Scanning (added after the initial build)

- **The scan layer has never run against a camera.** Every symbology list, the `DataScanner`
  pause/resume cycle, `VNDocumentCameraViewController`, haptic timing, and real-world OCR accuracy
  are unverified. The deterministic parts — normalisation, classification, money parsing,
  deduplication, ranking — are unit-tested; the hardware parts are not.
- **Live text recognition is the newest unverified thing in that layer.** `recognizesText: true`
  adds `.text()` to the recognised data types and turns on `recognizesMultipleItems`. Whether the
  barcode decode rate holds up with both active, how crowded the highlights look on a real invoice,
  and whether a tap reliably lands on the intended line are all questions only a camera can answer.
  The safety rule is enforced in code rather than by tuning: text is delivered from `didTapOn`
  only, never from `didAdd`, so nothing can be captured that a person did not point at.
- **Diagnostics are in-memory and hold only the most recent session.** They are deliberately not
  persisted, so a crash loses them. That is the privacy trade-off: nothing to leak, nothing to
  upload, and no image bytes are ever recorded.
- **`draft.scannedBarcodeValue` round-trips but has no editor UI.** It is stored, shown in
  diagnostics, and preserved across an edit, but there is no field to view or clear it directly.
- **Schema versioning is additive-only, and now guarded.** The decision was deliberate: freezing
  the historical schemas is a seven-model refactor whose correctness can only be shown with real
  migration fixtures on a Mac, and doing it unproven immediately before release is a worse risk
  than the one it removes. Instead the persisted shape of all seven `@Model` types is pinned in
  `scripts/swiftdata-model-manifest.json`, and any rename, retype, or removal fails CI with
  instructions to freeze the historical schemas first. Additive changes update the manifest in the
  same commit. Original note follows.
- **Schema versioning is additive-only.** `CoreCreditSchemaV1.models` returns the live model types,
  so V1 and V2 describe identical entities and the lightweight stage is a structural no-op.
  Existing stores open correctly because the change is purely additive, but the plan cannot express
  a future rename or retype. Freeze V1's models into nested copies before the first non-additive
  migration. Documented in `docs/SCAN_CONTRACTS.md` §12.
- **`ScanMoneyParser.moneyTokens(in:)` is unreferenced in production** — the ranking path uses the
  extractor's own tokeniser and calls `ScanMoneyParser.parse` for the ambiguity guard.
- **UI tests mirror the accessibility identifiers.** A UI test bundle runs out of process and
  cannot import the app module, so `CoreCreditUITests/UITestSupport.swift` carries a verbatim
  copy of the `A11y` strings. Renaming an identifier in the app will **not** cause a compile
  error — it will cause a query that never resolves. Keep the two in sync by hand.

### Closed in the final production sweep

- **JSON backup import.** Implemented. `BackupRestoreService` validates before it deletes and
  rolls back on failure; Data & export offers Restore from backup. Two honest limits, stated in
  the UI and in the legal documents: evidence photos are not in the format, and reminder
  preferences are not either (the device's own settings are carried across instead).
- **`draft.scannedBarcodeValue` had no editor UI.** Core detail now shows a Barcode card with
  copy and clear-with-confirmation, routed through `CoreItemService` so the clear lands in the
  timeline.
- **The `Calendar.current` leak in the ledger PDF.** `makeLedgerPDFData` now takes the calendar as
  a required parameter.
- **The A11y mirror could drift silently.** `scripts/verify_repository.py` compares the app's
  identifiers with the UI-test target's hand-copy, string for string, and runs first in CI.
- **The UI suite had never executed.** Wired into `corecredit-simulator-build`, which now also
  triggers on every push and pull request. It has still never *passed*, because it has still never
  been run — see §1.

### Deliberately out of scope for Version 1

Per the brief, none of these are implemented and none should be added casually: customer
invoicing, repair orders, estimating, payments, bookkeeping, inventory purchasing, dispatch,
messaging, payroll, CRM; vendor/accounting/shop-management integrations; multi-user or
multi-location accounts; CloudKit sharing or any sync backend; AI chatbot or probabilistic
eligibility decisions; Android/web clients; remote push notifications; background location;
complex charts or gamification.

Also not implemented, and explicitly not P0:

- **Optional local app lock** (LocalAuthentication). The brief lists it as post-P0 only.
- **JSON backup import.** `JSONBackupExporter.decode` exists and is tested, and the format is
  documented, but there is no restore-from-backup UI. Export is P0; import was not requested.
- **One currency per shop.** `ShopProfile.currencyCode` stores a single code; display formatting
  is locale-aware. Multi-currency ledgers are not supported.
- **No localisation.** English only, though all formatting is locale-aware and
  `LOCALIZATION_PREFERS_STRING_CATALOGS` is on, so adding a string catalog later is clean.
- **One injected-clock leak.** `DisputePacketBuilder.makeLedgerPDFData` uses the injected
  `DateProvider` for its totals, but pins `Calendar.current` internally for the red tinting of
  overdue rows. The numbers are deterministic; the row colouring on that one report is not.
  Fixing it needs a signature change on that builder.
- **The reminder body is deliberately locale-formatted.** `ReminderPlanner`'s fire-date decision
  is fully deterministic, but the money inside the notification text uses `Locale.current`,
  because a person reads it. Tests assert it through `Money.formatted(currencyCode:)` rather
  than a hard-coded `"$86.50"`.

### Design decisions worth knowing

- **A returned item stays in "Money at risk".** Returning a core does not reduce exposure — only
  a recorded credit does. This is intentional and is the product's central claim.
- **A returned-but-uncredited item past its due date still reads as overdue.** `dueDate` means
  "the date by which this should have been settled", so late money stays visible.
- **Recording a $0.00 credit is allowed** and produces a full-value dispute. That is how "the
  vendor never credited me" is recorded. Empty or unparseable input is still a validation error.
- **A batch is one vendor, by construction**, and the service rejects a mixed batch as well.
- **Deleting a vendor or bin does not delete cores.** Relationships nullify; the cores survive
  and become vendor-less. The confirmation copy says so.
- **The free limit counts unresolved items only.** Credited and written-off items never count,
  so a shop that keeps its ledger clean can stay on the free tier indefinitely.
- **OCR never auto-commits.** `OCRSuggestionExtractor` returns suggestions; the UI shows them in
  editable confirmation fields. There is no code path that writes a recognised value directly to
  a record.
- **`makeAppContainer` can return `nil`**, and that is a presentable state (`StoreUnavailableView`
  offers Try again and Reset local data) rather than a crash or a hang.

---

## 4. If the first build fails

Work in this order — it matches where risk actually concentrates:

1. **Fix the app target first**, then the unit tests, then the UI tests. The test targets
   reference far more app API than the reverse.
2. **Most likely error class: SwiftUI modifier and initialiser spellings** in `Features/`. These
   are mechanical.
3. **Second: SwiftData macro details** — `#Predicate` capture rules and `SortDescriptor`
   key-path forms in `Services/CoreItemService.swift`.
4. **Third: StoreKit 2 surface** in `Services/StoreKitSubscriptionEngine.swift` —
   `Product.SubscriptionInfo.Status`, `RenewalState`, and `AppStore.showManageSubscriptions(in:)`
   were the least verifiable calls in the codebase.
5. `Domain/` and `Models/` are the least likely to be wrong: pure Foundation, specified in
   advance, and the most heavily cross-checked.

`docs/CONTRACTS.md` records the intended signature for every cross-layer symbol. If a call site
and a declaration disagree, that file is the tie-breaker.
