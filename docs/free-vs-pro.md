# ReelTunes — Free vs Pro

> Status: **implemented** in `lib/entitlements.dart` (trial, caps, reminders) and
> `lib/billing.dart` (RevenueCat over Play Billing). What is *not* live yet is the
> Play Console product setup — until the subscription products exist there, a
> release build shows "Pro isn't live yet".
> Rule: **no restriction may ever touch the user's files.** Gating limits what
> the app shows/creates, never what exists on the phone.

## 1. The tier contract

| | **Free** | **Pro** |
|---|---|---|
| Price | ₹0 | ₹399/mo · ₹3000/yr · $3.99/mo · €3.99/mo · $35/yr · €35/yr |
| **First 7 days** | **Pro features, free** (trial) | — |
| Audios in library | 25¹ | Unlimited |
| Playlists | 2 | Unlimited |
| Ads | After the trial (see §5) | None |
| Looping | ✨ Smart **3–6** or ∞ (repeat icon) | Smart (learned 1–99) + **Custom range** + ∞ |
| Coins | Earn by watching rewarded ads, spend in shop | — |
| Coin shop | **Unlocks on day 8** | — |
| Shuffle / seek / skip / background play / lock screen | Free | Free |
| Audios folder link, mirror, uninstall-safety | Free | Free |
| Existing files & playlists when a sub lapses | **Read-only overflow, never deleted** | — |

¹ **Caps only bite after the trial.** A user who imported 80 audios during the
7-day trial keeps all 80 playable; they just can't import past the cap. Nothing
is ever deleted or hidden from the library.

**Never paywalled:** playback, background playback, shuffle, folder linking,
re-scan, "Remove from ReelTunes", delete, existing data.

### Suggested extras (pick, don't ship all)
| Idea | Why | Risk |
|---|---|---|
| **Pro: export / share a clip** | Natural "I want this elsewhere" moment | Small build |
| **Pro: sleep timer** (fade + pause) | Cheap, feels premium, no infra | Must build it first |
| **Pro: batch import >25 at once** | Follows from the cap | none |
| Don't add: EQ/crossfade "coming soon" rows | Vaporware rows read as dark patterns | — |

## 2. Enforcement rules (the boring part that decides refunds)

- **Cap 25:** counted on *library entries*, not files. Every list, search,
  playlist and play queue runs through `AppStore._baseVisible()`, which on Free
  keeps only the **newest 25 entries by `addedAtMs`** whenever the library is
  larger (e.g. it grew during the trial). The older entries are **hidden, not
  deleted**; one notice row reads
  `"N older audios are hidden on Free · files stay on your phone"` and opens the
  paywall. Upgrading brings them all back instantly.
- **Import:** every add path (link extraction, file picker, folder import,
  post-download prompt) checks `importBlockReason(tracks.length)` **before** it
  starts and shows the paywall at 25 — no partial import, no silent drop.
- **Folder scan / rescan:** stops at `Entitlements.maxTracks` (25 on Free), so
  extra files are counted in the existing "more files in your folder" row and
  never imported. Nothing is deleted, renamed or hidden from the file manager.
- **Playlists:** creating the 3rd is blocked; existing playlists above 2 stay
  fully usable but read-only (rename/add-to disabled) so a lapse never destroys
  work.
- **Downgrade / refund / cancel:** library keeps all tracks, the newest 25 stay
  visible and playable, older ones are hidden behind the notice/paywall. Files
  untouched.
- **Custom range:** hidden behind the paywall chip on Free; Smart is capped at
  3–6; ∞ stays on the repeat icon.
- **One choke point:** `Entitlements` exposes `maxTracks`, `maxPlaylists`,
  `canUseCustomRange`, `showAds`, `isPro`, `coins`. No scattered `if (isPro)`.
  Import path, scan merge, playlist create and the add-reel button all ask the
  same object — that is also the only thing an auditor has to read.

## 3. Coins — absorb the ad revenue, don't guess at it

**Model:** watch an ad on purpose → get coins → spend coins on a timed perk.
It converts ad inventory into something the user chose, which keeps ads from
feeling like a tax.

> **What is implemented today (`lib/coins.dart` + `lib/shop_sheet.dart`):**
> **1 coin per completed rewarded video**; the shop has **10 timed perks**:
> **no ads (24 h / 7 d / 30 d / 90 d)**, **+25 / +50 audio slots (30 d / 90 d)**,
> **3rd playlist slot (30 d)**, and **custom loop range (7 d / 30 d)**.
> The wallet is local (SharedPreferences) until the SSV ledger exists. The shop,
> balance and gold "Watch ad" button are **Free-only**; a coin purchase never
> changes the plan, so they stay visible while a no-ads window is running.

### Earning
- **1 coin per completed rewarded video** in the local build. Production:
  completion is confirmed by the ad network's **server-side verification (SSV)**
  callback, not the app — the app cannot mint coins by patching code.
- **Daily earn cap** (start at **15–20 ads/day**) so inventory isn't burned and
  nobody farms the shop. Number is a server constant, not in the APK.
- No coins for banners or interstitials — only videos the user opened.

### Shop (all items timed, all expire; costs at 1 coin per ad)
| Item | Cost | Duration | State |
|---|---|---|---|
| No ads | 6 coins | 24 h | **implemented** |
| No ads | 20 coins | 7 days | **implemented** |
| No ads | 50 coins | 30 days | **implemented** |
| No ads | 120 coins | 90 days | **implemented** |
| +25 audio slots | 10 coins | 30 days | **implemented** |
| +25 audio slots | 25 coins | 90 days | **implemented** |
| +50 audio slots | 18 coins | 30 days | **implemented** |
| 3rd playlist slot | 8 coins | 30 days | **implemented** |
| Custom loop range | 4 coins | 7 days | **implemented** |
| Custom loop range | 12 coins | 30 days | **implemented** |

Final numbers **after** you see real eCPM. Because costs are server-side, you
change prices without shipping an update. Buying an active perk again extends
it instead of resetting the clock.

### Ad-free is a pause, not a plan change
`Entitlements.showAds` is `capped && !CoinWallet.adFree` (where `adFree` is true
while *any* no-ads perk is active). A purchased window hides the sticky banner,
the playlist cards and the app-open/rewarded prompts while leaving the shop,
balance and "watch ad" button untouched — the user can keep earning during the
pause. Pro/trial still hide all coin UI.

### The money guardrail (important)
Indian rewarded eCPM is roughly **$1–4 per 1000 views** → **≈ ₹0.10–0.35 per
ad**. So one coin ≈ **₹0.10–0.35** of revenue.

That means free coins are cheap goodwill, **not** a Pro replacement. Price every
shop item so it costs *less* value than the Pro day it imitates — otherwise you
pay users to avoid paying you. For context: one day of Pro at ₹399/mo is ≈
₹13, so even the 90-day no-ads perk (120 coins ≈ ₹12–43) stays below a month of
Pro.

### Storage & anti-tamper
- Balance lives in the **Cloudflare Worker + KV** keyed by install ID, mirrored
  locally for offline display. Spend is a server call; offline spends queue.
- Never trust the local balance for anything that costs you money.
- Users can reset the app to farm coins → the SSV daily cap is per Google
  account (Play Integrity + ad network ID), not per install.

## 4. Pricing (Play Console, not code)

- Use **price templates** per country (Play does not let you hard-code a price).
  IN ₹399/mo · ₹3000/yr · US $3.99/mo · $35/yr · EU €3.99/mo · €35/yr.
- ₹3000/yr = ₹250/mo effective, **7.5× monthly, ~37 % off** ₹4788.
- $35/yr vs $47.88 = **27 % off**; €35 vs €47.88 = 27 %. So India's annual is a
  deeper discount than the West — deliberate or not, know it.
- Play takes 15 % under $1M/yr → ₹399 ≈ **₹339**; ₹3000/yr ≈ **₹2550**
  (≈ ₹212/mo); $35 ≈ **$29.75**; €35 ≈ **€29.75**. Above $1M it is 30 %.
- Subscription = auto-renewing; Play owns proration, holds, grace, refunds,
  RBI e-mandate (India), VAT/GST. You never touch card data.
- **No external checkout.** Play policy requires Play Billing for digital goods.

## 5. Ads (from day 8, deliberately gentle)

Full plan, network comparison and eCPM reality: **`docs/ads.md`**. Summary:

- **Nothing during the 7-day trial.** The trial is Pro — ads would undercut it.
- **Slot A — download ad:** one interstitial **after** a successful save, max
  one per download, ≥60 s apart, and never on the first download of an install.
  An unfilled ad never blocks the save.
- **Slot B — sticky bar:** anchored adaptive banner pinned **just above the mini
  player**, on every browsing screen. Hidden in the full-screen player, in
  sheets, and for Pro.
- **Slot C — end of list:** a labelled "Sponsored" card after the last track
  row. Never styled like a track.
- **Rewarded:** only when the user taps "watch an ad for coins". Never auto-play.
  Coins are credited by AdMob **SSV**, not by the client.
- **UMP consent** (EEA/UK) before any personalized ad; non-personalized
  fallback; an "Ad privacy settings" row in Settings; ads disclosed in Data
  Safety.
- Network: **AdMob** at launch (best India fill), mediation sources added later.
  Numbers above are caps, not commitments.

## 6. How Pro is validated without app accounts

**The Google account that buys the subscription *is* the account.** Play Billing
already gives you a durable, Google-verified identity without signup, passwords,
email capture or a user database.

### 6.1 What is built: RevenueCat (`lib/billing.dart`)

RevenueCat is the validation layer. It verifies every receipt with the Play
Developer API on its own servers, maps products to one entitlement, restores on
a new device, and hands the app a single `CustomerInfo`. That removes the need
for our own purchase-verification server while keeping exactly the property we
wanted: **the app never decides who is Pro from a local boolean it invented.**

```
Play purchase → RevenueCat (verifies receipt server-side)
              → CustomerInfo.entitlements.active['pro']
              → Entitlements.setStoreEntitlement(...)
              → caps / ads / custom range flip on the same tick
```

| Piece | Value | Where it lives |
|---|---|---|
| SDK key | `goog_…` (public, safe in the APK) | `--dart-define RC_ANDROID_KEY=` |
| Entitlement identifier | `pro` | RevenueCat dashboard + `--dart-define RC_ENTITLEMENT=` (default `pro`) |
| Offering | `default` (marked *current*) | dashboard |
| Packages | `$rc_monthly`, `$rc_annual` | dashboard |
| Monthly product | `reeltunes_pro_monthly` | Play Console → Subscriptions |
| Annual product | `reeltunes_pro_annual` | Play Console → Subscriptions |
| Free trial | 7 days, one per Google account | Play Console → base plan → offer |

Build with the key:

```powershell
flutter build appbundle --release --dart-define RC_ANDROID_KEY=goog_xxxxxxxxxxxx
```

Without the define the app has no store: the paywall falls back to a debug
unlock in debug builds and a "coming soon" toast in release. Nothing crashes and
no gate depends on the key being present.

**Offline:** `Entitlements` caches the entitlement plus its expiry date. Pro
survives 3 days past the reported expiry (`Entitlements.storeGrace`) so a phone
that is offline at renewal does not drop to Free; a cancelled plan still reverts,
just a few days later. Ads and caps never depend on the network.

**Restore:** a Play purchase belongs to the Google account, so reinstall and
new-phone both resolve with `Purchases.restorePurchases()` — the Settings row
"Restore purchases", and the same button on the paywall.

**Play trial vs app trial.** Both exist on purpose:
- The **app trial** (7 days, starts at first folder link) is the freebie for
  people who never open Play.
- The **Play trial** (7 days on the subscription) is the one Google tracks per
  Google account, so it cannot be reset by reinstalling. If it is running, the
  app shows `Free trial · ends <date>` and behaves as Pro; the app trial's
  reminders stay silent because `purchased` is true.

### 6.2 The server option (only if RevenueCat is ever not enough)

```
Play purchase → purchaseToken (opaque, per Google account + product)
              → your server verifies it with the Play Developer API
              → server returns a short-lived signed entitlement
              → app caches it and gates offline
```

### Minimal server (free tier, ~$0)
- **Cloudflare Worker + KV** (100k req/day free). Also hosts the coin ledger and
  the ad SSV callback.
- Calls `purchases.subscriptionsv2.get`; checks package, productId,
  `paymentState`, `acknowledgementState`, expiry, region.
- Reply: **Ed25519-signed** compact token
  `{v, plan, products, exp (≤24 h), installId, pkg}`. Private key only on the
  server; public key pinned in the app.
- **Offline grace:** 7 days from last successful refresh. Then ads + limits
  return; data stays.

### Flows
| Flow | Behaviour |
|---|---|
| Launch | Verify cached token; refresh if expired and online |
| Buy | BillingClient → purchase → POST token → cache entitlement |
| Reinstall / new phone | `queryPurchasesAsync` → re-verify → same Pro |
| Acknowledge | Within 3 days or Play auto-refunds; server acks then signs |
| Cancel / expiry | Server sees it on next refresh → issues `free` |
| Refund / chargeback | Play RTDN → revoke; refresh returns `free` |
| Tampered APK | Play Integrity attached to refresh; unknown builds get no signature |
| No network ever | Free after 7 days (still never deletes data) |

### Be honest about it
- **Modding cannot be made impossible** when the gate runs on the phone.
- Server signing + Play Integrity kills the *cheap* hacks: lucky-patcher license
  fakes, `pro=true` smali edits, cloned APKs, shared purchase tokens.
- A determined modder still wins. Goal is "not worth 20 minutes", not DRM.
- **No root detection**, no blocking screens — false positives, bad reviews.

### If RevenueCat is dropped later
- `queryPurchasesAsync` client-side only: works, restores, trivially patchable.
- RevenueCat's free tier is <$2.5k/mo revenue — while the app is small it is the
  cheapest correct answer, which is why it is the implemented one.

## 7. 7-day trial that survives a reinstall

**Use Play's free trial on the subscription product.** Play tracks it against
the **Google account**, so uninstalling, reinstalling, clearing data or switching
phones does not reset it. This is the only reinstall-proof mechanism that costs
you nothing to build.

Belt-and-braces (covers the no-Play path, e.g. sideloaded builds):
- Write `trialStartedAt` into `.reeltunes-library.json` inside the **user's
  audios folder**. That file survives uninstall, so re-linking the folder after
  reinstall already shows the trial was used.
- A user who deletes that file can restart the trial — acceptable; they've also
  lost their playlist mirror.
- Do **not** use the device clock as the source of truth; compare against server
  time when online.

### Day 8 (what actually changes)
- Caps start applying to **new imports only**. The library keeps everything.
- Ads start. The **coin shop unlocks**.
- Settings shows one row: `"Trial ended · Pro for ₹399/mo"` — no modal, no nag
  loop, dismissible for a week.
- Pro bought during the trial keeps the same library; nothing to migrate.

Codes, creator programs and the admin dashboard are specified in
`docs/promo-codes.md`.

## 8. 18+ / consent (no signups)

- **Don't add accounts.** COPPA/GDPR-K, password reset, deletion requests — all
  for zero benefit. Play's account already gates payments to adults.
- Before first purchase: bottom sheet with
  `"I'm 18 or older (or have a guardian's permission)"`, **Terms** + **Privacy**
  links, price + renewal wording. Store acknowledgement with a timestamp.
- Content rating questionnaire: declare ads, in-app purchases, user-generated
  links, no user-to-user. Target audience **13+**.
- Ads: UMP consent (EEA/UK), NPA fallback, disclosed in Data Safety.
- Renewal/cancellation wording: copy Play's subscription terms verbatim.

## 9. Anti-abuse / policy guardrails
- One trial per Google account (Play).
- No offline license keys. Promo codes are validated server-side and expire.
- Play Integrity failure → **fail open to Free**, never crash or lock the app.
- Entitlement/coin checks never on the UI thread.
- Never make playback depend on network.
- Server constants (coin prices, daily cap) changeable without an app update.

## 10. Build order

| # | Step | State |
|---|---|---|
| 1 | `Entitlements` replacing `fullPro` | **done** |
| 2 | Trial clock (folder marker) → day 8 switches to caps | **done** |
| 3 | Free limits: 25 audios / 2 playlists, Smart 3–6, custom-range paywall | **done** |
| 4 | Trial-ending reminders at 3 days and 1 day | **done** |
| 5 | RevenueCat + Play Billing: purchase, restore, entitlement → caps | **done in code**, awaiting Play Console products + dashboard |
| 6 | Ads: UMP + sticky banner + interstitial with caps | next |
| 7 | Coin ledger on the Worker + AdMob SSV → balances | |
| 8 | Coin shop (unlocks day 8) | |
| 9 | Codes + dashboard (`docs/promo-codes.md`) | |
| 10 | Store listing, Data Safety, privacy policy, release signing, AAB | |

## 11. Decisions still open
1. **Ad network** — AdMob only, or AdMob + a mediation layer (see the ads plan).
2. **Rewarded ad daily cap** — 15 or 20 to start?
3. **Interstitial at all**, or banner-only at launch?
4. **Coin shop item list** — the four in §3, or trim?
5. **RevenueCat product IDs** — confirm `reeltunes_pro_monthly` /
   `reeltunes_pro_annual` before they are created in Play Console (they are
   permanent).
