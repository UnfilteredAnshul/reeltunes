# ReelTunes — Google Play compliance snapshot

> Prepared 2026-10-30. Scope: current codebase + planned ads. This is an internal
> risk assessment, **not** an official Google score — Play review is pass/fail and
> most enforcement happens after publication (DMCA/IP complaints).

## Headline

| Measure | Value |
|---|---|
| Submission readiness (weighted rubric below) | **~43%** |
| Code / manifest-level compliance | **~75%** |
| Hard blockers | IP/copyright exposure of link extraction; GPL-3.0 obligations of the bundled engine |
| Cheapest next gain | Release signing + AAB (mechanical, no product decision) |

## Scoring breakdown

| Area | Weight | Score | Already compliant | Missing |
|---|---|---|---|---|
| IP / content | 20 | 5 | SAF/media import path is clean | Link extraction from TikTok/IG/YouTube is the headline feature |
| Packaging & technical | 15 | 6 | targetSdk 36, minSdk 24, arm64, valid app id | Release signing uses the debug key; no AAB; 16 KB page support unverified |
| Permissions & APIs | 15 | 13 | No storage permissions; FGS `mediaPlayback` declared; media session wiring correct; no restricted permissions | FGS declaration in Play Console; ads will add `AD_ID` |
| Data safety & privacy | 15 | 7 | Nothing collected today; all data on-device | No privacy policy; no Data safety form; ads will add collection/sharing |
| Licensing (GPL) | 10 | 4 | yt-dlp itself is public domain (Unlicense) | `youtubedl-android` (Python + ffmpeg) is GPL-3.0; obligations unresolved |
| Store listing & metadata | 10 | 2 | App name and in-app icon exist | No 512x512 icon, feature graphic, screenshots, descriptions, content rating, target audience; "ReelTunes" trademark not checked |
| Monetization | 10 | 3 | Nothing charged yet | No Google Play Billing for Pro; price copy live in Settings; ads not implemented |
| UX / behavioral | 5 | 3 | No deceptive UI, no system-UI mimicry | Dev-phase raw error toasts |

**Total: 43 / 100.** About 11 of the missing points are cosmetic/process items
(store listing assets, Console forms) rather than code.

## What adding ads changes

- **Data safety stops being "no data collected."** Ad SDKs collect a device/advertising
  ID → declare collection **and sharing**, and a **privacy policy becomes mandatory**.
- **`com.google.android.gms.permission.AD_ID`** is merged in by AdMob for target 33+;
  honour the user's advertising-ID reset/opt-out (Advertising ID policy).
- **Ads policy** ([Play Ads](https://support.google.com/googleplay/android-developer/answer/9857753)):
  ads must be clearly distinguishable from app content, easily dismissible, never
  unexpected full-screen, never outside the app (lock screen/notifications), and must
  not interfere with normal use.
- **"Interstitial on 5th import"** is acceptable only if closable, not shown during
  extraction/loading, and never on app launch. Banners must not cover the MiniBar or
  transport controls.
- **"Contains ads"** must be declared in the store listing (also feeds content rating).
- **EEA/UK/CH:** Google's EU user consent policy requires a UMP consent flow before
  personalised ads.
- **Target audience 13+/18+.** If the app is ever declared child-directed, only
  Families self-certified ad SDKs are allowed.
- **AdMob publisher policies are a second gate:** content that facilitates infringement
  can get ads limited or the AdMob account suspended even if Play keeps the app.
- **Pro "no ads"** must be sold through Google Play Billing, and the ad-free promise
  must be literally true.

## Where the missing points are

- Decide extraction for the store build → up to **+12**
- Release signing + `flutter build appbundle` + versionCode bump → **+8**
- GPL stance / source publication → **+5**
- Privacy policy + Data safety + consent → **+7** (with ads)
- Ads compliance pack: AD_ID, ads declaration, placement review, UMP → **+6**
- Listing assets, content rating, target audience → **+8**
- Polished user-facing errors → **+2**

Realistic ceiling: keeping link extraction leaves a permanent complaint-driven
removal risk, so the app cannot reach "safe 100%"; the import-only variant can
reach roughly 95%+.

## Bottom line

The code is in decent shape for Play (minimal permissions, correct media/FGS wiring,
no data collection today). The blockers are product/licensing/release decisions, not
Flutter code: extraction IP exposure, GPL-3.0, and the still-unconfigured release
pipeline.
