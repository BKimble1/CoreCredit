# CoreCredit — handoff

## 1. The one thing to know first

This repository is authored on a Windows machine with **no Swift toolchain** — `swift`,
`swiftc`, `xcodebuild`, and `xcrun` are all absent on the build host. Codemagic performs every
authoritative build. Every claim below distinguishes what was *verified* from what was
*reasoned about*.

### Build status, precisely

| Thing | State |
|---|---|
| App target, Debug, iOS Simulator | **compiles** |
| `CoreCreditQuickScanWidget` extension | **compiles** — the app depends on it and embeds the `.appex`, so a widget error fails the build |
| App + extension install and launch on a simulator | **yes** |
| `CoreCreditTests` / `CoreCreditUITests` targets | **compile** |
| Unit test suite | **260 tests in 23 suites, all passing** (`corecredit-simulator-build`) |
| UI test suite | **never run** — not wired into either workflow |
| Release archive / device build / signing | **blocked** on the widget App ID, §2 item 0 |

The architecture, the data model, the money arithmetic, and the business rules are now backed by
a compiler *and* by an executed test suite. Two things are still unproven: nothing has run on real
hardware, and no UI test has ever executed, so every claim about layout, Dynamic Type, VoiceOver,
camera behaviour, and notification delivery remains reasoning rather than evidence.

### The final UX pass — what it changed, and what that leaves unproven

A contained interface pass reworked appearance, bottom safe-area behaviour, empty-state density,
the Add Core form, and the capture entry points. It changed **no** domain rule: money is still
`Int64` cents through `Money`/`Decimal`, scanning and OCR still write nothing, every captured value
still enters an unsaved `CoreItemDraft` and requires review plus Save, only `.high` candidates still
start selected, the free tier still gates only the creation of a sixth unresolved core, and
`CoreItemService` / `ReturnBatchService` are still the only mutation paths.

What it changed that a person has to look at:

- **Light appearance is now the primary case.** `Palette.surface` is white in light so cards need no
  outline; every card stroke is gone, corner radii dropped to 10, and vertical padding shrank.
  Neither appearance has been seen on a screen.
- **The bottom safe-area bug is fixed structurally, not by a magic number.** Every root and pushed
  screen used `ZStack { Palette.background.ignoresSafeArea(); ScrollView { … } }`, which grows the
  stack past the tab bar's inset and takes it away from the scroll view. The background is now
  painted behind instead. **This has not been seen running**, and it is the single change most
  worth checking first on a device.
- **Capture is one entry point over two engines.** Same sheet, titled "Scan core", with a Live /
  Document selector; switching swaps `CoreEditorModel.Route` so only one sheet is ever up. Live now
  also recognises text, delivered **only** on a tap. **No part of this has run against a camera.**
- **The editor has one Save**, pinned in a bottom bar, and its optional sections fold away while
  they are empty. Keyboard avoidance of that bar is untested.
- **`DocumentScanSheet` now checks `DocumentScannerView.isSupported` before presenting the document
  camera.** It did not before, which means the Simulator and unsupported hardware were being handed
  a `VNDocumentCameraViewController` that cannot run there. That path was previously unreachable
  from the main scan entry; it is reachable now, which is why the check was added.
- **The app has a load-in screen.** `UILaunchScreen` paints the brand blue and the white mark before
  any Swift runs — that is what removes the white flash — and `LaunchSplashView` fades the same
  picture, gradient-lit, out of the way. `INFOPLIST_KEY_UILaunchScreen_Generation` was removed from
  both app build configurations; **it must stay off**, because it merges an empty dictionary over
  the real one and the only symptom is the flash coming back. See `docs/CONTRACTS.md` §7b.

### Both appearances are retuned, and a bug that was caught by being asked about

The first cut of this pass moved **only the light halves** of `Palette`. Dark was byte-for-byte
unchanged — while the card outlines were removed in *both* appearances. That left dark-mode cards
with nothing separating them from the background at all: 1.099:1, which is a card you cannot see.
It did not fail, did not warn, and looked from a dark-mode device exactly like no work had been
done.

Dark now has its own retune, to the same relationship light has: a deeper ground (`#080B12`) and a
clearly lifted card (`#18202E`), giving **1.204:1** — better separation than light's 1.151:1.
`surfaceElevated`, `hairline`, `textPrimary`, and `textSecondary` moved with it.

The same measurement found a second, pre-existing defect: `hairline` at 1.36:1 was doing duty as
both a row separator *and* the edge of every text field, and WCAG 1.4.11 wants 3:1 on the boundary
that identifies a control. `Palette.fieldBorder` now carries that job at 3.35:1 (light) and 3.36:1
(dark) across twelve input sites; `hairline` stays faint for separators.

**`CoreCreditTests/PaletteThemeTests.swift` measures all of it** — surface separation, 4.5:1 for
every foreground and every status colour on a card, 4.5:1 for text on a solid status fill, 3:1 for
the field border, Increase Contrast never making anything worse, and every token genuinely
differing between the two schemes — in four appearances (light, dark, and each with Increase
Contrast). That suite exists because a screenshot would have caught the original bug in one second
and there is no screenshot: this repository is built on a machine with no simulator.

### What was actually verified

| Check | Tool | Result |
|---|---|---|
| `project.pbxproj` parses as a valid old-style plist | custom parser | pass — 39 objects |
| Every object ID referenced is defined and reachable from `rootObject` | custom parser | pass — no dangling or orphaned IDs |
| Required keys present per `isa` type | custom parser | pass |
| `CoreCredit.xcscheme` is well-formed XML | `xml.dom.minidom` | pass |
| `CoreCredit.storekit` is valid JSON with both products in one group | `json` | pass |
| Asset catalog `Contents.json` files are valid JSON | `json` | pass |
| Brace/paren/bracket balance, string- and comment-aware | custom Swift scanner | pass — all files |
| Banned constructs: `fatalError`, `try!`, `as!`, force unwrap, `TODO` | custom Swift scanner | pass — zero occurrences |
| `OurType.member` references resolve to a declared member | custom Swift scanner | pass — 3 flagged, all false positives (wrapped `case` lists, a nested enum) |
| Framework imports present for the APIs each file uses | custom Swift scanner | pass — 2 flagged, both false positives (string literals) |
| Layering: `Domain/` imports only `Foundation` | custom Swift scanner | pass |
| Cross-file call sites match their declarations | full read-through audit | pass — no blockers across 16 seams |
| Duplicate top-level declarations | full read-through audit | pass — 204 types, 204 distinct names |
| `switch` exhaustiveness over 15 enums | full read-through audit | pass — 59 switches, all exhaustive or defaulted |
| Protocol conformance completeness + actor isolation | full read-through audit | pass |

### What could NOT be verified

- **The UI test suite.** The 8 UI-test files have never executed — neither workflow runs them,
  because they drive a full simulator session and belong in a longer job. Their assertions were
  written against real accessibility identifiers, but none has been evaluated. That now includes
  `CaptureAndLayoutUITests`, which is the suite that would prove the tab-bar and unified-capture
  claims above; until it runs, those claims are reasoning.
- **Every screenshot in the review matrix.** No screenshot of this build exists, in either
  appearance, at any Dynamic Type size, on any device. Light mode, Dark mode, iPad regular width,
  and the accessibility text sizes have all been reasoned about and none has been looked at.
- **Anything on real hardware.** The camera and scanner path, notification delivery, widget
  rendering on a Home Screen, Siri and Action Button entry, and StoreKit purchases have only ever
  run against stubs or not at all.
- **Runtime behaviour**, layout, Dynamic Type reflow, VoiceOver output, PDF rendering, QR
  scannability, and StoreKit purchase flows.
- **Code signing and device install.**

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
