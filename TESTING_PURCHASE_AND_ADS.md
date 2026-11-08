# ReelTunes: test purchases, testers, Play billing and ads

Last updated: 2026-11-08. Everything below was verified on the Realme (debug build) unless marked "later".

---

## 0. One-minute summary

| Question | Answer |
|---|---|
| Why did versionCode 5 crash? | R8 stripped Room's generated `WorkDatabase_Impl` constructor. WorkManager (pulled in by AdMob) created it at startup, before Flutter loaded, so the process died in `InitializationProvider`. |
| What changed? | `android/app/proguard-rules.pro` keeps Room database classes and their constructors; wired into the release `proguardFiles`. |
| Fixed? | Yes. v6 AAB boots on the phone; the constructor is back in the dex. |
| Why "Wrong API Key"? | RevenueCat refuses `test_…` keys in **non-debuggable** builds. The phone still had the release APK built with the test key. The SDK shows a blocking dialog and closes the app on purpose. |
| Can we test payments with the test key? | Yes, but **only in a debug build**. A release/AAB with a test key will always close. |
| How do testers simulate a purchase? | Sideload the debug APK with the test key, open the paywall, tap **Continue**, then **Test valid purchase**. No Google account, no money, Pro unlocks. |
| Is that a real Play purchase? | No. It is RevenueCat's Test Store: a sandbox subscriber, not Google Play billing. Real Play billing needs the production `goog_…` key plus the service account JSON. |
| Does AdMob need a service account? | No. The service account is only for **Play Console → RevenueCat** purchase validation. AdMob uses its own account, app ID and ad unit IDs. |

---

## 1. What happened, exactly

### 1.1 The startup crash (versionCode 5)

Logcat, top to bottom:

```
Unable to get provider androidx.startup.InitializationProvider
  caused by Failed to create an instance of androidx.work.impl.WorkDatabase
  caused by androidx.room.Room.getGeneratedImplementation(Room.java:100)
  caused by WorkManagerInitializer
```

- `play-services-ads` brings in WorkManager.
- WorkManager uses Room and instantiates `WorkDatabase_Impl` reflectively.
- R8 full mode (AGP 9) removed its no-arg `<init>()`, even though Room's own consumer rule keeps the class.
- The provider failed before the Flutter engine started, so the only thing the user saw was "ReelTunes keeps stopping".

Fix: `android/app/proguard-rules.pro`

```
-keep class * extends androidx.room.RoomDatabase { *; }
-keep class * extends androidx.room.RoomDatabase {
    <init>();
}
```

and in `android/app/build.gradle.kts`, release:

```kotlin
proguardFiles(
    getDefaultProguardFile("proguard-android-optimize.txt"),
    "proguard-rules.pro"
)
```

Verified: `WorkDatabase_Impl.<init>()` is present in the v6 dex and the release APK boots to the home screen. Do not remove this file when editing R8 rules.

### 1.2 Why the test key showed "Wrong API Key"

`purchases_flutter` checks whether the running app is debuggable. A `test_…` key inside a **release** build triggers `SimulatedStoreErrorDialogActivity`:

- Title: "Wrong API Key"
- Text: a test purchase key was used in a production build
- Only button path: the app closes.

That is why the test APK on the phone (versionCode 5, release-signed, test key baked in) failed. It was not a bad key and not a missing product. The same key was accepted immediately by the debug build.

Rule: **test key in debug builds only; release/AAB must have no key or a `goog_…` key.**

---

## 2. Let testers simulate purchases (no money, Pro unlocks)

### 2.1 How this works

RevenueCat Test Store is a fake store that lives entirely in the RevenueCat dashboard. The native SDK shows its own purchase sheet ("Test Store Purchase") with three buttons:

- **Test valid purchase**: creates a sandbox subscription and activates the entitlement.
- **Cancel**: nothing happens.
- **Test failed purchase**: simulates a failure (useful for error toasts).

Nothing touches Google Play. There is no charge, no Google account, no Play app, and no service account. Purchases appear in RevenueCat under the Test Store app, tied to the device's anonymous RevenueCat ID.

Requirement: the app must be **debuggable**, because Release builds reject test keys.

### 2.2 One-time RevenueCat Test Store setup (dashboard UI)

1. Open https://app.revenuecat.com and sign in.
2. Select the ReelTunes project.
3. Left sidebar → **Apps**. There must be an app whose store is **Test Store** (the key starts with `test_`). If it does not exist: **+ New** → App name `ReelTunes Test` → Store **Test Store** → save.
4. **Products** → **+ New**:
   - Identifier `monthly`, type Subscription, price `9.99`, period 1 month.
   - Identifier `yearly`, type Subscription, price `79.99`, period 1 year.
5. **Entitlements** → `reeltunes_pro` (create if missing). Attach both products so either purchase unlocks Pro. This identifier must match `Billing.entitlementId` (`reeltunes_pro`).
6. **Offerings** → `default`:
   - Mark it **Current** (the app falls back to the first offering, but Current is the intended behaviour).
   - Add package **Monthly** (`$rc_monthly`) → `monthly` product.
   - Add package **Annual** (`$rc_annual`) → `yearly` product.
7. **API keys** → Test Store app → copy the public key (`test_…`). It is not a secret; it can only read this app's sandbox.
8. Sanity check: the paywall must show both prices. If it shows "Prices are still being set up", the offering is missing, not current, or has no packages.

Current key used by this project:

```
test_tyQKigCCoWOlwvRESjGOAhdUwXI
```

### 2.3 Build the tester APK

From `E:\Projects\ReelTune`:

```powershell
flutter build apk --debug --target-platform android-arm64 `
  --dart-define=ADMOB_TEST_ADS=true `
  --dart-define=RC_ANDROID_KEY=test_tyQKigCCoWOlwvRESjGOAhdUwXI
```

Output: `build\app\outputs\flutter-apk\app-debug.apk`.

Notes:

- `--target-platform android-arm64` keeps it smaller. For old 32-bit phones, drop that flag (bigger, universal APK).
- `ADMOB_TEST_ADS=true` makes all ads Google's samples, safe for testers to tap.
- Never use this APK for a Play upload; a release build with the test key closes (section 1.2).
- Do not add the test key to a release command and do not commit a real `goog_` key.

Distribute the APK directly (Drive link, Firebase App Distribution, WhatsApp file, etc.). Play internal testing cannot host a debug APK.

### 2.4 What a tester does (UI step by step)

1. On the phone: open the APK. If prompted, allow "Install unknown apps" for the browser or file manager.
2. If an older ReelTunes is installed and Android says "App not installed", uninstall the old one first (different signing key resets data).
3. Open ReelTunes → allow notifications → on "Where should your audios live?" pick a folder or tap **Later**.
4. Settings (gear, top right) → **ReelTunes Pro**.
5. If the row says Free with a **Get Pro** button, tap that; otherwise tap the row. The sheet opens with **Yearly** and **Monthly**.
6. Tap **Continue**. RevenueCat's **Test Store Purchase** dialog appears.
7. Tap **Test valid purchase**.
8. Pro is now active: Settings shows `Pro · no ads, unlimited audios`, the Pro sheet shows `Pro · Renews automatically through Google Play`, and ads stop.
9. Optional: force-stop and reopen the app to prove the entitlement persists.

If the dialog does not appear, the tester is on a release build or the build has no test key. Check logcat for:

```
billing: ready (entitlement "reeltunes_pro")
```

### 2.5 Reset a tester back to Free

- Easiest: uninstall and reinstall the APK. The anonymous subscriber is new, so the app starts Free.
- Or in the app: Settings → **Debug · tiers** → **Force Free**.
- Or redeem the built-in debug code `FREEVERSION` (debug builds only).
- The Test Store subscription in RevenueCat stays in the dashboard; it is sandbox data, not revenue.

### 2.6 Limits and rules

- Test Store purchases are **not** real Play subscriptions and do not validate against Google.
- They do not prove Play product configuration, pricing, tax, grace periods or cancellation. They prove the app's own paywall, purchase call, entitlement mapping and UI.
- Testers can repeat the flow on any number of devices. There is no charge and no limit.
- The test key only works in debuggable builds. Anyone with the debug APK can unlock Pro for free — expected for internal testers, not for public distribution.
- Do not publish the debug APK. Do not put the test key in a release build.
- Test Store data is tied to the RevenueCat anonymous ID; clearing app data creates a new subscriber and the old sandbox subscription is orphaned.

### 2.7 Alternative without any store: promo code

For pure feature testing (not payment testing), the app already has a local Pro code system:

- Debug builds accept the built-in lifetime code `ANSHUL2012` (Code dashboard is visible in debug).
- Settings → **Redeem a code** applies it.
- This does not exercise the purchase sheet, so use it only for gating tests, never as a payment test.

---

## 3. Going live later: real Play billing

Do this only when the Play app exists and you are ready to publish. Testers still do not pay if you use license testing.

### 3.1 Pieces

- **Google Cloud**: a service account with a JSON key.
- **Play Console**: that service account gets permission to read orders and manage subscriptions.
- **RevenueCat**: upload the JSON so it can validate purchases; import products; attach the entitlement.
- **App**: built with the Play public key `goog_…`.

The service account is a robot Google account. RevenueCat uses it to ask Play "is this purchase valid?". It is not an AdMob credential.

### 3.2 Create the Google Cloud project and service account

1. Open https://console.cloud.google.com.
2. Project selector (top bar) → **New project** → name `reeltunes-play` → **Create** → select it.
3. Hamburger menu → **APIs & Services** → **Library**.
4. Search `Google Play Android Developer API` → open it → **Enable**.
5. Hamburger menu → **IAM & Admin** → **Service accounts** → **+ Create service account**.
6. Service account name: `reeltunes-revenuecat`. Skip the optional roles (no project role is needed). Click **Create and continue** → **Done**.
7. Click the new service account → **Keys** tab → **Add key** → **Create new key** → **JSON** → **Create**.
8. A `.json` file downloads. Rename it `reeltunes-play-service-account.json`. Treat it like a password: never commit it, never paste it in chat. Add it to `.gitignore`.

### 3.3 Give the service account access in Play Console

1. Open https://play.google.com/console → select the ReelTunes app.
2. **Setup** → **API access** (older UI) or **Settings → API access** (newer UI).
3. If no Cloud project is linked: **Link project** → choose `reeltunes-play` → confirm. (If Play created its own project, either link that one and create the service account there, or link the new one.)
4. Under **Service accounts**, find `reeltunes-revenuecat@….iam.gserviceaccount.com` → **Grant access** (or **Manage Play Console permissions**).
5. **Users and permissions** → **Invite new user** → paste the service account email.
6. App permissions: add **ReelTunes**, then tick:
   - **View app information and download bulk reports (read-only)**
   - **View financial data, orders, and cancellation survey responses**
   - **Manage orders and subscriptions**
7. Account permissions: none required beyond the app permissions above.
8. Send the invite. A service account does not need to click an email; access applies to it.

### 3.4 Upload the JSON to RevenueCat

1. RevenueCat → project → **Apps** → the **Play Store** app (package `com.buildwithanshul.reeltunes`).
2. **Service account credentials** → **Upload JSON** → select the file from 3.2.
3. Save. RevenueCat should report the credentials as valid.
4. If it complains about permissions, recheck 3.3 (usually "Manage orders and subscriptions" or "View financial data" is missing).

### 3.5 Create the subscriptions in Play Console

1. Play Console → **Monetize with Play** → **Products** → **Subscriptions** → **Create subscription**.
2. Product ID `monthly`, name "ReelTunes Pro Monthly".
3. Base plan: ID `monthly`, type auto-renewing, billing period 1 month, price for India and other countries.
4. Optional offer: **Free trial** 7 days (matches the app's trial wording; only if you actually want Play to give a trial).
5. **Activate** the base plan.
6. Repeat for `yearly`: product ID `yearly`, base plan `yearly`, 1 year.
7. RevenueCat identifiers for these are `monthly:monthly` and `yearly:yearly` (product ID **:** base plan ID). This is the format to use in RevenueCat, not just `monthly`.

### 3.6 Map products in RevenueCat

1. **Products** → **+ New** → identifier `monthly:monthly` → attach the Play store product → save.
2. Add `yearly:yearly`.
3. **Entitlements** → `reeltunes_pro` → attach both.
4. **Offerings** → `default` (Current) → packages:
   - Monthly (`$rc_monthly`) → `monthly:monthly`
   - Annual (`$rc_annual`) → `yearly:yearly`
5. Wait for RevenueCat to import the Play products (usually minutes; can take longer for a new app).
6. Copy the **Google Play public app-specific key** (`goog_…`) from **API keys**.

### 3.7 Build the release with the production key

```powershell
flutter build appbundle --release `
  --dart-define=ADMOB_TEST_ADS=false `
  --dart-define=RC_ANDROID_KEY=goog_your_public_play_key
```

- Bump `version: 0.0.2+N` in `pubspec.yaml` before every Play upload; Play burns each versionCode.
- Do not commit the `goog_` key. Pass it on the command line or through CI secrets.
- Upload the AAB to **Test and release → Testing → Internal testing**.

### 3.8 Let testers buy without paying (license testers)

Google Play license testing makes the purchase sheet show a test card that always approves and never charges.

1. Play Console → **Setup → License testing** (newer UI: **Settings → License testing**).
2. Add each tester's Google account email.
3. License response: `RESPOND_NORMALLY`.
4. Save.
5. Add the same emails under **Test and release → Testing → Internal testing → Testers**.
6. Create the internal release, roll it out, copy the opt-in URL and send it to testers.
7. Tester opens the opt-in URL, accepts, installs ReelTunes from Play.
8. Tester opens the paywall → **Continue** → Google Play sheet shows a **test card** / "Test purchase" → completes with no charge.

Requirements: the tester must be signed into Play with the listed account, the app must be installed from the Play internal-testing link (not sideloaded), and the subscription products must be active. Test subscriptions renew on the test cycle for free until cancelled.

### 3.9 What testing this proves that the Test Store does not

- Real Play product IDs, base plans, prices and currency.
- Play purchase sheet, test card, acknowledgement, pending purchases.
- RevenueCat's server-to-server validation with the service account.
- Restore, cancellation and expiry behaviour.
- Play policy wording ("Billed through Google Play").

---

## 4. Ads (AdMob) setup

### 4.1 No service account for ads

AdMob does not use the Play service account and does not use Google Cloud IAM. The pieces are:

- An AdMob account (already exists).
- An AdMob **app** whose App ID is in `AndroidManifest.xml`.
- Ad **unit IDs** in `lib/ad_config.dart`.
- Optionally, test device IDs so you can tap live units without risking the account.
- Payments/tax details in AdMob if you want to get paid.

Do not paste the Play service-account JSON into AdMob; it is not used there.

### 4.2 Current IDs in this project

`lib/ad_config.dart` and `AndroidManifest.xml` already contain:

```
App ID:            ca-app-pub-5837741403938321~1070877733
Banner:            ca-app-pub-5837741403938321/1283639888
Rewarded (coins):  ca-app-pub-5837741403938321/4971428445
Rewarded (gate):   ca-app-pub-5837741403938321/1020962184
App open:          ca-app-pub-5837741403938321/1962121722
Playlist banner:   ca-app-pub-5837741403938321/2022006489
```

The app ID must be identical in both places. If you create a new AdMob app, update both or every request fails.

### 4.3 Google test ads vs live ads

- Test ads: Google's sample units. Safe to tap. Enabled by `--dart-define=ADMOB_TEST_ADS=true` or Settings → Debug → "Use test ad units".
- Live ads: the ReelTunes units above. Never tap them yourself and never ask testers to tap them; invalid traffic can suspend the AdMob account.
- Every internal/test build should use `ADMOB_TEST_ADS=true`. Only the production build should use live units.
- `AdConfig.appIdMismatch` and the Settings debug row show which mode is active.

### 4.4 UMP consent form (fixes the launch log)

Current log:

```
UMP info update failed: Publisher misconfiguration ... no form(s) configured for the input app ID
```

Ads still load, but GDPR/US-states users get no consent form. Fix in the AdMob console:

1. Open https://admob.google.com → sign in.
2. **Privacy & messaging** (left sidebar).
3. **GDPR** → **Create message**:
   - Select the ReelTunes app.
   - Message name: `ReelTunes GDPR`.
   - Choose the consent message type, add the privacy policy URL `https://reeltunes-privacy.buildwise.workers.dev/`.
   - Keep "Consent" and the standard options; publish/save.
4. **US states** → **Create message**:
   - Same app, same privacy policy URL, publish/save.
5. Wait a few minutes, then relaunch. The log line should disappear.
6. The app already re-checks consent at startup (`Ads.ensureConsent`) and exposes **Settings → Ad privacy choices** when the SDK says privacy options are required.
7. If you need to re-test the form on your own device: clear app data or use a VPN in the EEA; the form only appears where the message applies.

### 4.5 Add your phone as a test device (optional but recommended)

Use this when you want to test **live** units without generating invalid traffic:

1. Run a build with live units and look at logcat for a line like:
   ```
   To get test ads on this device, set:
   RequestConfiguration.TestDeviceIds("33BE2250B43518CCDA7DE426D04EE231")
   ```
2. Either add that ID in AdMob → **Settings → Test devices → Add test device**, or add it in code through `RequestConfiguration`.
3. Reopen the app. Live units now serve test creatives on that device only.
4. Test ads (Google samples) need none of this and remain the safest default.

### 4.6 AdMob account, payments and policy

- **App verification**: AdMob → **Apps** → ReelTunes → verify ownership (link the Play listing when the app is live). Unverified apps can be limited.
- **Payments**: AdMob → **Payments** → verify identity, add bank account, complete tax forms. Payment threshold is typically USD 100; earnings below it roll over. This is separate from Play and RevenueCat.
- **Data safety**: the merged manifest declares `com.google.android.gms.permission.AD_ID` (from the Ads SDK). The Play Data safety form must keep "Device or other IDs" declared as collected/shared for advertising, which is already documented in `pc.md`.
- **Families policy**: if the app is ever listed as child-directed, ads must be configured accordingly; currently it is not.
- **Consent**: do not ship to the EEA without the GDPR message published.

### 4.7 AdMob checklist

- [ ] App ID in `AndroidManifest.xml` matches `AdConfig.liveAppId`.
- [ ] Five live unit IDs match the AdMob console.
- [ ] Internal builds use `ADMOB_TEST_ADS=true`.
- [ ] GDPR message published.
- [ ] US states message published.
- [ ] Test device added before tapping live ads.
- [ ] Payments/tax details complete before expecting a payout.
- [ ] Data safety still declares Advertising ID.

---

## 5. Recommended sequence

1. **Now**: keep the v6 AAB (store disabled) for the Play internal test. Testers who want to see Pro use the debug APK + Test Store (section 2).
2. **When Play products are ready**: create the service account, grant Play permissions, upload the JSON to RevenueCat, create `monthly`/`yearly` subscriptions, map the entitlement and offering (section 3).
3. **Then**: build with the `goog_…` key, upload a bumped versionCode, add license testers, and run the real flow with test cards.
4. **Ads, independent of billing**: publish the UMP messages and add a test device (section 4). Test ads stay on for every non-production build.

## 6. Do-not-do list

- Do not build a release/AAB with `RC_ANDROID_KEY=test_…`; the app closes by design.
- Do not ship sample ad units or live units to testers without `ADMOB_TEST_ADS=true`.
- Do not tap live ads yourself.
- Do not commit `reeltunes-play-service-account.json`, `android/key.properties` or `android/upload-keystore.jks`.
- Do not rename an AAB to fake a new version; bump `version: 0.0.2+N` and rebuild.
- Do not distribute the debuggable tester APK publicly.
