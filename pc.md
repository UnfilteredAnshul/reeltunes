# Project: ReelTunes

## Project Identity
- **Name:** ReelTunes · `applicationId com.buildwithanshul.reeltunes` (permanent — cannot change after the first Play upload) · Dart package `reel_tune` · project folder `E:\Projects\ReelTune`.
- **What it is:** Android Flutter music player for short-form video audio. Paste a TikTok / Instagram Reel / YouTube Shorts link → audio is extracted **on-device** by a bundled CPython + yt-dlp engine → the file is written into the user's own audios folder and played offline with loop/shuffle controls. Also imports existing phone media through SAF (videos play their own audio, nothing copied).
- **Pitch:** 100% on-device library. No cloud, no login, no server, no database. The audios folder is the source of truth: drop a song in with a file manager and it appears; uninstall the app and the files plus a portable copy of the playlists stay behind.
- **Status (2026-11-03):** debug build installed and clean-launching on a Realme RMX3381 (ColorOS, Android 13 / SDK 33). Engine runs end-to-end (Python → SSL → yt-dlp 2026.10.26). Since the last doc: free/Pro gating is implemented (`lib/entitlements.dart` — trial clock, 25 audios / 2 playlists, Smart 3–6, custom-range paywall, 3-day and 1-day trial reminders, debug tier switches) and RevenueCat billing is wired (`lib/billing.dart` + paywall/Settings). **Not built since these changes; no device test yet.**
- **Production status:** internal debug only. No release signing, no AAB, no ads, no Play Console products, no privacy policy yet. See "Production readiness (open)".

## Tech Stack
- **Flutter** 3.47.8 (`C:\src\flutter\bin`), Material 3, Dart `^3.9.0`.
- **Android:** `minSdk 24`, `targetSdk = flutter.targetSdkVersion` (36), SDK 36 at `E:\Android\Sdk`, NDK 28.2.13676358, JDK from Android Studio.
- **Deps (pubspec.yaml):** `just_audio` ^0.10, `just_audio_background` beta.17 (→ `audio_service` 0.18.19), `audio_session`, `receive_intent`, `reorderable_grid_view` 2.2.8, `path_provider`, `shared_preferences`, `url_launcher`, `file_picker` 13.x (**nonstandard fork**: `pickFiles` returns `List<PlatformFile>`, `getDirectoryPath()`), `purchases_flutter` 11.0.0 (RevenueCat → Play Billing 9.1.0; needs Kotlin ≥ 2.1 and compileSdk ≥ 35 — both already true), `cupertino_icons`.
- **Not yet added:** `google_mobile_ads` (planned, see `docs/ads.md`).
- **Removed:** `ytdlp_flutter` / `youtubedl-android` (GPL-3.0, ffmpeg payload, runtime yt-dlp updates). Nothing GPL ships now except `libcrypt` (LGPL-2.1, unmodified, separate `.so`).
- **Device:** adb `E:\Android\Sdk\platform-tools\adb.exe`, serial `PBFIINYP7LGE4PPV`, pattern lock — user unlocks and tests manually; `svc power stayon true` set.
- **No storage permissions at all.** All media and folder access goes through SAF (`content://` URIs).

## Design System
- Accent `Color(0xFF0A5CD6)` via `ColorScheme.fromSeed`, light/dark/system.
- **Bottom sheets only** (ColorOS renders dialog scrims invisible). No `showDialog` in the app — the old first-run `AlertDialog` is now `FirstRunSheet`.
- Splash = coin loader + "warming up your library…" only, minimum 1.4 s.
- Display name **ReelTunes**; physical folder `ReelTune Audios` (deliberately different spelling, existing data).
- **One sort+filter sheet:** left half SORT (Manual / Name / Date added + ascending), right half DATE ADDED (Any time / Today / Last 7 days / Last 30 days). Both apply live; sliders (`Icons.tune`) turn primary when something is active.
- **Playlists wording everywhere** (model is still `Folder`): chip strip, `Playlists (N)` header with `AnimatedRotation` chevron. **The playlist list/grid toggle only exists while the section is expanded** — a collapsed section has nothing to lay out.
- **Guide:** dismissible banner "First time here? Here is how it works." above the chip strip → opens a 7-step bottom sheet (also reachable at the top of Settings). Banner stays until dismissed (X or opening the guide).
- **Idle nudge:** after 7 s of stillness the import FAB expands into the "Import audio" pill for ~1.8 s and **repeats forever** while idle; resets on any touch/scroll/search; paused when audio is playing or the page isn't current. The pill occupies a fixed-width right-aligned slot, so the **"Add reel" button never moves**.
- **Top toast** (`lib/top_toast.dart`): slides in under the status bar, auto-dismisses after 2.6 s, tap to dismiss, never blocks input. Replaces bottom snackbars for failures.
- Active-state accents like Spotify: shuffle / repeat / filter icons in `scheme.primary`.

## Database Schema
No SQL. Two local stores + one mirrored file:
1. **`library.json`** (app documents dir, `app_flutter/library.json`) — fast local source of truth:
   ```json
   { "tracks": [ { "id","title","source","path","fileName","durationMs","addedAtMs","folderIds": ["f…"] } ],
     "folders": [ { "id","name","emoji" } ] }
   ```
   - `path` is a **`content://` URI** (audios folder or SAF import) — no raw paths since the SAF change.
   - `fileName` is the bridge between the folder and the library, and the key used by the mirror/restore.
   - `source`: `'TikTok' | 'YouTube' | 'Instagram' | 'web'` (extracted) · `'file' | 'video'` (imported).
2. **`.reeltunes-library.json`** inside the audios folder — portable mirror (folders + `{name,title,source,durationMs,addedAtMs,folderIds}`). Written ~700 ms after every library change; read back on the first launch after a reinstall, matched to files by name.
3. **SharedPreferences:** `themeMode`, `folderView`, `trackView`, `saveFolder` (legacy display string), `firstRunDone`, `rangeMin/rangeMax`, `confirmDelete(true)`, `playDuringCalls`, `sortBy`, `sortAsc`, `guideBannerDismissed`, `playlistsExpanded` (session), `loopHistory` (last 12 custom-range counts), **`hiddenFileNames`** (files removed with "Remove from ReelTunes" — stops a folder scan from re-adding them).
   - Android-side prefs (`reeltunes_folder`): SAF tree URI + resolved root document id.
   - Not persisted on purpose: search text, date filter.

## Storage model (SAF audios folder)
- The user links a folder once (`FolderBridge.link`, `ACTION_OPEN_DOCUMENT_TREE`, read+write persistable grant). If they pick `Download`, the app steps into / creates `ReelTune Audios`.
- **Why:** Android 13+ denies raw paths in Download/DCIM/Movies even with `READ_MEDIA_*` (verified: `touch /sdcard/Download/...` → permission denied as the app UID). SAF is the only Play-safe route.
- **Save path:** yt-dlp writes into the app cache → `FolderBridge.save` copies bytes into the folder (optionally a playlist sub-folder). The cache copy is deleted.
- **Discovery:** `LibrarySync.sync()` runs on launch and on `AppLifecycleState.resumed` — files added by a file manager appear, files deleted outside the app disappear (only entries under the linked tree are considered).
- **Remove vs delete:** "Remove from ReelTunes" unlists and remembers `fileName`; "Delete audio and file" asks once (checkbox + Settings switch `confirmDelete`) and deletes the document.
- **Reinstall:** the grant is revoked by Android, so the user links the same folder once → mirror restores playlists/titles/order, scan restores files.

## Engine (extraction)
- **Payload (all in the APK, no runtime downloads):** CPython 3.12 (PSF-2.0), QuickJS (MIT, used via yt-dlp `--js-runtimes quickjs`), yt-dlp **2026.10.26** zipapp (Unlicense), zlib/OpenSSL/etc. from the CPython distribution. No ffmpeg.
- **GPL strip:** `tools/repack_engine.py` rebuilds `libpython.zip.so` without readline/history/gdbm and the GPL-linked modules; verified 0 GPL strings. yt-dlp is Unlicense. `libcrypt` (LGPL-2.1) ships unmodified.
- **Packaging:** `android/app/src/main/jniLibs/<abi>/` holds `libpython.so`, `libpython.zip.so`, `libqjs.so`, `libytdlp.so` for arm64-v8a / armeabi-v7a / x86_64. Requires `extractNativeLibs="true"` + `useLegacyPackaging=true`.
- **`EngineBridge.kt`:** unpacks the stdlib zip to `files/python-3.12/usr`, materialises the zip's symlink stubs (`libz.so.1` ships as 13 bytes of text) via `Os.symlink`, then runs `libpython.so` with `PYTHONHOME=<usr>`, `LD_LIBRARY_PATH=<usr>/lib`, `SSL_CERT_FILE=<usr>/etc/tls/cert.pem` (without it every request dies with `CERTIFICATE_VERIFY_FAILED`), `TMPDIR=cache`. Streams stdout/stderr, reports progress, supports cancel, errors carry the last stderr line.
- **Dart side:** `lib/engine.dart` (channel wrapper), `lib/extractor.dart` (naming, cache→folder save, Track creation). **yt-dlp updates only ship through Play releases**, never at runtime.

## Auth Flow
None. `AppStore.I.fullPro` is hard-coded `true`; free/Pro gating contract in `play-compliance.md` / `docs/free-vs-pro.md`. Ads/Play Billing not started.

## Routing (screens)
- **RootScreen (main.dart)** — instant `runApp`; store init + ≥1.4 s splash; `LibrarySync.init()` (grant → restore → scan); first-run `FirstRunSheet` (folder picker) when nothing is linked; share-intent listener; lifecycle observer re-scans on resume.
- **LibraryScreen (library.dart)** — AppBar: search toggle · New playlist · Settings. FAB column: import pill (icon ↔ "Import audio") above "Add reel"; while rearranging, a single "Save order" FAB. Body: rearrange banner → guide bar → chip strip → `Playlists (N)` + collapse (+ list/grid toggle only when expanded) → playlists (grid/list, drag-reorder) → new-playlist row → tracks header (`All audios (N)` / `In "<name>" (N)`, sort+filter, view toggle) → track list/grid → bottom spacer. MiniBar when something plays; tap opens the player without restarting the queue.
- **PlayerSheet (sheets.dart)** — playing-from caption, title, source, slider, ✨ Smart / Custom range chips, animated transport (shuffle, prev, play/pause, next, repeat ∞).
- **AddReelSheet** — URL (+`initialUrl` from share), optional name, playlist multi-select, "Extract & save audio", "Or import an audio file instead". Refuses to run when no folder is linked ("Link your audios folder first").
- **Track long-press menu** — Rearrange (grid) · Rename · Manage playlists · **Remove from ReelTunes** (keeps the file) · **Delete audio and file** (red, confirmed).
- **Folder/playlist long-press menu** — Rearrange (grid) · Shuffle · Rename · Edit emoji · Delete.
- **Settings** — Guide card (top) · Appearance · Storage (audios folder, re-scan, uninstall explanation) · Playback (confirm before delete, keep playing during calls) · Support (mailto bug report) · Account.
- **Sort & filter sheet**, **Guide sheet**, **Folder create sheet**, **Delete confirm sheet** (with "Don't ask again").

## Components / Lib (per file)
### lib/entitlements.dart
- `Entitlements.I` (`ChangeNotifier`) — the single source of truth for the plan. Trial clock (`trialStartMs`, 7 days, starts at first folder link, adopted from the folder mirror after a reinstall), `purchased` (store entitlement + expiry + 3-day offline grace), `billingTrial`, `willRenew`, `subscriptionEndsAt`, `debugPro`, derived `isPro`, `capped`, `showAds`, `maxTracks` (25), `maxPlaylists` (2), `canUseCustomRange`, Smart `smartMin/Max` (3–6), `importBlockReason`, `dueTrialReminder` (3 / 1 days, once each), `setStoreEntitlement(...)` (written only by `lib/billing.dart`), `statusLabel`, and debug tier controls.
### lib/billing.dart
- RevenueCat wrapper. `init()` (no-op without `RC_ANDROID_KEY`), `refresh()`, `loadOfferings()`, `planView(plan)` / `annualSaving` (prices come from Play, never constants), `packageFor(plan)` (dashboard slot → package type → product id), `purchase`, `purchasePlan`, `restore`, `_mapError` (Play error code → one sentence), `_apply(CustomerInfo)` → `Entitlements.setStoreEntitlement`. `PurchaseReport{success,cancelled,pending,unavailable,failed}`.
### lib/models.dart
- `Track {id,title,source,path,fileName,durationMs,folderIds,addedAtMs}` + JSON; `Folder {id,name,emoji}`.
- Enums: `AppThemeMode`, `ViewMode`, `RtLoop{smart,customRange,infinite}`, `SortBy`, `DateFilter`.
- `AppStore.I`: tracks/folders, prefs, `selectedFolderId`, session search/date filter, `playlistsExpanded`, `guideBannerDismissed`, `hiddenFileNames`, audios-folder state (`audiosLinked/audiosUri/audiosName/audiosWritable`), `onLibrarySaved` hook (mirror), loop learning (`loopHistory`, `recordLoopCount`, `learnedLoopCount`), grid rearrange state, `_baseVisible()` / `visibleTracksSorted`, `reorderVisibleTracks`, `addTrack` (un-hides a name), `removeTrackKeepFile`, `save()` (local JSON + mirror).
### lib/folder_access.dart
- Thin Dart wrapper for the `com.buildwithanshul.reeltunes/folder` channel: `state`, `link`, `unlink`, `scan`, `save`, `readText`, `writeText`, `delete`; models `LinkedFolder`, `FolderFile`.
### lib/library_sync.dart
- `init` (grant → restore → scan), `link`, `unlink`, `sync` (add new files, update URIs, drop vanished files, map sub-folders to playlists), `mirror` (debounced portable snapshot), `restoreIfEmpty`.
### lib/player.dart — `RtPlayer.I`
- Boot law: `JustAudioBackground.init()` before any `AudioPlayer`; all ops through `_whenReady()`.
- `_sourceFor`: `path.contains('://')` → `AudioSource.uri` (everything today), else `AudioSource.file`.
- Looping: every track armed `LoopMode.one`; `positionStream` wrap counts passes; final pass flips to `LoopMode.off`; `_targetLoops` random in `rangeMin..rangeMax` (Smart samples `loopHistory`, +1 under 30 s); queue end → seek(0) + play.
- `unawaited(_ap.play())` everywhere (the future completes when playback stops).
- Gapless `skipNext/skipPrev`, `_loadFailures` guard, engine-stream listeners for the glyphs, interruptions via `audio_session`, `removeIfCurrent`.
### lib/extractor.dart
- `extractAndAdd(store,url,{title,folderIds,onStatus})`: `Engine.getVideoInfo` → sanitised name → yt-dlp into the cache → `FolderAccess.save` into the linked folder (playlist sub-folder when chosen) → Track with `fileName`, URI path, duration.
### lib/engine.dart
- Method-channel wrapper for `getVideoInfo`, `downloadAudio` (progress + cancel), `cancel`.
### lib/extraction_errors.dart
- Maps yt-dlp text to one plain sentence (login/private, 403, 429, gone, bad link, site changed, network, disk, permission). Used for logs; the UI shows a generic toast.
### lib/top_toast.dart
- Overlay-based top toast (`showTopToast`), single instance, slide+fade, tap to dismiss.
### lib/library.dart
- Home screen, chip strip, playlist header/collapse, sort+filter sheet, guide bar, idle FAB, rearrange modes, track/playlist menus, `removeTrackFromLibrary`, `deleteTrackWithConfirm`, MiniBar, SAF import (`_pickMedia`, `importMediaFiles`, `importMediaFolder`, `importAudioFile`).
### lib/sheets.dart
- `AddReelSheet`, `PlayerSheet`, range picker (bottom sheet), playlist sheets/menus, guide sheet (`_GuideStep` ×7), emoji picker, `showInputSheet`, `showPaywallSheet` (stateless shell + `_PaywallSheetState`: live Play prices, yearly/monthly cards, purchase/restore/manage, `_PlanCard`), `showTrialReminderSheet`.
### lib/main.dart
- `main()` (instant `runApp`, error reporting, deferred audio-service warm-up), `RootScreen` (splash, `LibrarySync`, `Billing.init()` after the library is up, first-run sheet, share intents, lifecycle re-scan + `Billing.refresh()`), `FirstRunSheet`, `CoinLoader`.
### lib/settings_screen.dart
- Guide card, appearance radios, storage block (link folder / re-scan / uninstall copy), playback switches, feedback mailto, live Pro card (`ListenableBuilder` on `Entitlements`), "Restore purchases" row, debug tier section.
### lib/error_report.dart
- `rootMessengerKey`, `reportError` (debugPrint + microtask-deferred single toast), `installErrorReporting`.
### Android
- **MainActivity : AudioServiceActivity** — engine bridge, folder bridge, SAF media picker channel (`/media`), recents-swipe notification cleanup by class name, back-press flag.
- **FolderBridge.kt** — SAF tree link/unlink, scan (recursive, depth 4), save (copy from cache), text read/write, delete, open.
- **EngineBridge.kt** — CPython launcher described above.
- **Manifest** — INTERNET, FOREGROUND_SERVICE(+MEDIA_PLAYBACK), WAKE_LOCK, **`com.android.vending.BILLING`**; AudioService + MediaButtonReceiver; SEND share target; `singleTask`; label ReelTunes; mailto query.
- **build.gradle.kts** — `applicationId com.buildwithanshul.reeltunes`, `minSdk 24`, `useLegacyPackaging = true`, `doNotStrip "**/*.zip.so"`, release still signed with the debug key.
- **packages/just_audio_background** — vendored fork of `0.0.1-beta.17` (latest upstream), wired via `dependency_overrides`. Two patches, both marked `ReelTunes patch`: (1) `getRelativeIndex` no longer returns the current index under `repeatMode == one`, so the media session's next/previous skip the queue instead of restarting the track; (2) `onTaskRemoved()` now calls `stop()`, so swiping the app from Recents clears the media notification. `example/` deleted so analysis stays clean. Re-check both when upgrading just_audio.

## Build & Deploy
```powershell
cd E:\Projects\ReelTune
flutter analyze                      # gate: zero errors (12 pre-existing infos/warnings)
flutter build apk --debug            # ~133 MB, 3 ABIs
$adb = "E:\Android\Sdk\platform-tools\adb.exe"
& $adb -s PBFIINYP7LGE4PPV install -r build\app\outputs\flutter-apk\app-debug.apk
& $adb -s PBFIINYP7LGE4PPV shell am start -n com.buildwithanshul.reeltunes/.MainActivity
```
- **No build without explicit approval.** The user runs device tests; the agent reads logcat (`adb logcat -d | Select-String "extraction failed|Saved"`).
- **Device access:** Wireless debugging is the default now. Pair once with `adb pair <ip>:<pair-port> <code>`, then `adb connect <ip>:<connect-port>`; the connect port changes every time Wireless debugging is toggled. `adb devices` shows a `host:port` serial for Wi-Fi and a bare serial for USB.
- Release plan `--release --split-per-abi` (~40 MB arm64) untested; `flutter build appbundle` never run.

## Bugs & Gotchas (hit & fixed — empirical)
1. **Gradle `excludes` deletes the engine** — use `doNotStrip` + `useLegacyPackaging=true`.
2. **ColorOS renders dialog scrims invisible** — every confirmation is a bottom sheet.
3. **Sheet + keyboard** — `isScrollControlled` + `Padding(bottom: viewInsets.bottom)`.
4. **Bottom sheets capture the store once** — wrap in `ListenableBuilder(AppStore.I)`.
5. **Shuffle repeated across restarts** — seed `Random(now ^ salt)` per call.
6. **`AudioPlayer.play()` future completes when playback stops** — never await it; `unawaited(...)`.
7. **Stale-APK install trap** — gate installs on a fresh "Built" line.
8. **Error-reporter wedge** — never show a SnackBar synchronously in a frame; microtask + one-at-a-time.
9. **Scoped storage blocks folder listing** — raw `ls /sdcard/Download` is denied as the app UID; SAF only.
10. **App could not write to Download at all** — proven with `run-as` `touch`; this is why the SAF save path exists.
11. **Engine: `library "libandroid-support.so" not found`** — `PYTHONHOME`/`LD_LIBRARY_PATH` must point at `python-3.12/usr` (+ `/lib`), the zip prefix tree, not its parent.
12. **Zip stores symlinks as text** — `libz.so.1` arrived as 13 bytes; the unpacker now turns stubs into real `Os.symlink` links (else zlib/binascii fail).
13. **`CERTIFICATE_VERIFY_FAILED`** — OpenSSL has no trust store on Android; set `SSL_CERT_FILE=<usr>/etc/tls/cert.pem`.
14. **YouTube `HTTP Error 403`** — bundled yt-dlp was a year old; updated to 2026.10.26 (SHA-256 verified against `SHA2-256SUMS`).
15. **Instagram "isn't available to everyone"** — audience-restricted reel; requires cookies the app deliberately does not ship. Not fixable client-side.
16. **Raw `PlatformException(…, null, null)` toasts** — replaced by a generic top toast; details stay in logcat.
17. **Folder scan re-adds removed tracks** — `hiddenFileNames` suppresses them until the user adds the file again.
18. **Delete semantics** — "Remove from ReelTunes" unlists; "Delete audio and file" is confirmed (checkbox + Settings switch) and only deletes documents inside the linked folder.
19. **Two apps after the package rename** — the old `com.reeltune.app.reel_tune` stayed installed; uninstalling it wipes its `library.json` (the 431 old tracks were filename-titled videos still in `Pictures/Creation`; metadata copy kept in `backup/old_library.json`).
20. **Recents-swipe must clear the media notification** — broadcast `ACTION_NOTIFICATION_DELETE` to the receiver **by class name** (its supertype isn't on the module classpath).
21. **`adb shell` path mangling on Windows** — quote paths; `pm grant` is blocked on this ColorOS build.
22. **Stock FAB `isExtended` does not animate** — custom `AnimatedContainer` pill in a fixed-width slot.
23. **Media-session skip restarted the track** — `just_audio_background` returns the current index from `getRelativeIndex` when `repeatMode == one`, and ReelTunes uses `LoopMode.one` for per-track looping. Patched in the vendored fork; in-app skip was always fine because it calls `seek(zero, index:)` directly.
24. **Media notification survived Recents swipe** — `onTaskRemoved()` is a no-op upstream. Patched in the fork to `stop()`.
25. **Mojibake in `library.dart`** — a PowerShell rewrite re-encoded the file (`â€”`, `Â·`, `â€¦`, `â–¶`, `ðŸŽ§`, `âž•`). Fixed by byte-level replacement; scan the repo for `[\u00C2\u00C3\u00C5\u00E2\u00F0\uFFFD]` after any shell-based file edit.
26. **Do not use `Set-Content -Encoding utf8` on Dart sources** — on this setup it produced the mojibake above. Use `[System.IO.File]::WriteAllText(path, text, UTF8Encoding($false))`.

## Design Decisions
- **On-device bundled engine, no runtime code downloads** — CPython + yt-dlp ride in the APK; updates ship through Play.
- **GPL-free payload** — no ffmpeg, no youtubedl-android; `tools/repack_engine.py` documents the strip.
- **SAF folder as source of truth** — saves, discovery and uninstall survival all come from the user's own folder; no broad storage permission.
- **Portable mirror over a hidden database** — playlists survive reinstall because they live next to the audio.
- **Playlists wording, `Folder` model** — renaming the model would touch every call site for no user benefit.
- **Reference imports, never copies** — SAF imports point at the original document URI and are never deleted.
- **Generic user-facing failures** — one plain sentence; precise reason in logcat.
- **Platform repeat-one for looping** rather than Dart timers (works backgrounded/screen-off).
- **Smart learns from Custom** — rolling 12-entry history of completed custom-range sessions.
- **Infinite loop only via the repeat icon.**
- **Vendored dependency over a refactor** — the two `just_audio_background` bugs were fixed in a local fork rather than replacing the media-session layer with a custom `audio_service` handler, to avoid destabilising playback right before release.
- **Free/Pro is specified in `docs/free-vs-pro.md`, ads in `docs/ads.md`, codes/dashboard in `docs/promo-codes.md`.** 7-day trial = Pro with no ads; day 8 = caps (25 audios / 2 playlists), ads, coin shop. Caps never hide existing tracks.
- **RevenueCat over a hand-rolled purchase server** — it verifies receipts with the Play Developer API for free at this scale, restores per Google account, and keeps the app from inventing its own Pro flag. The raw Worker + Ed25519 design stays in the doc as the fallback if RevenueCat ever becomes a cost or a dependency problem.
- **Play owns the prices.** The paywall renders `storeProduct.priceString` from Play and falls back to the static list only when the store is unreachable; no price is ever hard-coded as the charged amount.
- **Download ad after the save, not before** — an ad before a slow extraction gets blamed for the wait, and an ad before a failed extraction is a scam. Plus a 60 s floor so a burst of saves shows one ad, not three.
- **Ads live outside the playback path** — sticky banner above the mini bar, end-of-list card, post-save interstitial. Nothing over the player or the seek bar, ever.
- Parked: custom notification handler, sleep timer/EQ/crossfade, ads SDK, in-app licences screen.

## Production readiness (open)
- Release signing (debug key today), upload keystore / Play App Signing, AAB.
- **Play Console: create `reeltunes_pro_monthly` / `reeltunes_pro_annual` (7-day free trial offer), then RevenueCat dashboard: entitlement `pro`, offering `default`, packages `$rc_monthly` / `$rc_annual`, Play service-account JSON. Build with `--dart-define RC_ANDROID_KEY=goog_…`.** Until both exist, the paywall says "Pro isn't live yet".
- Ads: AdMob + UMP consent for EEA/UK (plan + slot rules in `docs/ads.md`); ads must be reflected in the privacy policy and Data Safety.
- Content-rights consent sheet + Settings toggle; link validation (`https` only, host allowlist, length cap).
- Generic branding in listing/screenshots (no platform names or logos); in-app licences screen (LICENSES/ already shipped in repo).
- `allowBackup=false` + `dataExtractionRules` (or a deliberate backup story) — audit before release.
- Privacy policy, Data Safety answers, store listing assets.
- Extraction IP/ToS exposure and Play's stance on bundled interpreters remain the headline risk.
- 16 KB page-size support for the bundled `libpython*.so` / `libqjs.so` not verified — **the RevenueCat/Billing SDK now adds its own `.so`-free code, so this remains an engine-only question**.
- Public GPL repo `UnfilteredAnshul/reeltunes-gpl-sources` still undeleted (delete after the GPL-free build is verified on device).

## File Tree
```
E:\Projects\ReelTune\
├─ android/app/build.gradle.kts              # appId com.buildwithanshul.reeltunes, minSdk 24, doNotStrip zip.so, debug signing
├─ android/app/src/main/AndroidManifest.xml  # no storage permissions; AudioService + receiver; SEND target
├─ android/app/src/main/jniLibs/<abi>/       # libpython.so, libpython.zip.so, libqjs.so, libytdlp.so (arm64/armv7/x86_64)
├─ android/app/src/main/kotlin/com/buildwithanshul/reeltunes/
│  ├─ MainActivity.kt                        # channels, SAF media picker, recents cleanup
│  ├─ EngineBridge.kt                        # CPython launcher, unpack, symlinks, TLS, progress
│  └─ FolderBridge.kt                        # SAF audios folder: link/scan/save/text/delete
├─ lib/
│  ├─ main.dart · library.dart · sheets.dart · player.dart
│  ├─ models.dart · extractor.dart · engine.dart · library_sync.dart · folder_access.dart
│  ├─ entitlements.dart                       # trial / free caps / Pro (single source of truth)
│  ├─ billing.dart                            # RevenueCat: configure, offerings, purchase, restore
│  ├─ extraction_errors.dart · top_toast.dart · settings_screen.dart · emoji.dart · error_report.dart
├─ docs/free-vs-pro.md · docs/ads.md · docs/promo-codes.md
├─ tools/repack_engine.py                    # reproducible GPL strip of libpython.zip.so
├─ LICENSES/                                 # PSF-2.0, Apache-2.0, LGPL-2.1, Unlicense, QuickJS-MIT
├─ THIRD_PARTY_NOTICES.md                    # licence table + yt-dlp version
├─ backup/old_library.json                   # metadata of the dead old-app library (431 tracks, 4 playlists)
├─ play-compliance.md                        # Play policy notes
├─ pc.md                                     # THIS file
└─ build/                                    # repo-ignored
```

## Skills & MCPs
- **Skills:** `apple-design`, `savefile` (this file + vault copy), `vault` (session/bug logs), `multi-author-commits` (commit rules), `opencode`; `agent-reach` unused so far.
- **MCP:** none configured.
- **Commit rules (owner `UnfilteredAnshul`):** author = Anshul (`anshul091103@gmail.com`); committer = random pick among the 3 identities (Anshul / shreyanotfound404 / buildwithsimran); never push unless explicitly asked; tokens in Credential Manager only.
