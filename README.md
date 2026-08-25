# CoreCredit

**Know exactly how much core-credit money is still at risk.**

CoreCredit is a local-first parts-core return and vendor-credit ledger for owner-operated
one-to-five-bay auto, diesel, collision, and equipment-repair shops that do not have usable
core tracking in an expensive shop-management suite.

It does one narrow, financial job:

1. A replacement part arrives with a refundable core charge.
2. The shop preserves and identifies the old part, often in the correct box.
3. Someone returns it to the correct vendor before the deadline.
4. A receipt or return reference is retained.
5. The item stays **open** until the expected vendor credit actually appears.
6. Short, missing, and overdue credits are visible and provable.

It is **not** a repair-order system, accounting product, inventory manager, vendor
marketplace, or AI chatbot, and it should not be broadened into one.

---

## Open in Xcode

```
Project:  CoreCredit.xcodeproj   (repository root)
Scheme:   CoreCredit
Target:   iOS 18.0+ (iPhone-first, adapts to iPad)
Requires: Xcode 16 or later
```

Open `CoreCredit.xcodeproj`, select the **CoreCredit** scheme and any iOS 18 simulator, and run.
No package resolution, no CocoaPods, no signing setup is needed for a simulator build.

The project uses Xcode 16 **synchronized folder groups** (`PBXFileSystemSynchronizedRootGroup`,
`objectVersion = 77`), so files added to `CoreCredit/`, `CoreCreditTests/`, or
`CoreCreditUITests/` on disk are picked up automatically — there is no file list to maintain
inside `project.pbxproj`.

### StoreKit in development

`StoreKit/CoreCredit.storekit` is checked in and already referenced by the shared scheme for
both the **Run** and **Test** actions. If Xcode does not pick it up, set it manually at
*Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration*.

---

## Repository layout

```
CoreCredit/
  App/          app entry, AppEnvironment, launch options, root/tab shell, AppConfiguration
  Models/       SwiftData @Model types, versioned schema, migration plan, container factory
  Domain/       pure Foundation-only value types and calculations (no SwiftData, no SwiftUI)
  Services/     side effects: persistence mutations, StoreKit, Vision, notifications, exports
  Components/   design tokens and shared views
  Features/     Onboarding · Dashboard · Cores · Capture · Returns · Settings · Paywall
  Resources/    Assets.xcassets, PrivacyInfo.xcprivacy
CoreCreditTests/     Swift Testing unit suites
CoreCreditUITests/   XCTest UI smoke suites
StoreKit/            CoreCredit.storekit (local StoreKit configuration)
docs/                CONTRACTS.md · HANDOFF.md · RELEASE.md · APP_STORE_REVIEW_NOTES.md · PRIVACY.md
```

`docs/CONTRACTS.md` is the authoritative API contract for the codebase and is worth reading
before making a change that crosses a layer boundary.

---

## Architecture in one page

**Money is never a `Double`.** It is `Money`, an `Int64`-cents value type. Parsing and
formatting go through `Decimal`; CSV and JSON exports carry integer cents or an exact
`"86.50"` string. There is no floating-point arithmetic anywhere in a financial path.

**Domain is pure.** `CoreCredit/Domain/` imports only `Foundation`. Status transitions
(`CoreStatusMachine`), exposure and aging (`RiskCalculator`), due dates (`DueDateCalculator`),
reconciliation (`CreditReconciler`), the free-tier rule (`EntitlementPolicy`), and search and
filtering (`CoreItemQuery`) are all plain functions over a `CoreItemRepresenting` protocol.
Both the SwiftData `CoreItem` and the `Codable` `CoreItemExportSnapshot` conform, so every
calculation is unit-testable with no store and no rendering.

**Time is injected.** Nothing in a calculation calls `Date()` or `Calendar.current`; they take
a `DateProvider`. `SystemDateProvider` in the app, `FixedDateProvider` in tests. That is what
makes due-date and aging-bucket boundaries deterministic.

**All writes go through two services.** `CoreItemService` and `ReturnBatchService` own every
mutation, so the append-only `CoreEvent` timeline can never be bypassed and status changes are
always validated by `CoreStatusMachine` first.

**Side effects sit behind small protocols** — `SubscriptionEngine`, `NotificationScheduling`,
`TextRecognizing` — each with a real implementation and a deterministic stub selected by
`LaunchOptions`. There is no Redux, no Combine pipeline, no coordinator layer, and no DI
framework; feature state is `@Observable`, persistence is `@Query`/`ModelContext`.

**The bright scheme is the app icon.** `Palette.accent` is `#0053FD` — the icon's own blue, which
happens to carry text on white (5.74:1) *and* take white text on itself (5.74:1), so one value
serves as both a label and a fill. The light ground is that hue washed almost to white. Amber is no
longer the action colour; it survives as "ready to return" only, private behind `color(for:)`.
CoreCredit **opens in Light** and the appearance is changed at **Settings → Appearance** — the one
place in the app that forces a `ColorScheme`. Every surface separation and contrast ratio, in both
schemes and with Increase Contrast, is measured by `CoreCreditTests/PaletteThemeTests.swift` rather
than eyeballed, because this repository is built on a machine that cannot take a screenshot.

**Capture is one entry point over two engines.** The Quick Scan widget, the App Shortcut and the
Action Button, the Dashboard's Scan core button, and the intake form's own all open the same sheet,
titled **Scan core**, with a Live / Document selector at the top. Live is
`DataScannerViewController` (barcodes, plus text that is highlighted and only ever *tapped*);
Document is `VNDocumentCameraViewController` (page-edge detection and perspective correction for an
invoice). The engines stay separate on purpose — they frame and fail differently — and choosing a
mode swaps `CoreEditorModel.Route` so exactly one capture sheet is ever presented. Neither can
write: everything lands in an unsaved `CoreItemDraft` after a confirmation step, and only the
editor's Save creates a record.

### The status model

| Status | Counts as unresolved | Meaning |
|---|---|---|
| Awaiting old core | yes | the core charge is on the invoice, the old part is not in hand yet |
| Ready to return | yes | the old part is boxed and identified |
| Returned — awaiting credit | yes | it went back to the vendor; the money has not |
| Credited | no | the vendor credit actually arrived |
| Disputed | yes | short or missing credit, still being chased |
| Written off | no | deliberately abandoned |

**Money at risk** is the sum of remaining exposure over unresolved items: the full expected
credit, except for a partially credited disputed item, which contributes
`max(0, expected − actual)`. Returning an item does **not** remove it from money at risk —
only a real credit does. That is the entire point of the product.

---

## Tests

```bash
# from the repository root, on a Mac with Xcode 16+
# (`CoreCredit.xcodeproj` sits at the repository root, which is also where CI runs it from)
xcodebuild -project CoreCredit.xcodeproj -scheme CoreCredit \
           -destination 'platform=iOS Simulator,name=iPhone 16' build

xcodebuild -project CoreCredit.xcodeproj -scheme CoreCredit \
           -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Unit tests use **Swift Testing**; UI tests use **XCTest**. UI tests never touch the camera or
live StoreKit — they launch with `-uiTesting`, which forces an in-memory store and
deterministic stubs. See `docs/CONTRACTS.md` §7 for the full launch-argument table.

> **Build status:** this repository is authored on machines with no Swift toolchain, so
> **CI performs every authoritative build**. `.github/workflows/ci.yml` runs on every push and
> every pull request, on every branch: it checks the repository invariants, builds the app *and*
> the embedded widget, then runs the **unit suite and the UI suite** as separate steps and gates
> on both, plus an iPad Air 11-inch smoke check when that simulator is on the runner. Neither
> suite is excluded, quarantined, or allowed to fail.
>
> A result belongs to the commit that produced it. Read it under the repository's **Actions** tab
> for the commit you care about rather than trusting a count written down here.
> `docs/HANDOFF.md` §1 separates what was established without a toolchain, what CI establishes,
> and what only a device or App Store Connect can.
>
> CI is GitHub Actions. `codemagic.yaml` is the previous host, kept for reference and running
> nothing. **This repository is private, so macOS runner minutes are billed** — see
> `docs/RELEASE.md` §2a, because until that is settled no job starts at all.

---

## Before you ship

**`docs/RELEASE.md`** is the authoritative release procedure: which workflow builds, which one
signs, which one publishes, and in what order. The short version is that publishing is never a
side effect — `corecredit-testflight` is started by hand, and a repository invariant fails the
build if any workflow both triggers automatically and publishes.

Identity, product identifiers, and the public addresses are all centralised in
`CoreCredit/App/AppConfiguration.swift` and are set. What is left for the owner — the widget's
App ID and provisioning profile, the two App Store Connect subscriptions, and the App Store
metadata — is listed in **`docs/HANDOFF.md`** §2.
