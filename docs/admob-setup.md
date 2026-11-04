# AdMob — switching from test ads to live ads

> Short version: the code is already wired. Live ads need **two ids that only
> the AdMob account owner can create**: the app id and a banner unit id.
> I can't log into your AdMob account, so send me those two strings and I'll
> wire them and build.

---

## 1. What is already in the code

| Piece | Where | State |
|---|---|---|
| SDK | `google_mobile_ads` 9.2.0 | wired |
| Init + UMP consent | `lib/ads.dart` → `Ads.I.init()` / `ensureConsent()` | wired |
| Banner (slot B) | `lib/ads.dart` → `AdBanner` above `MiniBar` | wired, test unit |
| Identifiers | `lib/ad_config.dart` | placeholders |
| Manifest app id | `android/app/src/main/AndroidManifest.xml` | sample id + `TODO(release)` |
| Privacy options row | Settings → Privacy → "Ad privacy choices" | wired |
| Debug readout | Settings → Debug tiers → "Ads: unit in use" | wired |

Debug builds **always** request Google's sample banner
(`ca-app-pub-3940256099942544/6300978111`), so they are safe to tap. Live units
only ever go into a **release** build.

---

## 2. What only you can do (AdMob console)

You can do this while the account is still being verified — app + ad-unit
creation is available; payouts and some features unlock after verification.

1. Open <https://apps.admob.com> and sign in.
2. **Apps → Add app** (or *All apps → Add app*).
   - Platform: **Android**.
   - *Is the app listed on a supported app store?* → **No** for now
     (ReelTunes is not published yet). You'll link the Play listing later in
     *App settings*.
   - App name: **ReelTunes**.
3. Open the new app → **App settings** → copy the **App ID**:
   `ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY`
4. **Ad units → Add ad unit → Banner**.
   - Name: `Home · anchored adaptive`.
   - Keep the default (banner) format; anchored-adaptive sizing is requested
     by the app, no special unit type is needed.
   - Create → copy the **Ad unit ID**:
     `ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ`
5. **Payments**: add payment method, tax info and your address. Google mails a
   **PIN** to verify the address before any payout (no fee). Ads can start
   serving before that, but a brand-new unverified account often sees low fill
   for a while.
6. Leave the eCPM floor at 0 for now (see `docs/ads.md` §6).

Those two ids are **not secret** (they ship inside every APK), so pasting them
in chat is fine.

---

## 3. What happens once you send the ids

1. `lib/ad_config.dart` → real `appId` + `bannerUnit` become the release
   defaults (debug still forces the sample unit).
2. `AndroidManifest.xml` → `com.google.android.gms.ads.APPLICATION_ID` becomes
   the real app id.
3. I build a **release** APK (`flutter build apk --release`, still debug-signed
   until the Play upload keystore exists) and install it. That build requests
   the live unit.
4. You keep testing day-to-day on the debug build (test ads, safe to tap);
   the release build is only to confirm live fill.

---

## 4. Verifying live ads without risking the account

- **Never tap your own live ad.** Invalid-traffic warnings are the one thing
  that can suspend an AdMob account, and they are permanent.
- A new ad unit can take **minutes to a couple of hours** for the first
  impression. "No ad yet" in the first 10 minutes is normal.
- Fill can stay near zero until the app is on Play **and** `app-ads.txt` is
  verified. That is expected, not a code bug.
- The banner only requests when `Entitlements.showAds` is true: Free plan,
  after the trial. In debug use **Settings → Debug tiers → Force Free**.
- The UMP consent form only appears where required (EEA/UK/CH) or when Google
  decides it is; "Ad privacy choices" re-opens it on demand.

---

## 5. Things that must exist before production (independent of the ids)

- **`app-ads.txt`** at the root of your developer website, verified in AdMob.
  No website yet? A free GitHub Pages site works:
  1. Create repo `<you>.github.io` (public), add a file `app-ads.txt`:
     ```
     google.com, pub-<your publisher id without ca-app-pub->, DIRECT, f08c47fec0942fa0
     ```
     Example publisher id `pub-1234567890123456` → that exact `pub-…` token.
  2. Enable Pages for the repo.
  3. Put `https://<you>.github.io` as the website on the Play listing.
  4. AdMob → app → **app-ads.txt** → verify (can take hours, re-check after
     publishing).
- **Privacy policy** naming AdMob, the advertising ID (AAID), and how to reset
  it (`Settings → Google → Ads`).
- **Data Safety**: device or other IDs, app interactions, approximate location
  (from IP), purpose *Advertising or marketing*, shared with Google.
- **Play listing**: "Contains ads" = **Yes**; content rating **13+**, not
  child-directed.
- Keep the sample ad units local to debug — never ship a release that requests
  `ca-app-pub-3940256099942544/…`.

---

## 6. If live ads show nothing

Check, in order:

1. Is the build **release**? (debug intentionally uses the sample unit.)
2. Does `AdConfig.modeLabel` say *Live ads* in Settings → Debug tiers?
   (That section is stored in the debug build; a release build shows the ad if
   the ids are right.)
3. Manifest app id = the same AdMob account as the unit id? A mismatch causes
   `Invalid request` / no fill.
4. Is the plan Free? Force Free, or end the trial.
5. Network/ad-blocker on the phone (Private DNS, VPN, AdAway).
6. Wait an hour, then check AdMob → app → **Ad units** for request/fill counts.
