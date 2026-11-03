# ReelTunes — Free vs Pro (plan, not shipped)

> Status: **planning only**, nothing enforced yet. `AppStore.I.fullPro` is still
> hard-coded `true`.
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

- **Cap 25:** counted on *library entries*, not files. When the folder scan finds
  more than 25, add the 25 newest and show one sticky row:
  `"17 more files in your folder · Pro to add"`. Nothing is deleted, renamed or
  hidden from the file manager.
- **Import:** stop at the cap, toast `"Free tier holds 25 audios · Pro for more"`.
  Never partially import then fail silently.
- **Playlists:** creating the 3rd is blocked; existing playlists above 2 stay
  fully usable but read-only (rename/add-to disabled) so a lapse never destroys
  work.
- **Downgrade / refund / cancel:** library keeps all tracks, the newest 25 stay
  playable, the rest show as locked rows (tap → paywall sheet). Files untouched.
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

### Earning
- **1 coin per completed rewarded video.** Completion is confirmed by the ad
  network's **server-side verification (SSV)** callback, not the app — the app
  cannot mint coins by patching code.
- **Daily earn cap** (start at **15–20 ads/day**) so inventory isn't burned and
  nobody farms the shop. Number is a server constant, not in the APK.
- No coins for banners or interstitials — only videos the user opened.

### Shop (all items timed, all expire)
| Item | Suggested cost | Duration |
|---|---|---|
| No ads | 20 coins | 24 h |
| +25 audio slots | 25 coins | 30 days |
| 3rd playlist slot | 15 coins | 30 days |
| Custom loop range | 10 coins | 7 days |

Final numbers **after** you see real eCPM. Because costs are server-side, you
change prices without shipping an update.

### The money guardrail (important)
Indian rewarded eCPM is roughly **$1–4 per 1000 views** → **≈ ₹0.10–0.35 per
ad**. So 20 ads ≈ **₹2–7** of revenue, while one day of Pro is ₹13.

That means free coins are cheap goodwill, **not** a Pro replacement. Price every
shop item so it costs *less* value than the Pro day it imitates — otherwise you
pay users to avoid paying you.

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

- **Nothing during the 7-day trial.** The trial is Pro — ads would undercut it.
- **Banner:** library + settings **only**. Never in the player, never on the
  "saved!" moment.
- **Interstitial:** none in the first week of use. Later: max 1 per 4 saves,
  ≥90 s apart, never while audio plays, never right after a failed extract.
- **Rewarded:** only when the user taps "watch an ad for coins". Never auto-play.
- **UMP consent** (EEA/UK) before any personalized ad; non-personalized
  fallback; ads disclosed in Data Safety.
- Provider TBD — costs and formats get finalised once you pick (AdMob vs
  alternatives). Numbers above are caps, not commitments.

## 6. How Pro is validated without app accounts

**The Google account that buys the subscription *is* the account.** Play Billing
already gives you a durable, Google-verified identity without signup, passwords,
email capture or a user database.

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

### If you want 100 % server-free
- `queryPurchasesAsync` client-side only: works, restores, trivially patchable.
- Middle option: **RevenueCat** free tier (<$2.5k/mo revenue) does validation.

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

## 10. Build order (when approved)
1. `Entitlements` service replacing `fullPro` (dev flag, no billing).
2. **Trial clock** (Play trial + folder marker) → day 8 switches to caps.
3. Free limits after trial: 25 audios / 2 playlists, Smart 3–6, custom-range
   paywall.
4. Ads: UMP + banner, then rewarded, then interstitial with caps.
5. Coin ledger on the Worker + AdMob SSV → balances.
6. Play Billing: products, trial, purchase/restore/acknowledge.
7. Entitlement signing + Play Integrity + RTDN; 7-day grace.
8. Coin shop (unlocks day 8) + paywall sheets.
9. Codes + dashboard (`docs/promo-codes.md`).
10. Store listing, Data Safety, privacy policy, release signing, AAB.

## 11. Decisions I still need
1. **Server or no server** for Pro + coins + codes? (recommended: free Worker —
   codes and referral quotas cannot work without one.)
2. **Caps after the trial** — 25 audios / 2 playlists, or 50 / 3?
3. **Rewarded ad daily cap** — 15 or 20 to start?
4. **Interstitial at all**, or banner-only at launch?
5. **Coin shop item list** — the four in §3, or trim?
