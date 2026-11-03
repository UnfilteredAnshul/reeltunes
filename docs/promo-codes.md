# ReelTunes — Codes, referrals & admin dashboard

> Companion to `free-vs-pro.md`.
> **Phase 1 is shipped** (local engine, in-app dashboard): see §12. The rest of
> this document is the server design it will move onto, unchanged.
> All of it will live on the same Cloudflare Worker as the entitlement service,
> so there is still **one backend, one bill (₹0), one dashboard.**

## 0. Trial → cap → shop (the timeline this plugs into)

| Day | What the user gets |
|---|---|
| 0–7 | **Pro features**: unlimited audios + playlists, Smart + Custom range, no caps |
| Day 7 | Trial ends silently. Library **keeps everything**, nothing deleted |
| Day 7+ | Free caps apply (25 audios / 2 playlists on new imports only), **ads**, **coin shop unlocks** |
| Any time | A code can push them back into Pro for a set period |

**Important:** caps never retro-hide what they already have. A user who imported
80 audios during the trial keeps all 80 playable after it — they just can't
import past the cap. Anything else looks like a bait-and-switch and gets 1-star
reviews.

## 1. What a code can and cannot do (read this first)

**Can:** grant Pro time, extend a trial, unlock a feature for N days, grant
coins, run a capped campaign, reward a creator.

**Cannot:** change the Play price at checkout.

Play Billing prices are fixed per country in Play Console. Your server cannot
give one user a ₹200 price and another ₹399. So:

- **"Discount code" = time, not money.** `DIWALI20` doesn't cut ₹399 to ₹319 —
  it grants **20 days of Pro**, or **20% more days** on the next purchase.
  Users understand "free 20 days" better than "20% off" anyway.
- If you truly want price discounts, use **Play Console's own offers**
  (introductory price, first-month discount, seasonal). Country-wide, no code,
  no dashboard. Pick one: *time codes here*, *price offers in Console*.
- Never implement a fake "discount" that charges through another channel. That
  is a Play policy removal.

## 2. Code types

| Type | Example | Grants | Used for |
|---|---|---|---|
| `trial_extend` | `MORE7` | +7 days Pro | Win-back, support gestures |
| `pro_grant` | `LAUNCH30` | 30 days Pro | Campaigns, "first 1000 users" |
| `pro_long` | `CREATOR12` | 365 days Pro | Creator payouts, your own account |
| `feature` | `LOOP7` | one feature, N days | Cheap giveaway, testing a perk |
| `coins` | `COIN50` | +50 coins | Contest prizes, apology credits |
| `referral` | `ARJUN10` | 30 days to redeemer + counts to creator | Creator program |
| `master` | (yours) | `pro_forever` on allowlisted devices | You |

Every type shares the same row shape, so the dashboard only needs one form.

## 3. Data model (Cloudflare D1 — SQLite)

```sql
CREATE TABLE codes (
  code          TEXT PRIMARY KEY,       -- normalised, upper, no dashes
  type          TEXT NOT NULL,
  grant_days    INTEGER,                -- NULL for lifetime/master
  grant_coins   INTEGER,
  feature_key   TEXT,                   -- 'custom_loop', 'no_ads', ...
  discount_pct  INTEGER,                -- display only, never charged
  max_uses      INTEGER,                -- NULL = unlimited
  per_user_max  INTEGER DEFAULT 1,
  uses          INTEGER DEFAULT 0,
  starts_at     INTEGER,
  expires_at    INTEGER,
  campaign      TEXT,                   -- 'launch-1000', 'diwali-2026'
  creator_id    TEXT,                   -- FK -> creators
  notes         TEXT,
  revoked       INTEGER DEFAULT 0,
  created_at    INTEGER NOT NULL
);

CREATE TABLE redemptions (
  id         TEXT PRIMARY KEY,
  code       TEXT NOT NULL,
  device_id  TEXT NOT NULL,   -- SSAID, survives reinstall
  install_id TEXT NOT NULL,
  redeemed_at INTEGER NOT NULL,
  ip_hash    TEXT,
  integrity  TEXT              -- Play Integrity verdict, for fraud review
);

CREATE TABLE creators (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  handle       TEXT,            -- @instagram etc.
  content_url  TEXT,            -- the post you approved
  code         TEXT UNIQUE,
  approved_at  INTEGER,         -- NULL = still under review
  reward_tier  TEXT DEFAULT 'none',  -- none | t1 | t25 | t50 | t100
  reward_until INTEGER,         -- end of their current Pro grant
  redeemed     INTEGER DEFAULT 0,     -- distinct devices, own device excluded
  max_uses     INTEGER DEFAULT 150,
  notes        TEXT
);

CREATE TABLE creator_grants (
  id         TEXT PRIMARY KEY,
  creator_id TEXT NOT NULL,
  tier       TEXT NOT NULL,
  months     INTEGER NOT NULL,
  granted_at INTEGER NOT NULL,
  until      INTEGER NOT NULL
);
```

`codes.uses` is a counter, not `COUNT(*)` — cheaper reads. `redemptions` exists
for "already used on this device" checks and for fraud review.

## 4. Redemption flow

```
Settings → Redeem code
  → POST /redeem { code, deviceId, installId, integrityToken }
  → server: rate limit → lookup → validate → insert redemption → increment
  → returns { plan, exp, signedEntitlement, message }
  → app stores entitlement, shows "Pro until 12 Jan"
```

**Rules the server enforces:**
- Code is normalised: uppercase, strip spaces/dashes, map `0→O`, `1→I`.
- Rejected if: unknown, revoked, not started, expired, out of uses, or this
  `deviceId` already hit `per_user_max`.
- **Rate limit:** 5 attempts per device per hour, 20 per day. Codes are 8 chars
  from a 32-char alphabet (`RT-XXXX-XXXX` ≈ 1.1 trillion), so brute force is
  hopeless even at 20/day.
- Response is a **signed entitlement**, same Ed25519 token the billing path
  produces. The app treats a code grant exactly like a purchase — one code path
  for gating.

**Identity without accounts:** `Settings.Secure.ANDROID_ID` (SSAID). Per-app,
no permission, **survives uninstall/reinstall**, resets on factory reset. Pair
with `installId` for logging. Be honest: a factory reset re-redeems — fine for a
promo, not fine for a permanent giveaway.

## 5. Your master code

**Never put it in the APK.** Anything in `app.so` is extractable in a minute.

- Server has `MASTER_CODE` (env secret) + a `master_devices` list of SSAIDs.
- Redeem succeeds **only** from an allowlisted device.
- Grants `pro_forever`, not visible in the shop, not logged under a campaign.
- Adding a new phone = one row in the dashboard.
- Rotate the code by changing the env var; the old one dies immediately.

## 6. Creator / referral program

**A creator gets paid in Pro months, and the ladder only ever goes up.**

| Tier | Trigger | Creator gets | Total, not extra |
|---|---|---|---|
| **t1 — join** | you approve their post (`content_url`) | **1 month Pro** | 1 mo |
| **t25** | 25 people redeemed their code | **3 months Pro** | 3 mo |
| **t50** | 50 people | **6 months Pro** | 6 mo |
| **t100** | 100 people | **12 months Pro** | 12 mo |

**Upgrade, not stack.** Hitting 50 means they're at 6 months total, not 1+3+6.
Otherwise one creator farms 22 months and you pay for it twice. The dashboard
extends `reward_until` to *now + tier months* (or to the existing end, whichever
is later, so an active grant never shortens).

**What the redeemer gets:** 30 days Pro. That's the hook — the creator's audience
gets something free, which is why they'll post it.

### Flow
1. Creator posts a Reel about the app, sends you the link.
2. You approve in the dashboard → their code is generated (`ARJUN10`) + 1 month
   Pro is granted.
3. They share the code. Each **distinct device** redemption increments `redeemed`.
4. The dashboard flags `t25 / t50 / t100` reached; you tap **Grant** (or set it to
   auto-grant) → `creator_grants` row + new `reward_until`.
5. Reward is Pro time only. Never cash — cash means tax, contracts and a
   different legal footing.

### Guardrails
- **Distinct device IDs only.** Same person reinstalling can't inflate the count.
- **The creator's own device is excluded** from `redeemed`.
- `max_uses` 150 per code, so a leak that spreads beyond the ladder tops out and
  can't be farmed past t100.
- Redemptions later revoked for fraud are **subtracted**; tiers can go down only
  that way.
- One code per creator. No regeneration to reset the count.
- Numbers shown to the creator in-app: "18 / 25 to your next month" — this is
  what makes them keep posting.

## 7. "First 1000 users"

Simplest honest version: **one campaign code, `max_uses = 1000`, `expires_at`
set**, granting 30 days Pro.

- Auto-stops at 1000. No overrun.
- Expect it on Telegram within a day — that's why the cap exists.
- Dashboard shows `uses / 1000` live.
- If you want it to feel exclusive, rotate the code weekly and post it once.

Unique per-user codes need accounts or emails — you're not doing accounts, so
don't.

## 8. Dashboard

**Host:** Cloudflare Pages (static) + Worker API. **Auth:** Cloudflare Access
(free ≤50 users) with your email + OTP — or a single admin token + TOTP. Never
ship admin credentials in the app.

### Screens
| Screen | What it does |
|---|---|
| **Overview** | Codes live, redemptions today, Pro grants active, campaign burn |
| **Codes** | Table: code, type, grant, uses/max, expiry, state. Search, filter, revoke |
| **Create code** | One form: type → grant → limits → expiry → notes. Generates the string or takes yours |
| **Code detail** | Per-code redemptions with device/first-seen/verdict, revoke button |
| **Creators** | Approve a post, see the code, ladder progress (1 → 25 → 50 → 100), grant the next tier, notes |
| **Master devices** | Allowlist for your `pro_forever` |
| **Campaigns** | Group codes under a name, see total burn |
| **Danger zone** | Revoke all codes, revoke all Pro grants, export CSV |

**Nice-to-have later:** revenue chart from Play, ad eCPM from AdMob, coin
economy health (coins minted vs spent). Don't build before you have numbers.

## 9. Abuse & legal

- Every grant has an expiry except `pro_forever` (only on your devices).
- Revocation propagates on next entitlement refresh (≤24 h; instant if the app
  is online).
- Ads and coins are **not** affected by a revoked code — only Pro time.
- Terms: "Promotional codes may be revoked if abused. Codes have no cash value,
  are non-transferable, and cannot be combined."
- Don't run a code giveaway with prizes that look like cash — that's a lottery in
  some jurisdictions.

## 10. Build order (after the Pro/coins work)

1. D1 schema + `/redeem` + `/entitlement` sharing one signer.
2. ✅ **App: "Redeem code" sheet, wired to `Entitlements`** — shipped locally
   (§12), same call site for the server.
3. ✅ **Dashboard: codes list + create + revoke** — shipped in-app; the web
   version is still to build.
4. Creators + campaigns views.
5. Master device allowlist (the current master code is debug-only).
6. Rate limits + Play Integrity check on `/redeem`.
7. Analytics: redemptions per day, per campaign.

## 11. Open questions

1. **Creator ladder auto-grant or manual?** Recommended: manual at first — you
   want to eyeball the redemptions before handing out a year.
2. **Codes during the trial** — allowed (extends Pro), or only after it ends?
3. **Caps after trial** — 25 audios / 2 playlists confirmed? Or higher (50/3)?
4. **Campaign name + size** for the first-1000 run.
5. **Redeemer reward for creator codes** — 30 days Pro? Longer = more incentive
   for the creator, more free Pro for strangers.

---

## 12. Phase 1 — shipped local engine (2026-11-03)

No Worker, no D1, no network. The phone is the server, which is enough to test
every redeem, grant, expiry and dashboard flow end to end.

| File | Job |
|---|---|
| `lib/promo.dart` | `PromoEngine`: registry, redemption log, normalise, validate, grant. The single call the UI makes is `redeem()`. |
| `lib/redeem_sheet.dart` | Bottom sheet: code field → `PromoEngine.redeem()` → sentence. No other logic. |
| `lib/code_admin.dart` | In-app dashboard: status card, built-ins, codes list (copy/revoke/delete), create sheet, redemption log, danger zone. |
| `lib/entitlements.dart` | New, separate grant fields (`grantUntilMs`, `grantLifetime`, `grantCode`) and `codeGrantActive`. `isPro` now = store **or** debug **or** grant **or** trial. |
| `lib/library_sync.dart` | Mirrors `grant` next to `trialStartMs`, adopts it on reinstall. |

### Codes available now

| Code | What it does | Build |
|---|---|---|
| **`ANSHUL2012`** | Lifetime Pro on this device, and unlocks the dashboard | debug only |
| **`FREEVERSION`** | Clears store state, debug flag, grant **and ends the trial** → real Free tier (caps + ads) | debug only |
| `RT` + 8 chars | Any code created in the dashboard | any build |

Both built-ins sit in a `kDebugMode` branch, so `flutter build apk --release`
compiles them out. A release build gets its master behaviour from `/redeem` +
an SSAID allowlist instead — the APK never carries the string.

### How to test right now

1. Settings → **Redeem a code** → `ANSHUL2012` → Pro card flips to "Pro ·
   lifetime code", ads flag off, caps lifted.
2. Settings → **Code dashboard** → New → 1 day Pro, max uses 3, custom code
   `TEST1` → copy it.
3. `FREEVERSION` → back to Free (trial retired too, so caps and ads are real).
4. Redeem `TEST1` → Pro until tomorrow; redeem it again → "Already used on this
   device".
5. Dashboard → revoke `TEST1` → a second phone (or cleared log) gets "That code
   was switched off".
6. Reinstall the app, re-link the folder → the grant comes back from
   `.reeltunes-library.json`.

### Storage and what it deliberately does not do

- Prefs: `promoCodes`, `promoLog`, `promoDeviceId`, `adminUnlocked`; the grant
  itself lives in the entitlement keys, not in the code store.
- The mirror is a plain file in the user's folder, so a determined user can edit
  `grant.untilMs` and give themselves Pro. Accepted for now: the alternative is
  a server round trip on every launch. The server phase signs the grant
  (Ed25519) and the mirror becomes a cache, not an authority.
- No rate limiting yet — brute force of `RT…` (32^8) is already hopeless, and
  the local log is only a test aid. `/redeem` will add 5/hour and 20/day.
- Creators, referrals, campaign burn and master-device allowlists are **not** in
  phase 1; they need the shared database.

### What changes when the Worker lands

Only `PromoEngine.redeem()` gains a network branch (POST `/redeem` →
`{plan, exp, signedEntitlement}`), and `code_admin.dart` switches its list from
the local registry to `GET /admin/codes`. The UI, the bottom sheet, the
`Entitlements` fields and the mirror format stay exactly as they are.
