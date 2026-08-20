# Releasing CoreCredit

The one page that says what builds what, and in which order a release happens.

If this file and `codemagic.yaml` ever disagree, `codemagic.yaml` wins and this file is wrong —
fix it.

---

## 1. The three workflows

| Workflow | Starts | Signs | Publishes |
|---|---|---|---|
| `corecredit-simulator-build` | **automatically**, every push and every pull request, all branches | no | no |
| `corecredit-release-archive` | **by hand only** | yes | **no** |
| `corecredit-testflight` | **by hand only** | yes | **yes — App Store Connect / TestFlight** |

### Why publishing is manual

`corecredit-testflight` used to trigger on every push to `main`. That made *merging* a release
action: a documentation fix, an audit, a typo — anything landing on the shipping branch uploaded a
build to TestFlight, advanced the build number, and sent testers something nobody had decided to
release.

Gating should be automatic. Publishing should be a decision. The `triggering:` block is gone from
that workflow, and `scripts/verify_repository.py` now fails if **any** workflow both triggers
automatically and carries a `publishing:` section. That invariant exists because re-adding a
trigger breaks nothing, warns nobody, and is only noticed by testers receiving a build.

### One owner check, once

`codemagic.yaml` is not the only place a trigger can live. In Codemagic, open
**Applications → CoreCredit → `corecredit-testflight`** and confirm no automatic build trigger is
configured in the UI either. If one is, the change above is cosmetic. Do the same for
`corecredit-release-archive`.

---

## 2. Before the first signed archive ever succeeds

**Register the widget extension's App ID and provisioning profile — one time, in the Developer
portal.** This is the only step that blocks a signed archive outright; without it the build fails
with *"CoreCreditQuickScanWidget requires a provisioning profile"*.

Codemagic's managed signing takes exactly one `bundle_identifier` and creates the App ID and
profile for that one only, so the embedded extension is not covered.

1. <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles** →
   **Identifiers** → **+** → *App IDs* → *App*
   - Description: `CoreCredit Quick Scan Widget`
   - Bundle ID: **Explicit**, `com.blakekimble.corecredit.widget`
   - Enable no capabilities — the widget needs none.
2. **Profiles** → **+** → *App Store Connect* (distribution) → select that App ID → the same
   distribution certificate the app uses → Generate.

Nothing needs downloading. Codemagic matches profiles by bundle-identifier prefix, so once the
profile exists, `bundle_identifier: com.blakekimble.corecredit` picks up both the app and the
extension.

The **Apply App Store signing** step prints every installed profile with its application
identifier. Both of these must appear, prefixed with team id `7GNFT94A9L`:

```
com.blakekimble.corecredit
com.blakekimble.corecredit.widget
```

A missing widget line means the profile above does not exist yet. That is the difference between
"the portal is not set up" and "the configuration is wrong", which the archive error itself never
distinguishes.

---

## 3. The release sequence

1. **Land the work.** Open a pull request. `corecredit-simulator-build` runs on it: repository
   invariants, a Debug build of the app *and* the widget, the full unit suite, the full UI suite.
   It gates on all four. Merge only when it is green for the exact head being merged.

2. **Prove the archive.** Start `corecredit-release-archive` by hand against `main`.

   It runs the invariants, builds **Release** for the simulator (the configuration that actually
   ships, which the Debug-only gate never exercises), applies App Store signing, builds a signed
   `.ipa`, and then inspects it: bundle identifiers, version and build number, the privacy
   manifest, the app icon, the embedded `.appex`, code signature and entitlements — and it fails
   if a `.storekit` configuration file has somehow ended up inside the bundle.

   It uploads nothing and does not advance the build number. Read the inspection output; that is
   the archive evidence.

3. **Cut the TestFlight build.** Start `corecredit-testflight` by hand.

   This one *does* set a build number (`agvtool new-version -all "$PROJECT_BUILD_NUMBER"`) and
   *does* upload to App Store Connect. Starting it is the act of releasing to testers.

4. **Accept on hardware.** Work `docs/DEVICE_ACCEPTANCE.md` on a real iPhone, and on an iPad for
   the layout sections. Everything camera-, notification-, and StoreKit-shaped can only be
   established here — see the "not executed anywhere" table in `docs/HANDOFF.md`.

5. **Submit.** `docs/APP_STORE_REVIEW_NOTES.md` for the review notes,
   `docs/APP_STORE_PRIVACY_ANSWERS.md` for the privacy questionnaire.

---

## 4. Versioning

- `MARKETING_VERSION` (`1.0`) is edited in the Xcode target. It is the version customers see.
- `CURRENT_PROJECT_VERSION` is overwritten by `corecredit-testflight` with the Codemagic build
  index, so build numbers are unique and monotonic without anyone editing the project file.
- `corecredit-release-archive` deliberately does **not** set one. Burning a build number to answer
  "does it sign?" makes the next real TestFlight build's number misleading.
- No version string is hard-coded in Swift. `AppConfiguration.appVersion` and `.buildNumber` read
  the bundle at runtime.

---

## 5. Testing subscriptions, and what the dates mean

CoreCredit sells two auto-renewable subscriptions in one group:

```
com.blakekimble.corecredit.pro.monthly
com.blakekimble.corecredit.pro.annual
```

They must exist in App Store Connect, in one subscription group, and reach **Ready to Submit**.
A missing or misnamed product fails *silently*: `Product.products(for:)` returns nothing, and the
paywall shows its retry state, which looks like a network problem rather than a configuration one.

**Subscription periods are accelerated everywhere except production.** Apple's own numbers:

- **Sandbox Apple Account** — the default speed equalization is *1 month = 5 minutes*, and a
  subscription auto-renews up to 12 times before auto-renewal turns off.
  ([Manage Sandbox Apple Account settings](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/manage-sandbox-apple-account-settings/))
- **TestFlight, ordinary account** — *every* duration renews in 1 day, 6 times, then stops.
  ([Testing subscriptions in TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/subscription-renewal-rate-in-testflight/))
- **Xcode with `StoreKit/CoreCredit.storekit`** — the scheme's Run and Test actions reference the
  local configuration, whose renewal rate is set in the StoreKit configuration editor. The Archive
  action does not reference it, which is why no `.storekit` file can reach a shipping build.

So a monthly plan bought in a test environment shows a period ending minutes or hours later, on
the same day or the next one. **That is correct, and it is not a CoreCredit bug.** Apple's
Subscriptions screen words it "Renews <date>"; CoreCredit's own Settings → Subscription screen
says "Current period ends" (or "Current period ended"), formats
`StoreKit.Transaction.expirationDate` verbatim, and never computes a renewal date.
`CoreCreditTests/SubscriptionPeriodPresentationTests.swift` holds that behaviour in place.

To see a real monthly period, you need a production purchase.
