# Releasing CoreCredit

The one page that says what builds what, and in which order a release happens.

**CI lives in GitHub Actions.** If this file and `.github/workflows/` ever disagree, the workflows
win and this file is wrong — fix it.

`codemagic.yaml` is the previous host. It is kept for reference and no longer runs anything. It can
be deleted at any time; `scripts/verify_repository.py` treats it as optional and its invariants
hold with the file gone.

---

## 1. The two workflows

| Workflow | Starts | Signs | Publishes |
|---|---|---|---|
| `.github/workflows/ci.yml` | **automatically**, every push and every pull request, all branches | no | no |
| `.github/workflows/testflight.yml` | **by hand only** (`workflow_dispatch`) | yes | **yes — App Store Connect / TestFlight** |

### Why publishing is manual

The publishing workflow used to trigger on every push to `main`. That made *merging* a release
action: a documentation fix, an audit, a typo — anything landing on the shipping branch uploaded a
build to TestFlight, advanced the build number, and sent testers something nobody had decided to
release.

Gating should be automatic. Publishing should be a decision. `testflight.yml` therefore has
`workflow_dispatch` and nothing else, and `scripts/verify_repository.py` fails if **any** workflow
— on either CI host — both starts by itself and uploads to App Store Connect. That invariant
exists because adding a trigger breaks nothing, warns nobody, and is only noticed by testers
receiving a build.

The same check bans `testFlightInternalTestingOnly` everywhere. That export flag produces a build
which uploads and reaches internal testers exactly as normal, and which then cannot be selected in
App Store Connect when the version is submitted — the build is simply not in the list, and nothing
looks wrong until that moment.

---

## 2. Before the first signed archive ever succeeds

### 2a. Repository secrets — one time

**Settings → Secrets and variables → Actions → New repository secret.** All five are required;
`testflight.yml` refuses to run without them and names the ones that are missing.

| Secret | Where it comes from |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect → **Users and Access → Integrations → App Store Connect API**. A UUID at the top of the keys list. |
| `APP_STORE_CONNECT_KEY_ID` | The **Key ID** of a key generated on that page. Give it the **App Manager** role. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The full contents of the `AuthKey_<KEYID>.p8` that downloads **once**, BEGIN/END lines included. |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64` | An Apple Distribution certificate exported from Keychain Access as `.p12` **with its private key**, then `base64 -i Distribution.p12 \| pbcopy`. |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | The password set when exporting that `.p12`. |

Provisioning profiles are deliberately **not** secrets. The archive runs with
`-allowProvisioningUpdates` and the App Store Connect key, so Xcode fetches or creates the profiles
for `com.blakekimble.corecredit` and `com.blakekimble.corecredit.widget` itself. That is what the
project's `CODE_SIGN_STYLE = Automatic` already expects, and it means an expiring profile never
becomes a stale secret nobody remembers to rotate.

### 2b. The widget's App ID — one time, only if automatic signing cannot create it

Automatic signing normally registers both identifiers on its own. If the archive fails with
*"CoreCreditQuickScanWidget requires a provisioning profile"*, create the App ID by hand:

1. <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles** →
   **Identifiers** → **+** → *App IDs* → *App*
   - Description: `CoreCredit Quick Scan Widget`
   - Bundle ID: **Explicit**, `com.blakekimble.corecredit.widget`
   - Enable no capabilities — the widget needs none.
2. Re-run the workflow. It will pick the profile up.

---

## 3. The release sequence

1. **Land the work.** Push a branch or open a pull request. `ci.yml` runs on it: repository
   invariants, a Debug build of the app *and* the widget, the full unit suite, the full UI suite,
   and an iPad Air 11-inch smoke check when that simulator is on the runner. It gates on all of
   them. Merge only when it is green for the exact head being merged.

2. **Cut the TestFlight build.** **Actions → TestFlight → Run workflow**, against `main`.

   Leave **Build number** empty unless you have a reason not to: the job computes
   `BUILD_NUMBER_OFFSET + github.run_number` (64 + the run's number), which is unique, monotonic,
   and always above the rejected build 64. It refuses to run if that ever yields 64 or lower.

   It runs the invariants, archives **Release**, exports a signed `.ipa`, and then inspects it:
   bundle identifiers, the build number actually inside the bundle, the privacy manifest, the app
   icon, the embedded `.appex`, code signature and entitlements — and it fails if a `.storekit`
   configuration file has somehow ended up inside the bundle. Then it validates and uploads.

   **The upload command exiting 0 is not the finish line.** App Store Connect still has to process
   the build. Open TestFlight, wait for it to leave *Processing*, and confirm there is no *Missing
   Compliance* banner before attaching it to the App Store version.

3. **Accept on hardware.** Work `docs/DEVICE_ACCEPTANCE.md` on a real iPhone, and on an iPad for
   the layout sections. Everything camera-, notification-, and StoreKit-shaped can only be
   established here — see the "not executed anywhere" table in `docs/HANDOFF.md`.

   The **camera** permission primer is in that category and cannot be shortcut. Every simulator
   answers `.simulator` from `BarcodeScannerAvailabilityChecker.current()` before it ever reads an
   authorization status, so the primer's neutral **Continue** button only renders on a real device.
   The notification primer's `.notDetermined` state *is* covered by the UI suite.

4. **Submit.** `docs/APP_STORE_REVIEW_NOTES.md` for the review notes,
   `docs/APP_STORE_PRIVACY_ANSWERS.md` for the privacy questionnaire.

---

## 4. Versioning

- `MARKETING_VERSION` (`1.0`) is edited in the Xcode target. It is the version customers see.
- `CURRENT_PROJECT_VERSION` is overwritten by `testflight.yml` with `BUILD_NUMBER_OFFSET +
  github.run_number`, so build numbers are unique and monotonic without anyone editing the project
  file. The offset is `64` — the build App Review rejected — so every build this workflow produces
  is strictly above it. **Raise the offset if the workflow file is ever renamed or recreated**,
  because that resets `run_number`.
- `ci.yml` deliberately does **not** set one. Burning a build number to answer "does it compile?"
  makes the next real TestFlight build's number misleading.
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
