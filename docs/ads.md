# ReelTunes — Ads: network choice, slots, and the rules that decide whether they survive review

> Free tier only. Nothing shows during the 7-day trial, and nothing shows for Pro.
> Every ad in this plan is **outside the playback path**: no ad ever interrupts
> audio, sits on the player, or blocks a download that is still running.

---

## 1. Which network to use

| Network | India fill | eCPM (IN, rewarded) | Effort | Verdict for ReelTunes |
|---|---|---|---|---|
| **Google AdMob** | **Best** — AdSense demand, ~99 % fill | $1.50–4 (₹130–350) | Low: one SDK, UMP consent built in, SSV for rewarded | **Start here** |
| **AppLovin MAX** | Medium on its own, good once mediated | $3–8 on US/EU, $1.5–3 IN | High: extra SDK, ad review, network keys | Add after 5–10k DAU, as a *mediation layer* |
| **Unity LevelPlay (ironSource)** | Medium | $2–5 (video-heavy) | High: Unity account, adapter juggling | Alternative to MAX, not both |
| **Meta Audience Network** | Good in India (Facebook-heavy) | $2–5 | Medium: business verification, bidding setup | Good as a **mediation source inside AdMob** |
| **InMobi** | Very good — India-HQ demand | $1.5–4 | Medium | Good mediation source for IN traffic |
| **Pangle (ByteDance)** | High eCPM numbers, **skip** | — | — | Privacy/policy risk, looks bad in a Play listing |
| **Amazon APS** | Weak unless Fire TV/tablet | — | — | Not worth it here |

**The honest answer to "where do I get the best high-paying ads":** the network
is not the lever for an app with a few hundred DAU — **fill rate is**. A "high
eCPM" network that fills 40 % of your impressions earns less than AdMob at 99 %
fill. Mediation (MAX or AdMob mediation) is what actually raises revenue, and it
only pays off once you have consistent impressions. So:

1. **Now → launch:** AdMob only, with UMP consent. Banner + interstitial +
   rewarded. One SDK, smallest APK, no mediation configuration to debug.
2. **After ~5k DAU:** turn on **AdMob mediation** and add AppLovin + Meta AN +
   InMobi as ad sources. Same code, no UI change — only the AdMob adapter SDKs
   and the ad-unit setup in the dashboard.
3. **Only if revenue justifies the complexity:** move to AppLovin MAX.

AdMob also gives you the pieces this plan needs: **server-side verification
(SSV)** for rewarded coins, **UMP** consent, per-country **eCPM floors**, and
`apps.txt` verification. Nothing else does all four for free.

### Meta Audience Network in 2026 — a bidder, not a network

FAN is still alive and shipping (SDK 6.22.0, July 2026), but three facts decide
how it fits ReelTunes:

1. **Bidding only since 2021.** There is no "integrate FAN directly and get a
   waterfall" path on Android anymore. It only works as an **ad source inside a
   mediation layer** — for us, AdMob mediation.
2. **It cannot be set up before launch.** Onboarding needs a **live Play Store
   link** (an Early Access listing does not qualify), plus Meta Business Suite,
   a finance admin, 2FA, a payout account with a tax ID, app **ownership
   verification**, and **up to 72 h** of app review. Ads only serve after payout
   info is added — so this is post-launch work by definition.
3. **No AdMob-style SSV for rewarded.** FAN rewarded has no server-to-server
   reward callback we can verify on the Worker, so it must never become the coin
   source. Coins stay on **AdMob rewarded + SSV**; FAN can only *bid* on that
   same rewarded unit.

**Integration when we do it:** add Meta Audience Network as an AdMob bidding
source (`com.google.ads.mediation:facebook:6.22.0.1`, FAN SDK 6.22.0, min API
24), create one property + placement in Monetization Manager, list Meta in
`app-ads.txt`, and add Meta to the UMP / US-state privacy disclosures. Formats
map 1:1 to what we already ship (banner, interstitial, rewarded).

**Verdict:** worth testing **after** AdMob has a measured baseline, as a second
bidder on the banner and interstitial units — it raises competition for Indian
inventory without a UI change. It is not a replacement for AdMob, and it can
never replace it for coins. Payouts are monthly (~21st) with a **$25**
international minimum via PayPal/local bank (**$100** by wire), so early revenue
will sit in the account for a while.

### What a realistic Indian eCPM looks like (₹ per 1,000 impressions)

| Format | India | US / EU |
|---|---|---|
| Anchored banner | ₹15–60 | ₹80–250 |
| Interstitial | ₹60–200 | ₹250–700 |
| Rewarded video | ₹130–350 | ₹400–1,200 |

Sanity check at **1,000 DAU** (3 banner impressions + 1 interstitial + 0.3
rewarded per user/day): ≈ **₹230–300/day ≈ ₹7,000–9,000/month ≈ ₹7–9 per DAU per
month**. That is the number to plan against — it is roughly *two* monthly Pro
subs per 100 free users, which is why pro conversion, not ad CPM, is the real
revenue lever.

---

## 2. The three slots

### Slot A — the download ad (interstitial)

**Where:** fires *after* the file is written and the library row appears, on the
"saved" moment — never before or during extraction.

Why after: an ad that precedes the download makes a slow extraction feel like
the ad's fault, and if extraction fails you have shown an ad for nothing. After
is the moment the user got what they came for.

**Rules**
- Free tier only (`Entitlements.showAds`), never during the trial.
- **One per download, maximum**, and a **60 s floor** between two interstitials:
  if someone saves three reels back to back, they see one ad, not three.
- **Skip the very first download of the install** (it is the "does this even
  work" moment) and skip if the last interstitial was < 60 s ago.
- Preload the next one right after dismissal so the ad never adds a spinner.
- If no ad is loaded, **save anyway** and move on — an unfilled ad must never
  block a download.

**Why not every download, no exceptions:** Google's ad-placement policy treats
"excessive" or task-blocking interstitials as a policy violation, and Play
reviewers do open the app and try the main flow. The 60 s floor costs you almost
nothing in impressions (users rarely save more than 2–3 in a minute) and is the
difference between "downloaders do this" and "this got my account suspended".

### Slot B — the sticky bar above the mini player

**Where:** a pinned `AnchoredAdaptiveBanner` in the scaffold's bottom area,
**directly above the mini player bar**, on the library screen and the playlist
screens. Always present on the free tier.

Why this placement works: it is the one rectangle that is on screen the whole
time the user is browsing, and it never covers a control. It is Spotify's model
without Spotify's audio interruption.

**Rules**
- Hidden when `Entitlements.isPro` (covers trial, Play trial, and paid).
- Hidden when the full-screen player is open — no ads during playback, as
  decided.
- Hidden while the Add-reel sheet, the paywall, or the first-run sheet is up:
  one full-screen task at a time.
- **≥8 dp gap** between the banner and the mini bar, and no button adjacent to
  it. Accidental-click rate is the first thing AdMob measures.
- Reload with exponential backoff on failure (30 s → 2 min → 5 min), never in a
  loop.
- One banner instance for the whole app, moved between screens — a banner that
  is re-created on every navigation burns requests and can look like click
  farming.

### Slot C — the always-there ad at the end of the list

**Where:** a card after the **last track row** in the library list:

```
[ ... last track ... ]
┌───────────────────────────────┐
│ Sponsored                     │   ← label always visible
│ [ 320×100 / native unit ]     │
└───────────────────────────────┘
```

**Rules**
- **Labelled "Sponsored".** Never styled like a track row — a fake track is a
  deceptive-ad violation and users tap it by accident, which gets the ad unit
  flagged (not just the ad).
- Use a **native** unit when you have the appetite for it (title + image + CTA
  in the app's own typography); a plain banner card is the v1 and always fills.
- It sits *after* the last row, so it never pushes content down while the user
  is reading. No scroll-triggered interstitial — that reads as a trap.
- Shown on the free tier only, and not on an empty library (nothing to end).

Two smaller add-ons that cost nothing to build and earn quietly:
- **End of the playlist list** — same card, on the home screen's playlist
  section.
- **Settings footer** — a banner under the last row. It is a low-traffic screen;
  treat it as free inventory, not a design decision.

### Explicitly **not** doing
- No ad on the splash, on app open, or between screens.
- No ad over the player controls, the seek bar, or the "saved" toast.
- No ads for Pro, ever, including the trial.
- No "watch an ad to unlock this track" on existing library items — that turns
  the free tier into a hostage situation and contradicts "nothing is ever
  hidden or deleted".

---

## 3. Coin economics (why rewarded is the good one)

Rewarded video is worth **3–6× a banner** per impression *and* it is the only
format the user chooses. 1 coin per **SSV-verified** completion, daily cap 15–20,
spent on time-limited perks (see `docs/free-vs-pro.md` §3). The client's
`onUserEarnedReward` is honoured for UI feedback only; the balance is credited by
the SSV callback on the Worker. Anything else is farmable with a patched APK.

---

## 4. Compliance checklist (do these before the first ad shows)

- [ ] **UMP consent** (EEA/UK/CH) before any ad request; non-personalized
      fallback; a **"Ad privacy settings"** row in Settings that re-opens the
      form — required, and easy to forget.
- [ ] **Data Safety** declares: device or other IDs (advertising ID), app
      interactions, approximate location (derived from IP), purpose
      *Advertising or marketing*, shared with Google.
- [ ] **Privacy policy** names AdMob, the ad ID, and how to reset it
      (`Settings → Google → Ads`).
- [ ] **`app-ads.txt`** at the developer website root, verified in AdMob. Do it
      before launch; unverified inventory is worth less.
- [ ] **Content rating 13+**, not child-directed. If it were, personalized ads
      would be off the table entirely.
- [ ] **Test ad units** in debug (`ca-app-pub-3940256099942544/...`) and real
      units only in release — clicking your own live ads is an instant ban.
- [ ] **AdMob app ID** in `AndroidManifest.xml` (`com.google.android.gms.
      ads.APPLICATION_ID`) — the SDK crashes on start without it, and it is not
      the same value as the ad unit ID.
- [ ] **eCPM floor** left at 0 initially; set floors per country only after you
      have ≥2 weeks of fill data.
- [ ] **No ads for new installs during the trial.** `Entitlements.showAds` is
      already false then; assert it in the ads layer too, defence in depth.

---

## 5. Build order for the ads work

1. ~~`google_mobile_ads` (**9.2.0**), AdMob app ID, manifest meta-data, UMP flow,
   `lib/ads.dart` with one banner controller + one interstitial + one rewarded.~~
   **Done for the banner:** SDK 9.2.0, sample app id + test banner unit in
   `AndroidManifest.xml` / `lib/ads.dart`, UMP consent + "Ad privacy choices"
   in Settings. Interstitial/rewarded still parked.
2. ~~**Slot B** (sticky banner)~~ — **done**: `AdBanner` above `MiniBar`, gated
   on `Entitlements.showAds`, backoff on no-fill. This validates fill and layout
   on the real device before anything else is built on top.
3. **Slot A** (post-download interstitial) with the 60 s floor and the
   first-download exemption.
4. **Slot C** (end-of-list card).
5. Then rewarded + SSV + the coin ledger (needs the Cloudflare Worker).

Release switch-over (before production): replace the sample app id
(`ca-app-pub-3940256099942544~3347511713`) and build with
`--dart-define=ADMOB_BANNER_UNIT=ca-app-pub-…/…`; `usingLiveAdUnit` in
`lib/ads.dart` reports whether a real unit is in use.

Expected app-size cost: ~1.5–2.5 MB for the AdMob SDK, plus ~300 KB per
mediation adapter added later.

---

## 6. Numbers to watch after launch

| Metric | Where | Target |
|---|---|---|
| Fill rate | AdMob | > 95 % (IN) |
| Interstitials per DAU | own analytics | 0.4–0.8 |
| eCPM by format, by country | AdMob | compare to §1 monthly |
| Accidental clicks | AdMob invalid-traffic warnings | **0** — this is the health signal |
| Ads per session | own analytics | ≤ 4 |

If invalid traffic warnings appear, the first suspect is always Slot C sitting
too close to a tappable row, or a banner overlapping the mini player.
