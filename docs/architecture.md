# ReelTune — Architecture

> Music player for short-form video audio. Share a reel → audio saved locally → play offline.
> 100% on-device. No cloud, no login, no server DB. Uninstall = everything gone.

## Locked decisions
- **Local storage strategy** (not link-streaming): on share, we extract & save the audio file.
- Android-first dev & testing; iOS code kept cross-platform for a future Mac build.
- Free/premium tiers enforced locally via:
  - **Free**: 50 tracks max, 5 playlists max, basic looping (fixed count + infinite), ads.
  - **Premium ($2.99/mo · $19.99/yr)**: unlimited tracks & playlists, range looping
    (X–Y× with random count), equalizer, sleep timer, crossfade, no ads.

## Packages
| Concern | Package |
|---|---|
| State / DI | riverpod |
| Share-sheet intake | receive_intent (share filter ACTION_SEND text/plain URLs) |
| Audio extraction | ffmpeg_kit_flutter community fork (`ffmpeg -i <video> -vn -c:a aac track.m4a`) |
| Playback + queue | just_audio + audio_service (lock-screen / notification controls) |
| Local persistence | hive (tracks, playlists, settings) — no SQL server |
| Loop engine | custom service on top of just_audio LoopMode + custom range logic |
| Ads | google_mobile_ads (free tier only) |
| Billing | in_app_purchase (premium) |

## Module map
lib/
  main.dart
  models/
    track.dart          # id, title, sourceUrl, filePath, duration, addedAt, playlistIds
    playlist.dart       # id, name, trackIds, createdAt
    loop_config.dart    # { none | fixed(n) | range(min,max) | infinite | smart }
  services/
    share_intake.dart   # receives ACTION_SEND url, parses platform (tiktok/ig/yt/web)
    extractor.dart      # ffmpeg extraction pipeline w/ progress + failure states
    library.dart        # track+playlist CRUD, storage-quota checks
    player.dart         # just_audio/audio_service wrapper
    looper.dart         # range/random/smart loop logic
    entitlements.dart   # free/premium gating
  ui/
    library/            # home: tracks list + playlists
    player/             # now playing screen w/ loop controls
    playlists/
    settings/

## Extraction flow
1. Share sheet → open app with URL text.
2. `share_intake` normalizes URL (strip query Params, detect host).
3. Import screen (2 lines: title, playlist picker) → Import.
4. `extractor` runs ffmpeg on the *downloaded reel video*:
  与现实: platforms don't expose direct video mp4.
   Phase 1 (dev/testing): user picks a local video file or we accept direct mp4 URLs;
   pipeline is ffmpeg regardless, so only the *fetch* step changes later.
5. On success → save `track.m4a` under app-docs/audio/, add Track row to Hive.
6. Failure → friendly error card, nothing stored.

## Loop engine details
- fixed(n): LoopMode from just_audio won't count plays → we count via playerState
  transitions and stop after n completes.
- range(min,max): random pick in [min,max] per session or per enqueue.
- infinite: native LoopMode.one.
- smart: heuristic (track length < 30s → fixed 3, else infinite) — v2, data-driven later.

## Testing on device
- Enable Developer options → USB debugging on phone.
- `flutter run` → hot reload every save.
- Debug instrumentation: verbose log of intake → extraction → play lifecycle,
  since share-sheet flows behave differently across TikTok/IG/YouTube apps.
