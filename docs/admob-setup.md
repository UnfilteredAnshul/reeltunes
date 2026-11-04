# AdMob — live units, testing, and the pre-production checklist

> Status (2026-11-04): **live ids are wired in.** The app id is in
> `android/app/src/main/AndroidManifest.xml`; every unit id is in
> `lib/ad_config.dart`. Debug builds request the live units by default so fill
> can be verified on the device. Google's samples are one switch away.

---

## 1. What is wired

| Piece | Where | Unit |
|---|---|---|
| SDK | `google_mobile_ads` 9.2.0 | — |
| Init + UMP consent | `lib/ads.dart` → `Ads.I.init()` / `ensureConsent()` | — |
| Sticky banner (slot B) | `AdBanner` above `MiniBar` | `…/1283639888` |
| Playlist cards ×2 | `PlaylistAdCard` after the 8th/18th audio | `…/2022006489` |
| Rewarded video | coin shop + gold "Watch ad" FAB | `…/4971428445` |
| App-open | after the coin splash on cold start | `…/1962121722` |
| Privacy options | Settings → Privacy → "Ad privacy choices" | — |
| Debug readout | Settings → Debug tiers → "Ads: unit in use" | — |

App id: `ca-app-pub-5837741403938321~1070877733`.

**Two placements can share one ad unit.** AdMob pays per impression/click, not
per unit id, so the two playlist cards request `…/2022006489` twice and earn the
same as two identical units would. Separate units only split reporting.

### Test vs live at runtime

- **Live is the default** in both debug and release.
- **Settings → Debug tiers → "Use test ad units"** switches every placement to
  Google's samples (`ca-app-pub-3940256099942544/…`), which are safe to tap.
  The choice is persisted.
- `--dart-define=ADMOB_TEST_ADS=true` forces samples from the build command.
- **Never tap your own live ad.** Invalid traffic is permanent and can suspend
  the account. Watching your own live rewarded ad to test coins is also invalid
  traffic — use the test-unit switch for that.

---

## 2. What to expect on the device

1. Install the debug APK, open Settings → Debug tiers → **Force Free** (or let
   the trial end). Ads are hidden during the trial and for Pro.
2. The sticky banner sits just above the mini bar, the two playlist cards are
   after the 8th and 18th audio in list view, and a cold start can show the
   app-open ad (max once per 4 h).
3. The gold coin chip / shop icon appear beside search. Open the shop and tap
   **Watch ad · +5 coins**. 4 videos = 20 coins = 24 h without ads.
4. Coin shop purchases do **not** hide the shop/balance/watch-ad controls — only
   Pro or the trial does. A purchase only pauses ads for 24 h.
5. A brand-new unit can take **minutes to a couple of hours** for its first
   impression, and fill stays low until the app is on Play **and**
   `app-ads.txt` is verified. That is expected, not a code bug.

If nothing fills, check in order: is the plan Free (`showAds`)? Is the test-unit
switch off intentionally? Is the unit id from the **same AdMob account** as the
manifest app id? Is a VPN / Private DNS / ad blocker active? Then wait an hour
and look at AdMob → app → Ad units → requests/fill.

---

## 3. Before production (deferred until after the ad test is approved)

### app-ads.txt
AdMob verifies it against the developer website on the Play listing.
1. Create a public repo `<you>.github.io` with a root file `app-ads.txt`:
   ```
   google.com, pub-5837741403938321, DIRECT, f08c47fec0942fa0
   ```
2. Enable **GitHub Pages** for the repo.
3. Put `https://<you>.github.io` as the website on the Play listing.
4. AdMob → app → **app-ads.txt** → **Verify** (can take hours; re-check after
   publishing).

### Privacy policy
Name AdMob, the advertising ID (AAID), the app-open/rewarded/banner formats,
and how to reset the advertising ID (`Settings → Google → Ads`).

### Data Safety
- Device or other IDs (AAID)
- App interactions / ad interactions
- Approximate location (from IP)
- Purpose: **Advertising or marketing**, shared with Google.

### Play listing
- "Contains ads" = **Yes**.
- Content rating **13+**, not child-directed.
- No sample units in a release build; the debug switch is debug-only.

---

## 4. Coin economy caveat

The wallet in `lib/coins.dart` is **local** until AdMob SSV + the Cloudflare
Worker exist. The local ledger is fine for testing and for a first release, but
a production balance that costs real money should be server-verified; see
`docs/free-vs-pro.md` §3.
