# ReelTune — Free vs Pro feature contract

> Reference this before shipping any gating. UI currently ships as FULL PRO
> for development; restrictions get switched on via feature flags when the
> player + library are stable. One boolean owns all gating: `AppStore.fullPro`.

## Free tier
| Feature | Limit / rule |
|---|---|
| Track count | 50 max |
| Folder (playlist) count | 5 max |
| Loop modes | Off · 3x fixed · Infinite |
| Playback | Full: play / pause / seek / skip / shuffle-listens |
| Ads | Shown: banner + (interstitial on 5th import) later |
| Grid views | Free |
| Custom folder emoji | Free |
| Storage location | Free |
| On-device | No cloud, no login. Uninstall deletes everything, either tier. |

## Pro ($2.99/mo · $19.99/yr)
| Feature | Detail |
|---|---|
| Track & folder limits | Unlimited |
| Loop modes | **2-4x range** (random count each enqueue) · **Smart loop** |
| Ads | None |
| Equalizer | On-deviceJustAudio EQ once player HTML is in (globally stored preset per folder) |
| Sleep timer | Countdown that fades, then pauses |
| Crossfade | On automatic advance during loops/queue moves |
| Extra UI gestures | Batch multi-select for moves/renames later |

## Gating checklist (when switch lands)
- [ ] Add-reel blocked at 51st track (free): show upgrade sheet, keep app functional.
- [ ] New-folder blocked at 6th (free).
- [ ] Range/Smart chips show ⭐ and open upgrade sheet on tap (free).
- [ ] Equalizer + sleep timer rows in Settings deep-link upgrade (free).
- [ ] Restore purchases wired via in_app_purchase.
- [ ] Track 5th import interstitial later per ads plan.

## Licensing ledger (pre-launch)
- **youtube_dl-android (part of ytdlp_flutter on Android) is GPL-3.0.** Our APK
  uses it for on-device extraction ⇒ distribution of the binary implies review
  of GPL obligations before any public monetized release. Options at that time:
  (a) open-source the app repo (GPL-compatible, simplest),
  (b) run extraction in a separate GPL process (yt-dlp CLI itself is
      *Unlicense/public-domain* — arguably cleaner), or
  (c) keep extraction server-side for store builds only.
  Not a blocker for dev/testing/Play closed tracks. Revisit BEFORE public launch.
- yt-dlp itself: public domain (Unlicense) — no obligations from the engine.
- Fallback wrapper (Cobalt on Vercel): Cobalt is AGPL-3.0 — self-hosted use is
  fine; if we ever expose the wrapper publicly as a service, AGPL applies to
  our frontend modifications. Keep the wrapper minimal/modless or accept AGPL.

