# Project: ReelTunes

## Project Identity
- **Name:** ReelTunes · `applicationId com.buildwithanshul.reeltunes` (permanent — cannot change after the first Play upload) · Dart package `reel_tune` · project folder `E:\Projects\ReelTune`.
- **What it is:** Android Flutter music player for short-form video audio. Paste a TikTok / Instagram Reel / YouTube Shorts link → audio is extracted **on-device** by a bundled CPython + yt-dlp engine → the file is written into the user's own audios folder and played offline with loop/shuffle controls. Also imports existing phone media through SAF (videos play their own audio, nothing copied).
- **Pitch:** 100% on-device library. No cloud, no login, no server, no database. The audios folder is the source of truth: drop a song in with a file manager and it appears; uninstall the app and the files plus a portable copy of the playlists stay behind.
- **Status (2026-11-07):** debug APK built and installed over wireless adb on Realme RMX3381. This batch: **sort defaults** (date added newest first, filter empty, reset filter button; manual sort restricted to playlists only), **playlist cap enforcement** (visibleFolders hides over-cap playlists on Free; extra playlists stay on disk, never deleted), **loop stutter fix** (switch to LoopMode.off at start of final pass via wrap detection instead of 900 ms margin), **NotificationService stub** (preferences stored; real notifications wired later), **notification settings section** in Settings (vibrate toggle + sound picker). Also: RevenueCat entitlement ID default changed to `reeltunes_pro`, download/import gate ad (one per audio, Free tier) wired into AddReelSheet + import path, app-open ad reliability (10s wait + explicit preload), shop pricing rework (no ads 12h/10c, 24h/15c, 7d/20c, 30d/69c; removed 90d; +25/+50 slots; extra playlist; custom loop 7d/30d), additive perk stacking (counts accumulate, days don't extend), "Add reel" paywall at Free cap, receipt email via Resend (Cloudflare Worker), debug coin section (active perks list, custom balance, delete perks).
- **Production status:** internal debug only. No release signing, no AAB, no Play Console products, no privacy policy yet. AdMob now runs on the **live app id + live units**; the pre-production work (app-ads.txt, privacy policy, Data Safety, content rating) is deliberately deferred until the ad test is approved. See "Production readiness (open)".

## Tech Stack
- **Flutter** 3.47.8 (`C:\src\flutter\bin`), Material 3, Dart `^3.9.0`.
- **Android:** `minSdk 24`, `targetSdk = flutter.targetSdkVersion` (36), SDK 36 at `E:\Android\Sdk`, NDK 28.2.13676358, JDK from Android Studio.
- **Deps (pubspec.yaml):** `just_audio` ^0.10, `just_audio_background` beta.17 (→ `audio_service` 0.18.19), `audio_session`, `receive_intent`, `reorderable_grid_view` 2.2.8, `path_provider`, `shared_preferences`, `url_launcher`, `file_picker` 13.x (**nonstandard fork**: `pickFiles` returns `List<PlatformFile>`, `getDirectoryPath()`), `purchases_flutter` 11.0.0 (RevenueCat → Play Billing 9.1.0; needs Kotlin ≥ 2.1 and compileSdk ≥ 35 — both already true), **`google_mobile_ads` 9.2.0** (AdMob + UMP), `cupertino_icons`.
  - `flutter_local_notifications` was **removed** — versions 13-19 all fail to compile with AGP 9 (desugaring requirement / `bigLargeIcon` ambiguity). NotificationService is a stub storing preferences; real notifications to be wired when a compatible notification plugin is found.
- **Removed:** `ytdlp_flutter` / `youtubedl-android` (GPL-3.0, ffmpeg payload, runtime yt-dlp updates). Nothing GPL ships now except `libcrypt` (LGPL-2.1, unmodified, separate `.so`).
- **Device:** adb `E:\Android\Sdk\platform-tools\adb.exe`, serial `PBFIINYP7LGE4PPV`, pattern lock — user unlocks and tests manually; `svc power stayon true` set.
- **No storage permissions at all.** All media and folder access goes through SAF (`content://` URIs).

## Design System
- Accent `Color(0xFF0A5CD6)` via `ColorScheme.fromSeed`, light/dark/system.
- **Bottom sheets only** (ColorOS renders dialog scrims invisible). No `showDialog` in the app — the old first-run `AlertDialog` is now `FirstRunSheet`.
- Splash = coin loader + "warming up your library…" only, minimum 1.4 s.
- Display name **ReelTunes**; physical folder `ReelTune Audios` (deliberately different spelling, existing data).
- **One sort+filter sheet:** left half SORT (Manual / Name / Date added + ascending), right half DATE ADDED (Any time / Today / Last 7 days / Last 30 days). Both apply live; sliders (`Icons.tune`) turn primary when something is active. **Default sort = date added newest first**; default filter = empty. **Manual sort only inside playlists** — "All audios" is always date/name sorted. **Reset filters** button clears sort/filter/search to defaults.
- **Playlists wording everywhere** (model is still `Folder`): chip strip, `Playlists (N)` header with `AnimatedRotation` chevron. **The playlist list/grid toggle only exists while the section is expanded** — a collapsed section has nothing to lay out.
- **Guide:** dismissible banner "First time here? Here is how it works." above the chip strip → opens a 7-step bottom sheet (also reachable at the top of Settings). Banner stays until dismissed (X or opening the guide).
- **Idle nudge:** after 7 s of stillness the import FAB expands into the "Import audio" pill for ~1.8 s and **repeats forever** while idle; resets on any touch/scroll/search; paused when audio is playing or the page isn't current. On Free the gold "Watch ad · +5" FAB above it expands on the same tick. Both pills are intrinsic-width (no trailing gap) inside a fixed-width right-aligned slot, so the **"Add reel" button never moves**.
- **Top toast** (`lib/top_toast.dart`): slides in under the status bar, auto-dismisses after 2.6 s, tap to dismiss, never blocks input. Replaces bottom snackbars for failures.
- Active-state accents like Spotify: shuffle / repeat / filter icons in `scheme.primary`.

## Database Schema
No SQL. Two local stores + one mirrored file:
1. **`library.json`** (app documents dir, `app_flutter/library.json`) — fast local source of truth:
   ```json
   { "tracks": [ { "id","title","source","path","fileName","sourceUrl","durationMs","addedAtMs","folderIds": ["f…"] } ],
     "folders": [ { "id","name","emoji" } ] }
   ```
   - `path` is a **`content://` URI** (audios folder or SAF import) — no raw paths since the SAF change.
   - `fileName` is the bridge between the folder and the library, and the key used by the mirror/restore.
   - `sourceUrl` is the original link (empty for imports); duplicate-link detection compares `canonicalLink(sourceUrl)` (host+path, no scheme/query), so `?igsh=…`/`utm_*` variants count as the same reel.
   - `source`: `'TikTok' | 'YouTube' | 'Instagram' | 'web'` (extracted) · `'file' | 'video'` (imported).
2. **`.reeltunes-library.json`** inside the audios folder — portable mirror (folders + `{name,title,source,sourceUrl,durationMs,addedAtMs,folderIds}` + `trialStartMs` + `grant {untilMs,lifetime,code}`). Written ~700 ms after every library change and after a code redeem; read back on the first launch after a reinstall, matched to files by name.
3. **SharedPreferences:** `themeMode`, `folderView`, `trackView`, `saveFolder` (legacy display string), `firstRunDone`, `rangeMin/rangeMax`, `confirmDelete(true)`, **`confirmRemove(true)`** (remove-from-library + playlist-removal confirmation), `playDuringCalls`, `sortBy`, `sortAsc`, `guideBannerDismissed`, `playlistsExpanded` (session), `loopHistory` (last 12 custom-range counts), **`hiddenFileNames`** (files removed with "Remove from ReelTunes" — stops a folder scan from re-adding them), `trialStartMs`, `proPurchased/proTrial/proWillRenew/proEndsMs/proProductId`, **`grantUntilMs/grantLifetime/grantCode`** (code grants), `promoCodes`, `promoLog`, `promoDeviceId`, `adminUnlocked`, **`lastTrackId`** (mini-bar resume across launches), **`debugPro` / `debugFree`** (debug tier overrides).
   - Android-side prefs (`reeltunes_folder`): SAF tree URI + resolved root document id.
   - Not persisted on purpose: search text, date filter.

## Storage model (SAF audios folder)
- The user links a folder once (`FolderBridge.link`, `ACTION_OPEN_DOCUMENT_TREE`, read+write persistable grant). If they pick `Download`, the app steps into / creates `ReelTune Audios`.
- **Why:** Android 13+ denies raw paths in Download/DCIM/Movies even with `READ_MEDIA_*` (verified: `touch /sdcard/Download/...` → permission denied as the app UID). SAF is the only Play-safe route.
- **Save path:** yt-dlp writes into the app cache → `FolderBridge.save` copies bytes into the folder (optionally a playlist sub-folder). The cache copy is deleted.
- **Discovery:** `LibrarySync.sync()` runs on launch and on `AppLifecycleState.resumed` — files added by a file manager appear, files deleted outside the app disappear (only entries under the linked tree are considered).
- **Remove vs delete:** "Remove from ReelTunes" unlists and remembers `fileName` (confirmed by default; "Don't ask again" + Settings switch `confirmRemove`); "Delete audio and file" asks once (checkbox + Settings switch `confirmDelete`) and deletes the document. Removing or deleting the track that is playing advances to the next audio — playback does not stop.
- **Duplicate protection:** importing a folder/files again opens a file-manager-style sheet. **Skip duplicates** adds only files that are no longer in the library (i.e. the ones the user removed earlier); **Add anyway** creates separate entries. Re-pasting a saved link asks the same question before extraction.
- **Reinstall:** the grant is revoked by Android, so the user links the same folder once → mirror restores playlists/titles/order, scan restores files.

## Engine (extraction)
- **Payload (all in the APK, no runtime downloads):** CPython 3.12 (PSF-2.0), QuickJS (MIT, used via yt-dlp `--js-runtimes quickjs`), yt-dlp **2026.10.26** zipapp (Unlicense), zlib/OpenSSL/etc. from the CPython distribution. No ffmpeg.
- **GPL strip:** `tools/repack_engine.py` rebuilds `libpython.zip.so` without readline/history/gdbm and the GPL-linked modules; verified 0 GPL strings. yt-dlp is Unlicense. `libcrypt` (LGPL-2.1) ships unmodified.
- **Packaging:** `android/app/src/main/jniLibs/<abi>/` holds `libpython.so`, `libpython.zip.so`, `libqjs.so`, `libytdlp.so` for arm64-v8a / armeabi-v7a / x86_64. Requires `extractNativeLibs="true"` + `useLegacyPackaging=true`.
- **`EngineBridge.kt`:** unpacks the stdlib zip to `files/python-3.12/usr`, materialises the zip's symlink stubs (`libz.so.1` ships as 13 bytes of text) via `Os.symlink`, then runs `libpython.so` with `PYTHONHOME=<usr>`, `LD_LIBRARY_PATH=<usr>/lib`, `SSL_CERT_FILE=<usr>/etc/tls/cert.pem` (without it every request dies with `CERTIFICATE_VERIFY_FAILED`), `TMPDIR=cache`. Streams stdout/stderr, reports progress, supports cancel, errors carry the last stderr line.
- **Dart side:** `lib/engine.dart` (channel wrapper), `lib/extractor.dart` (naming, cache→folder save, Track creation). **yt-dlp updates only ship through Play releases**, never at runtime.

## Auth Flow
None — no account, no login. Playback/library access is anonymous. The plan (Free / trial / Pro) comes from `lib/entitlements.dart` (trial clock + store state + code grants); purchases go through RevenueCat → Play Billing (`lib/billing.dart`). Contract in `play-compliance.md` / `docs/free-vs-pro.md`.

## Routing (screens)
- **RootScreen (main.dart)** — instant `runApp`; store init + ≥1.4 s splash; `LibrarySync.init()` (grant → restore → scan); first-run `FirstRunSheet` (folder picker) when nothing is linked; share-intent listener; lifecycle observer re-scans on resume.
- **LibraryScreen (library.dart)** — AppBar: search toggle · **coin shop icon** · **gold coin balance** (Free only) · New playlist · Settings. FAB column: **gold "Watch ad · +5" pill (Free only)** · import pill (icon ↔ "Import audio") · "Add reel"; while rearranging, a single "Save order" FAB. Body: rearrange banner → guide bar → chip strip → `Playlists (N)` + collapse (+ list/grid toggle only when expanded) → playlists (grid/list, drag-reorder) → new-playlist row → tracks header (`All audios (N)` / `In "<name>" (N)`, sort+filter, view toggle) → track list/grid → bottom spacer. On Free, list view interleaves **two playlist ad cards** after the 8th and 18th audio (display indices map back to track indices for drag-reorder). **MiniBar is always mounted** — the current track when something plays, the **last audio played** (persisted `lastTrackId`, shown as a resume state) on a cold launch, an idle "Nothing playing" row otherwise — so the free-tier banner ad has a fixed anchor directly above it. Tap opens the player; play starts the remembered track.
- **PlayerSheet (sheets.dart)** — playing-from caption, title, source, slider, loop chips (✨ Smart / Custom range only; **tapping the active chip deselects to "no loop"**, and a small caption says "plays once, then the next audio"), animated transport (shuffle, prev, play/pause, next, repeat ∞). The sheet listens to `AppStore` as well as the player, so a rename from its top-right menu updates the title instantly.
- **AddReelSheet** — URL (+`initialUrl` from share), optional name, playlist multi-select, "Extract & save audio", "Or import an audio file instead". Refuses to run when no folder is linked ("Link your audios folder first"). Rejects unsupported links before extraction (`linkProblem`) and asks Skip / Add anyway when the same link is already saved.
- **Track long-press menu** — Rearrange (grid) · Rename · Manage playlists · **Remove from ReelTunes** (keeps the file) · **Delete audio and file** (red, confirmed).
- **Folder/playlist long-press menu** — Rearrange (grid) · Shuffle · Rename · Edit emoji · Delete.
- **Settings** — Guide card (top) · Appearance · Storage (audios folder, re-scan, uninstall explanation) · Playback (confirm before delete, **confirm before removing**, keep playing during calls) · **Privacy (Ad privacy choices → UMP form)** · Support (mailto bug report) · Account · (debug) **Force Pro/Free, trial jump/end/reset, coin balance + give/reset, "Use test ad units", ads readout**.
- **Sort & filter sheet**, **Guide sheet**, **Folder create sheet**, **Delete confirm sheet**, **Remove confirm sheet** (both with "Don't ask again"), **duplicate import/link sheets** (Skip / Add anyway).

## Components / Lib (per file)
### lib/entitlements.dart
- `Entitlements.I` (`ChangeNotifier`) — the single source of truth for the plan. Trial clock (`trialStartMs`, 7 days, starts at first folder link, adopted from the folder mirror after a reinstall), `purchased` (store entitlement + expiry + 3-day offline grace), `billingTrial`, `willRenew`, `subscriptionEndsAt`, `debugPro`, **`debugFree`** (force Free over purchase/code/trial), derived `isPro` (`!debugFree && (purchased || debugPro || codeGrantActive || trialActive)`), `capped`, **`showAds` (`capped && !CoinWallet.adFree`)**, **`maxTracks` (25 + coin-shop `bonusTracks`, up to 50)**, `maxPlaylists` (2), `canUseCustomRange`, Smart `smartMin/Max` (3–6), `importBlockReason` (uses the live `maxTracks`), `dueTrialReminder` (3 / 1 days, once each), `setStoreEntitlement(...)` (written only by `lib/billing.dart`), `statusLabel`, and debug tier controls (`setDebugPro`, `setDebugFree`, trial jump/end/reset). Listens to `CoinWallet` so a purchase/expiry re-renders every gate.
### lib/billing.dart
- RevenueCat wrapper. `init()` (no-op without `RC_ANDROID_KEY`), `refresh()`, `loadOfferings()`, `planView(plan)` / `annualSaving` (prices come from Play, never constants), `packageFor(plan)` (dashboard slot → package type → product id), `purchase`, `purchasePlan`, `restore`, `_mapError` (Play error code → one sentence), `_apply(CustomerInfo)` → `Entitlements.setStoreEntitlement`. `PurchaseReport{success,cancelled,pending,unavailable,failed}`.
### lib/models.dart
- `Track {id,title,source,path,fileName,sourceUrl,durationMs,folderIds,addedAtMs}` + JSON; `Folder {id,name,emoji}`.
- Enums: `AppThemeMode`, `ViewMode`, `RtLoop{off,smart,customRange,infinite}`, `SortBy`, `DateFilter`.
- `AppStore.I`: tracks/folders, prefs (`confirmDelete`, `confirmRemove`), `selectedFolderId`, session search/date filter, `playlistsExpanded`, `guideBannerDismissed`, `hiddenFileNames`, **`lastTrackId`** (mini-bar memory), audios-folder state (`audiosLinked/audiosUri/audiosName/audiosWritable`), `onLibrarySaved` hook (mirror), loop learning (`loopHistory`, `recordLoopCount`, `learnedLoopCount`), grid rearrange state, `_baseVisible()` / `visibleTracksSorted` (**Free cap: `_freeCapIds()` keeps only the newest `Entitlements.maxTracks` by `addedAtMs`, so every list/search/playlist/queue agrees; coin-bought slots raise the number; files stay on disk**), `hiddenByFreeCap`, **`reorderVisibleTracks` (now reorders `visibleTracksSorted`, so a drag works under any sort)**, `trackById`, **`trackBySourceUrl`** (canonical-link match), **`trackByFileName`** (case-insensitive), `addTrack` (un-hides a name), `removeTrackKeepFile`, `removeTrack` (clears `lastTrackId`), `setLastPlayedId`, `save()` (local JSON + mirror).
### lib/folder_access.dart
- Thin Dart wrapper for the `com.buildwithanshul.reeltunes/folder` channel: `state`, `link`, `unlink`, `scan`, `save`, `readText`, `writeText`, `delete`; models `LinkedFolder`, `FolderFile`.
### lib/library_sync.dart
- `init` (grant → restore → scan), `link`, `unlink`, `sync` (add new files, update URIs, drop vanished files, map sub-folders to playlists), `mirror` (debounced portable snapshot including `sourceUrl`), `restoreIfEmpty`.
### lib/player.dart — `RtPlayer.I`
- Boot law: `JustAudioBackground.init()` before any `AudioPlayer`; all ops through `_whenReady()`.
- `_sourceFor`: `path.contains('://')` → `AudioSource.uri` (everything today), else `AudioSource.file`.
- Looping: with a loop mode active every track is armed `LoopMode.one`; `positionStream` wrap counts passes; final pass flips to `LoopMode.off`; `_targetLoops` random in `rangeMin..rangeMax` (Smart samples `loopHistory`, +1 under 30 s); queue end → seek(0) + play. **`RtLoop.off` ("no loop") arms `LoopMode.off` immediately when the track loads**, so even sub-2 s clips advance without waiting for a position tick in the margin.
- `unawaited(_ap.play())` everywhere (the future completes when playback stops).
- Gapless `skipNext/skipPrev`, `_loadFailures` guard, engine-stream listeners for the glyphs, interruptions via `audio_session`.
- **`removeIfCurrent(id)`** is index-surgical: it removes the row from `queue` and fixes `queueIndex`/`current` **first**, sets `_queueSurgery` so `_onIndexChange`/`_onPlaylistEnd` ignore the platform's transient events, then calls `removeAudioSourceAt(idx)`, then seeks to the new index and resumes only if it was playing. A failed engine removal rebuilds the flat playlist from `queue` (`_rebuildQueueAt`). Used by both "Remove from ReelTunes" and "Delete audio and file". The playlist itself is built with `setAudioSources([...], initialIndex:)` — **never** a nested `ConcatenatingAudioSource` (that nesting is what made the UI say "pqr" while "abc" played).
### lib/ads.dart
- AdMob entry point. `Ads extends ChangeNotifier`; `init()` (idempotent) loads the debug unit preference, initializes `MobileAds`, then runs the **UMP** consent flow (`ConsentForm.loadAndShowConsentFormIfRequired`) and preloads rewarded + app-open after consent. `privacyOptionsRequired()` / `showPrivacyOptions()` power **Settings → Ad privacy choices**. `AdBanner` is slot B: anchored adaptive banner above the mini bar. `PlaylistAdCard` is the in-list placement (320×50, labelled "Ad", hidden on screens too narrow to show it uncropped). `showRewarded()` returns true only on the reward callback; `maybeShowAppOpen()` shows at most once per launch and once per 4 h. All gated on `Entitlements.I.showAds` (never Pro, never trial, paused by a 24 h coin purchase); banners back off 30 s → 2 min → 5 min on no-fill.
### lib/coins.dart
- `CoinWallet.I` (`ChangeNotifier`) — local ledger: `balance`, `adFree`/`adFreeUntil`, `extraTracksActive`/`bonusTracks`, `coinsPerAd` (5), `adFreeCost` (20) / 24 h, `extraTracksCost` (25) / +25 slots for 30 days. `addFromAd`, `add`, `spend`, `buyAdFree` (extends an active window), `buyExtraTracks`, `debugGrant`/`debugReset`, and an expiry `Timer` so a lapsed perk re-renders the UI. Local until the AdMob SSV worker exists.
### lib/shop_sheet.dart
- `showShopSheet()` (bottom sheet): balance header, gold **Watch ad · +5 coins** button, the two implemented perks with active/expiry states, and a note that Pro removes the limits. `CoinBalanceChip` is the gold app-bar pill. Purchases never change the plan, so the shop stays reachable during a 24 h ad-free window.
### lib/ad_config.dart
- The only place ad ids live. Live app id `ca-app-pub-5837741403938321~1070877733`; live units for banner (`…/1283639888`), rewarded (`…/4971428445`), app-open (`…/1962121722`) and playlist (`…/2022006489`). Google's samples are the fallback; `useTestAds` = `ADMOB_TEST_ADS=true` or the debug Settings switch (persisted by `Ads`). `modeLabel` feeds the **Settings → Debug tiers → "Ads: unit in use"** readout. Switching units = edit this file (and the manifest app id) — see `docs/admob-setup.md`.
### lib/extractor.dart
- `extractAndAdd(store,url,{title,folderIds,onStatus})`: `Engine.getVideoInfo` → sanitised name → yt-dlp into the cache → `FolderAccess.save` into the linked folder (playlist sub-folder when chosen) → Track with `fileName`, `sourceUrl` (the pasted link), URI path, duration.
### lib/link_rules.dart
- `linkProblem(raw)` → null or one actionable sentence: `https` only, ≤2048 chars, and only **YouTube Shorts** (`/shorts/`, `youtu.be`), **Instagram Reels** (`/reel/`, `/reels/`, `/p/`), **Facebook** (`fb.watch`, `/reel`, `/share/`, `/videos/`, `/watch`), **TikTok** (`*.tiktok.com`). Also `linkAllowed`, `linkRejectedMessage`, and `canonicalLink` (lower-case host+path, `www.` and trailing `/` stripped) used as the duplicate identity.
### lib/engine.dart
- Method-channel wrapper for `getVideoInfo`, `downloadAudio` (progress + cancel), `cancel`.
### lib/extraction_errors.dart
- Maps yt-dlp text to one plain sentence (login/private, 403, 429, gone, bad link, site changed, network, disk, permission). Used for logs; the UI shows a generic toast.
### lib/top_toast.dart
- Overlay-based top toast (`showTopToast`), single instance, slide+fade, tap to dismiss.
### lib/library.dart
- Home screen, chip strip, playlist header/collapse, sort+filter sheet, guide bar, idle FAB, rearrange modes, track/playlist menus, **`removeTrackFromLibrary`** (confirmed, keeps the file), `deleteTrackWithConfirm`, **always-mounted MiniBar** (playing → last played `lastTrackId` resume state → idle row; prev / play-pause / next; listens to `AppStore` for renames), SAF import (`_pickMedia`, `importMediaFiles`, `importMediaFolder`, `importAudioFile`), **`_importPicked` / `_askDuplicateImport`** (Skip / Add anyway, restores only previously removed files).
### lib/sheets.dart
- `AddReelSheet` (link validation + duplicate-link sheet), `PlayerSheet` (Smart / Custom-range chips only — deselect = no loop; `Listenable.merge([RtPlayer.I, AppStore.I])` so renames hot-reload), range picker (bottom sheet), playlist sheets/menus (**playlist-removal confirmation** sharing `confirmRemove`), guide sheet (`_GuideStep` ×7), emoji picker, `showInputSheet`, `showPaywallSheet` (stateless shell + `_PaywallSheetState`: live Play prices, yearly/monthly cards, purchase/restore/manage, `_PlanCard`), `showTrialReminderSheet`.
### lib/main.dart
- `main()` (instant `runApp`, error reporting, deferred audio-service warm-up), `RootScreen` (splash, `LibrarySync`, `Billing.init()` after the library is up, first-run sheet, share intents, lifecycle re-scan + `Billing.refresh()`), `FirstRunSheet`, `CoinLoader`.
### lib/settings_screen.dart
- Guide card, appearance radios, storage block (link folder / re-scan / uninstall copy), playback switches (**confirm before delete**, **confirm before removing**, keep playing during calls), feedback mailto, live Pro card (`ListenableBuilder` on `Entitlements`), "Redeem a code" row, "Code dashboard" row (debug builds, or once a master code unlocked the device), "Restore purchases" row, debug tier section.
### lib/promo.dart
- `PromoEngine` (ChangeNotifier singleton): normalise (`uppercase`, strip `space - _`), local code registry (`promoCodes`), redemption log (`promoLog`, 500 rows), per-device once check on `promoDeviceId`, grant application through `Entitlements.setCodeGrant`. Built-ins `ANSHUL2012` (lifetime Pro + unlocks dashboard) and `FREEVERSION` (clears store/debug/grant **and** ends the trial) are inside `kDebugMode` branches, so release builds compile them out. `createCode/setRevoked/deleteCode/revokeAll/clearLog`. `redeem()` is the single UI entry point and the future `/redeem` swap point.
### lib/redeem_sheet.dart
- `showRedeemSheet` — code field (uppercase, 24 chars), busy state, inline error, success pops with a `PromoResult` the caller toasts. Copies the "codes add time, Play owns price" rule into the UI.
### lib/code_admin.dart
- `CodeDashboardScreen` — status card (plan, grant source/end, live codes, redemptions, device tag), built-ins (copy), codes list (copy on tap; menu: revoke/switch on, delete), create sheet (type, custom code, days, max uses, valid-for days, campaign, notes), redemption log, danger zone (revoke all, clear log).
### lib/entitlements.dart (code grants)
- `codeGrantActive`, `codeGrantUntil/Code/Lifetime`, `setCodeGrant`, `clearCodeGrant`, `adoptCodeGrant`, `codeGrantMirror`. `isPro` = purchased || debugPro || codeGrantActive || trialActive; `showAds`/caps derive from it, so a code is enough to test both tiers. Grants suppress trial reminders.
### lib/error_report.dart
- `rootMessengerKey`, `reportError` (debugPrint + microtask-deferred single toast), `installErrorReporting`.
### Android
- **MainActivity : AudioServiceActivity** — engine bridge, folder bridge, SAF media picker channel (`/media`), recents-swipe notification cleanup by class name, back-press flag.
- **FolderBridge.kt** — SAF tree link/unlink, scan (recursive, depth 4), save (copy from cache), text read/write, delete, open.
- **EngineBridge.kt** — CPython launcher described above.
- **Manifest** — INTERNET, FOREGROUND_SERVICE(+MEDIA_PLAYBACK), WAKE_LOCK, **`com.android.vending.BILLING`**; AudioService + MediaButtonReceiver (`android.intent.action.MEDIA_BUTTON`); SEND share target; `singleTask`; label ReelTunes; mailto query; **AdMob `com.google.android.gms.ads.APPLICATION_ID` meta-data = `ca-app-pub-5837741403938321~1070877733` (live)**.
- **Headset / Bluetooth buttons** — no custom code and no second app: `AudioService` publishes a real Android MediaSession, so the wired/BT remote goes through `MediaButtonReceiver` → audio_service → `just_audio_background`. Single tap = play/pause, next/previous buttons = queue skip, and the Platform's headset-hook double-tap maps to next (the vendored fork's `getRelativeIndex` patch is what stops that from restarting the same track under `LoopMode.one`). Lock-screen and notification controls use the same path.
- **build.gradle.kts** — `applicationId com.buildwithanshul.reeltunes`, `minSdk 24`, `useLegacyPackaging = true`, `doNotStrip "**/*.zip.so"`, release still signed with the debug key.
- **packages/just_audio_background** — vendored fork of `0.0.1-beta.17` (latest upstream), wired via `dependency_overrides`. Two patches, both marked `ReelTunes patch`: (1) `getRelativeIndex` no longer returns the current index under `repeatMode == one`, so the media session's next/previous skip the queue instead of restarting the track; (2) `onTaskRemoved()` now calls `stop()`, so swiping the app from Recents clears the media notification. `example/` deleted so analysis stays clean. Re-check both when upgrading just_audio.

## Build & Deploy
```powershell
cd E:\Projects\ReelTune
flutter analyze                      # gate: zero errors (12 pre-existing infos/warnings)
flutter build apk --debug            # ~157 MB, 3 ABIs
$adb = "E:\Android\Sdk\platform-tools\adb.exe"
& $adb devices                       # copy the exact serial — wireless shows as adb-<device>-<hash>._adb-tls-connect._tcp
& $adb -s "<serial>" install -r build\app\outputs\flutter-apk\app-debug.apk
& $adb -s "<serial>" shell am start -n com.buildwithanshul.reeltunes/.MainActivity
```
- **Last build:** 2026-11-04 — `flutter build apk --debug` (157 MB) + `adb install -r` succeeded on the wireless serial above. Installed, not device-tested by the agent (the user tests).
- **No build without explicit approval.** The user runs device tests; the agent reads logcat (`adb logcat -d | Select-String "extraction failed|Saved"`).
- **Device access:** Wireless debugging is the default now. Pair once with `adb pair <ip>:<pair-port> <code>`, then `adb connect <ip>:<connect-port>`; the connect port changes every time Wireless debugging is toggled, and mDNS pairing exposes a serial like `adb-PBFIINYP7LGE4PPV-Sgk2he._adb-tls-connect._tcp`. USB shows the bare `PBFIINYP7LGE4PPV`.
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
22. **Stock FAB `isExtended` does not animate** — custom pill in a fixed-width slot. The pill is **intrinsic-width** (collapsed = 16 + icon + 16 = a perfect 56 px circle), so an expanded label never leaves an icon-sized blank tail; only the slot underneath is fixed, which keeps "Add reel" from moving.
23. **Media-session skip restarted the track** — `just_audio_background` returns the current index from `getRelativeIndex` when `repeatMode == one`, and ReelTunes uses `LoopMode.one` for per-track looping. Patched in the vendored fork; in-app skip was always fine because it calls `seek(zero, index:)` directly.
24. **Media notification survived Recents swipe** — `onTaskRemoved()` is a no-op upstream. Patched in the fork to `stop()`.
25. **Mojibake in `library.dart`** — a PowerShell rewrite re-encoded the file (`â€”`, `Â·`, `â€¦`, `â–¶`, `ðŸŽ§`, `âž•`). Fixed by byte-level replacement; scan the repo for `[\u00C2\u00C3\u00C5\u00E2\u00F0\uFFFD]` after any shell-based file edit.
26. **Do not use `Set-Content -Encoding utf8` on Dart sources** — on this setup it produced the mojibake above. Use `[System.IO.File]::WriteAllText(path, text, UTF8Encoding($false))`.
27. **Rename is display-only** — `AppStore.renameTrack` changes the library/player title; the audio/video file on disk keeps its old name (and the `MediaItem` tag keeps the old title until the next track loads, so the notification can lag one track behind).
28. **Removing the playing track stopped playback** — `removeIfCurrent` now drops the item from `removeAudioSourceAt(idx)` *and* `queue`, seeks to the replacement index and plays; it only stops when the queue is empty. Both remove and delete call it.
29. **Remove-from-queue desynced title and audio** — the playlist had been built with a nested `ConcatenatingAudioSource`, so the engine's playlist held one child while `queue` held N rows: `removeAudioSourceAt(idx)` removed the whole nested playlist or threw, and the UI (updated from `queue`) showed the next title while the engine kept playing the removed file. Fixed in three parts: `setAudioSources([...], initialIndex:)` builds a **flat** playlist, `removeIfCurrent` mutates `queue`/`queueIndex`/`current` **before** the engine, and `_queueSurgery` makes `_onIndexChange`/`_onPlaylistEnd` ignore the platform's transient events during the operation.
30. **Mini bar was conditional** — it is now always mounted (`track` nullable, idle row) so the free-tier banner ad has a stable slot above it and the bar's prev/play/next stay reachable.
31. **`use_build_context_synchronously` after awaits** — guard `context.mounted` before `showModalBottomSheet`/toast/`Navigator.pop`; file import helpers take an optional `BuildContext?` so a closed picker never shows a sheet on a dead context.
32. **Over-cap Free library was invisible-bug-shaped** — when the trial ended with >25 audios, the cap only applied to *new* imports, so Free users kept unlimited tracks. Now `_baseVisible()` filters to the newest 25 and a notice row explains the hidden files; the folder rescan and every import path ask the same cap.
33. **Widget survives Recents swipe + player buttons dead when app killed** — the app widget's receiver and its media buttons need `onDisabled`/`onDeleted` handling and a background service path that works when the app process is dead. Currently the widget stays visible and buttons don't respond after swiping from recents.
34. **Loop stutter on final pass** — the 4th loop of a 4-loop track stuttered before changing to the next audio. Fixed by detecting the wrap (position jumps backward) and switching to `LoopMode.off` at the *start* of the final pass, giving the engine time to prepare the next track — no 900 ms margin guesswork.
35. **No hot reload on playlist changes** — creating a playlist or adding audio to a playlist updates the folder strip but not the tracks list/grid until app restart. `AppStore` listeners need to propagate to `_TracksView` immediately on every `_persist()`.
36. **Free restrictions don't re-apply after Pro/perk ends** — deleting an extra-playlist perk didn't remove the 3rd playlist. When Pro lapses or a coin perk expires, every gate (maxTracks, maxPlaylists, canUseCustomRange, showAds) must re-evaluate and hide/disable over-cap items.
37. **flutter_local_notifications removed** — versions 13-19 all fail with AGP 9 (desugaring requirement / `bigLargeIcon` ambiguity). NotificationService is a stub; real perk/Pro expiry notifications to be wired when a compatible plugin is found.

## Design Decisions
- **On-device bundled engine, no runtime code downloads** — CPython + yt-dlp ride in the APK; updates ship through Play.
- **GPL-free payload** — no ffmpeg, no youtubedl-android; `tools/repack_engine.py` documents the strip.
- **SAF folder as source of truth** — saves, discovery and uninstall survival all come from the user's own folder; no broad storage permission.
- **Portable mirror over a hidden database** — playlists survive reinstall because they live next to the audio.
- **Playlists wording, `Folder` model** — renaming the model would touch every call site for no user benefit.
- **Reference imports, never copies** — SAF imports point at the original document URI and are never deleted.
- **Generic user-facing failures** — one plain sentence; precise reason in logcat.
- **Platform repeat-one for looping** rather than Dart timers (works backgrounded/screen-off).
- **"No loop" is the deselected state of the loop model** (`RtLoop.off`, no dedicated button): tapping the active Smart / Custom-range chip deselects it, the repeat icon toggles infinite ↔ off, and the player arms `LoopMode.off` up front so short clips advance reliably.
- **Duplicate identity is content-shaped, not row-shaped:** links compare `canonicalLink(sourceUrl)` (scheme/query stripped), files compare `fileName` case-insensitively. "Skip" therefore re-adds exactly what is missing — including items the user had removed — which is what a file manager's duplicate prompt implies.
- **Smart learns from Custom** — rolling 12-entry history of completed custom-range sessions.
- **Infinite loop only via the repeat icon.**
- **Vendored dependency over a refactor** — the two `just_audio_background` bugs were fixed in a local fork rather than replacing the media-session layer with a custom `audio_service` handler, to avoid destabilising playback right before release.
- **Free/Pro is specified in `docs/free-vs-pro.md`, ads in `docs/ads.md`, codes/dashboard in `docs/promo-codes.md`.** 7-day trial = Pro with no ads; day 8 = caps (25 audios / 2 playlists), ads, coin shop. **Caps never delete files, but an over-cap library shows only the newest `maxTracks` on Free** (a notice row offers Pro); every add path is gated at the cap rather than silently dropping imports. Coins are **Free-only**: 5 per rewarded video, 20 = 24 h ad-free (ads pause, shop stays), 25 = +25 slots for 30 days.
- **RevenueCat over a hand-rolled purchase server** — it verifies receipts with the Play Developer API for free at this scale, restores per Google account, and keeps the app from inventing its own Pro flag. The raw Worker + Ed25519 design stays in the doc as the fallback if RevenueCat ever becomes a cost or a dependency problem.
- **Play owns the prices.** The paywall renders `storeProduct.priceString` from Play and falls back to the static list only when the store is unreachable; no price is ever hard-coded as the charged amount.
- **Download ad after the save, not before** — an ad before a slow extraction gets blamed for the wait, and an ad before a failed extraction is a scam. Plus a 60 s floor so a burst of saves shows one ad, not three.
- **Ads live outside the playback path** — sticky banner above the mini bar, end-of-list card, post-save interstitial. Nothing over the player or the seek bar, ever.
- Parked: custom notification handler, sleep timer/EQ/crossfade, interstitial + end-of-list ads, in-app licences screen.
- **Queue surgery is index-aligned** — one flat engine playlist, state-first removal, and a guard flag while the platform catches up. This is the fix for the "remove abc → shows pqr → hears abc" report.

## Production readiness (open)
- Release signing (debug key today), upload keystore / Play App Signing, AAB. **Play fee:** $25 one-time developer registration (no yearly fee); Play's subscription commission is 15% on the first $1M/year. **New personal accounts (created after 13 Nov 2023) must run a closed test with ≥12 testers opted in for 14 continuous days before production access is unlocked**; organization accounts need a D-U-N-S number instead.
- **Subscriptions do not require a production app.** Create `reeltunes_pro_monthly` / `reeltunes_pro_annual` once a billing-enabled AAB is on an internal-testing track, wire RevenueCat, and test purchases with license testers; production can follow later. The live redeem dashboard can likewise ship in a later update.
- **Play Console: create `reeltunes_pro_monthly` / `reeltunes_pro_annual` (7-day free trial offer), then RevenueCat dashboard: entitlement `pro`, offering `default`, packages `$rc_monthly` / `$rc_annual`, Play service-account JSON. Build with `--dart-define RC_ANDROID_KEY=goog_…`.** Until both exist, the paywall says "Pro isn't live yet".
- Ads: **AdMob is live** (`google_mobile_ads` 9.2.0 + UMP): sticky banner, two in-list playlist cards, rewarded (coins), app-open. App id + units in `lib/ad_config.dart` and the manifest; debug defaults to live units with a **Settings → Debug tiers → Use test ad units** safety switch. Deferred until the ad test is approved: `app-ads.txt`, privacy policy + Data Safety naming AdMob/AAID, content rating 13+, "contains ads" declaration. Plan + slot rules in `docs/ads.md`, switch/verification steps in `docs/admob-setup.md`.
- Coins: local `CoinWallet` + shop sheet are implemented for testing; before production, move the balance/spend to the SSV worker so the APK cannot mint coins.
- Content-rights consent sheet + Settings toggle. **Link validation is done** (`lib/link_rules.dart`: `https` only, YouTube Shorts / Instagram Reels / Facebook / TikTok allowlist).
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
│  ├─ models.dart · extractor.dart · engine.dart · library_sync.dart · folder_access.dart · link_rules.dart
│  ├─ entitlements.dart                       # trial / free caps / Pro (single source of truth)
│  ├─ coins.dart                              # local coin wallet + 24 h ad-free / +25 slot perks
│  ├─ ads.dart                                # AdMob: UMP, sticky banner, playlist cards, rewarded, app-open
│  ├─ ad_config.dart                          # live app id + all four ad units (test switch lives here)
│  ├─ shop_sheet.dart                         # coin shop + gold balance chip
│  ├─ billing.dart                            # RevenueCat: configure, offerings, purchase, restore
│  ├─ promo.dart · redeem_sheet.dart · code_admin.dart   # codes: registry, redeem sheet, in-app dashboard
│  ├─ extraction_errors.dart · top_toast.dart · settings_screen.dart · emoji.dart · error_report.dart
├─ docs/free-vs-pro.md · docs/ads.md · docs/promo-codes.md · docs/admob-setup.md
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

## Remaining work (bugs + features)

1. **Widget survives Recents swipe + player buttons dead** — widget needs `onDisabled`/`onDeleted` + background service path.
2. **Notification bar player** — ongoing foreground notification with prev/play/pause/next + playlist name.
3. **Perk/Pro expiry notifications** — 3d, 1d, exact-minute alerts via NotificationService (currently stub).
4. **Notification settings** — device sound + vibrate, synced app info ↔ in-app.
5. **Real flutter_local_notifications** — find AGP 9-compatible version or write platform channel.
6. **Hot reload on playlist changes** — `AppStore` listeners must propagate to `_TracksView` immediately.
7. **Free restriction re-apply** — all gates must re-evaluate when Pro/perk lapses (playlist removal etc.).
8. **Push to origin/main** — only when explicitly asked.

