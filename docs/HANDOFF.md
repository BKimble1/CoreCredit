# CoreCredit — handoff

## 1. The one thing to know first

**This repository has never been compiled.** It was authored end-to-end on a Windows machine
with no Swift toolchain — `swift`, `swiftc`, `xcodebuild`, and `xcrun` are all absent on the
build host. Every claim below distinguishes what was *verified* from what was *reasoned about*.

Expect a first build on a Mac to surface some compile errors. They should be small and local —
a wrong argument label, a renamed SwiftUI modifier, an `iOS 18` API spelled the way it was in a
beta. What should *not* be wrong is the architecture, the data model, the money arithmetic, or
the business rules; those were specified up front in `docs/CONTRACTS.md` and cross-checked.

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

- **Type checking and compilation.** No compiler ran. Generic inference, overload resolution,
  `@Observable` macro expansion, SwiftData macro expansion, and `#Predicate` compilation are all
  unchecked.
- **Any test result.** The 21 unit-test files and 4 UI-test files have never executed. Their
  *assertions* were written against the real implementations, but no assertion has been evaluated.
- **Runtime behaviour**, layout, Dynamic Type reflow, VoiceOver output, PDF rendering, QR
  scannability, and StoreKit purchase flows.
- **Code signing and device install.**

---

## 2. Before TestFlight — owner-supplied values and actions

Everything below is centralised in **`CoreCredit/App/AppConfiguration.swift`** unless noted.

### Required

1. **Apple Developer team — set.** `DEVELOPMENT_TEAM = 7GNFT94A9L` on all six build
   configurations, `CODE_SIGN_STYLE = Automatic`. Nothing to do.
2. **Bundle identifier — set.** `com.blakekimble.corecredit` (plus `.tests` / `.uitests`),
   matching `AppConfiguration.bundleIdentifier` and the Codemagic `ios_signing` block.
   App Store Connect Apple ID `6802336957`.
3. **Subscription product IDs — STILL PLACEHOLDERS.** `com.example.corecredit.pro.monthly` and
   `com.example.corecredit.pro.annual`, subscription group `21500000`. Change in
   `AppConfiguration` **and** in `StoreKit/CoreCredit.storekit`, then create the matching
   auto-renewable subscriptions in App Store Connect in a single group.
   Intended prices: **US $14.99/month** and **US $119.99/year**. These prices live only in the
   `.storekit` file and App Store Connect — there is no price string in any Swift source, by
   design.
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

- **Never compiled or run** — see §1. This is the dominant limitation.

### Scanning (added after the initial build)

- **The scan layer has never run against a camera.** Every symbology list, the `DataScanner`
  pause/resume cycle, `VNDocumentCameraViewController`, haptic timing, and real-world OCR accuracy
  are unverified. The deterministic parts — normalisation, classification, money parsing,
  deduplication, ranking — are unit-tested; the hardware parts are not.
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
