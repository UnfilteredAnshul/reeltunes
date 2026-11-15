# Project: ReelTunes

## Project Identity
- **Name:** ReelTunes · `applicationId com.buildwithanshul.reeltunes` (permanent — cannot change after the first Play upload) · Dart package `reel_tune` · project folder `E:\Projects\ReelTune`.
- **What it is:** Android Flutter music player for short-form video audio. Paste a TikTok / Instagram Reel / YouTube Shorts link → audio is extracted **on-device** by a bundled CPython + yt-dlp engine → the file is written into the user's own audios folder and played offline with loop/shuffle controls. Also imports existing phone media through SAF (videos play their own audio, nothing copied).
- **Pitch:** 100% on-device library. No cloud, no login, no user database. The audios folder is the source of truth: drop a song in with a file manager and it appears; uninstall the app and the files plus a portable copy of the playlists stay behind.
- **Production status (2026-11-15):** **live on Google Play.** versionCode 11 is published; 12 was built and uploaded with Google's test ad units baked in (`ADMOB_TEST_ADS=true`). Next upload is **0.0.4+13**. Privacy policy, terms, Data safety, content rating and ads declarations are done. Open console work: AdMob "limited ad serving", app-ads.txt, UMP consent form.
- **Owner's standing rules:** short answers, no emoji; sizes in % / rem / em, px only for borders and shadows; accent `kNeonBlue` `#2C8BFF` on an "Acoustic Blue" dark background; never build or push without being asked; the agent never runs UI tests (no screenshots); never build release with the RevenueCat test key — always `goog_cGOTfYvUekciFKVVNAqpWNosUKV`; bump versionCode **and** versionName on every Play upload.

## Tech Stack
- **Flutter** 3.47.8 (`C:\src\flutter\bin`), Material 3, Dart `^3.9.0`.
- **Android:** `minSdk 24`, `targetSdk 36`, SDK 36 at `E:\Android\Sdk`, NDK 28.2.13676358, JDK from Android Studio.
- **Deps (pubspec.yaml):** `just_audio` ^0.10, `audio_session` ^0.2.4, `receive_intent`, `reorderable_grid_view` 2.2.8, `path_provider`, `shared_preferences`, `url_launcher` ^6.2, `file_picker` ^13 (fork: `pickFiles` returns `List<PlatformFile>`, `getDirectoryPath()`), `purchases_flutter` 11.0.0 (RevenueCat → Play Billing), `purchases_admob_flutter` 11.0.0 (impression/click reporting), **`google_mobile_ads` ^8.0.0** (AdMob + UMP), `pdf` ^3.11.3 (local purchase summary), `http` ^1.2.0 (promo codes), `cupertino_icons`.
  - **No `just_audio_background` / `audio_service`.** Both were removed; on ColorOS their service sometimes never reached `startForeground`, so the notification never appeared. The media session is Kotlin (`PlaybackService.kt`). `packages/` is empty, no `dependency_overrides`.
  - `flutter_local_notifications` was removed (13-19 fail to compile with AGP 9). Reminders use the native `ReminderScheduler` bridge.
- **Removed:** `ytdlp_flutter` / `youtubedl-android` (GPL-3.0, ffmpeg payload). Nothing GPL ships except `libcrypt` (LGPL-2.1, unmodified, separate `.so`).
- **Device:** adb `E:\Android\Sdk\platform-tools\adb.exe`, serial `PBFIINYP7LGE4PPV` (Realme RMX3381, Android 13). User unlocks and tests manually.
- **No storage permissions for the audios folder.** All media access goes through SAF (`content://` URIs). `WRITE_EXTERNAL_STORAGE` exists only with `maxSdkVersion="28"` for the legacy mkdir path.

## Design System
- Accent `kNeonBlue` `#2C8BFF` (glow, never purple) via `ColorScheme.fromSeed`, light/dark/system; dark surface `#070A12` ("Acoustic Blue"), light surface `#F7FAFF`.
- **Sizing contract — `lib/ui.dart` (`UiMetrics` on `BuildContext`):** `pw(%)` / `ph(%)` percentage of the screen, `rem(n)` type size (1 rem = 16 logical px, scaled by the OS font setting), `em(n, fontSize:)` padding relative to a font size, `u` = 1% of the shortest side for nested spacing, `compact` when width < 370. Borders, radii and shadow blur stay in raw logical pixels.
- **Bottom sheets only** (ColorOS renders dialog scrims invisible). Only exception: the destructive confirmations that Android itself raises.
- Splash = coin loader + "warming up your library…" only, minimum 1.4 s.
- Display name **ReelTunes**; physical folder `ReelTune Audios` (deliberately different spelling, existing data).
- **One sort+filter sheet:** left half SORT (Manual / Name / Date added + ascending), right half DATE ADDED (Any time / Today / Last 7 days / Last 30 days). Both apply live; `Icons.tune` turns primary when active. Default sort = date added newest first; default filter = empty. **Manual sort only inside playlists.** Reset button restores defaults.
- **Playlists wording everywhere** (model is still `Folder`): chip strip, `Playlists (N)` header with `AnimatedRotation` chevron. List/grid toggle only while expanded.
- **Guide:** dismissible banner → 7-step bottom sheet (also at the top of Settings).
- **Idle nudge:** after 7 s of stillness the import FAB expands into the "Import audio" pill for ~1.8 s and repeats while idle; resets on any touch/scroll/search; paused while audio plays or the page isn't current. On Free the gold "Watch ad · +5" FAB does the same. Both pills are intrinsic-width inside a fixed-width right-aligned slot so **"Add reel" never moves**.
- **Top toast** (`lib/top_toast.dart`): slides in under the status bar, 2.6 s, tap to dismiss, never blocks input. Replaces bottom snackbars for failures.
- Cover art: 48 bundled dark mesh gradients (`assets/covers/`), picked deterministically from the track/folder id (`lib/cover_art.dart`, `coverIndexFor`).
- Launcher icon: adaptive (`mipmap-anydpi-v26`), mark at 60% inside the 72 dp safe zone. Store icon `assets/play-store-icon-512.png`, feature graphic `assets/feature-graphic-1024x500.png`.

## Database Schema
No SQL. Two local stores + one mirrored file:
1. **`library.json`** (app documents dir, `app_flutter/library.json`) — fast local source of truth:
   ```json
   { "tracks": [ { "id","title","source","path","fileName","sourceUrl","durationMs","addedAtMs","folderIds": ["f…"] } ],
     "folders": [ { "id","name","emoji" } ] }
   ```
   - `path` is a **`content://` URI** (audios folder or SAF import) — no raw paths since the SAF change.
   - `fileName` is the bridge between the folder and the library, and the key used by the mirror/restore.
   - `sourceUrl` is the original link (empty for imports); duplicate-link detection compares `canonicalLink(sourceUrl)` (host+path, no scheme/query).
   - `source`: `'TikTok' | 'YouTube' | 'Instagram' | 'web'` (extracted) · `'file' | 'video'` (imported).
2. **`.reeltunes-library.json`** inside the audios folder — portable mirror (folders + `{name,title,source,sourceUrl,durationMs,addedAtMs,folderIds}` + `trialStartMs` + `grant {untilMs,lifetime,code}`). Written ~700 ms after every library change and after a code redeem; read back on the first launch after a reinstall, matched by file name.
3. **`Download/ReelTunes/consent.json`** — durable legal-acceptance copy written through the native `ConsentBridge` (survives reinstall). `SharedPreferences` keeps the fast copy.
4. **SharedPreferences:** `themeMode`, `folderView`, `trackView`, `saveFolder`, `firstRunDone`, `rangeMin/rangeMax`, `confirmDelete`, `confirmRemove`, `playDuringCalls`, `sortBy`, `sortAsc`, `guideBannerDismissed`, `playlistsExpanded`, `loopHistory` (last 12 custom counts), `hiddenFileNames`, `trialStartMs`, `trialDeclined`, `proPurchased/proTrial/proWillRenew/proEndsMs/proProductId`, purchase history JSON, `grantUntilMs/grantLifetime/grantCode`, `promoCodes`, `promoLog`, `promoDeviceId`, `promoInstallId`, `lastTrackId`, `debugPro` / `debugFree`, consent keys, coin wallet keys. The old admin-token keys (`promoCodesToken`, `adminUnlocked`) are no longer read or written.
   - Android-side prefs (`reeltunes_folder`): SAF tree URI + resolved root document id.
   - Not persisted on purpose: search text, date filter.

## Storage model (SAF audios folder)
- The user links a folder once (`FolderBridge.link`, `ACTION_OPEN_DOCUMENT_TREE`, read+write persistable grant). If they pick `Download`, the app steps into / creates `ReelTune Audios`.
- **Why:** Android 13+ denies raw paths in Download/DCIM/Movies even with `READ_MEDIA_*` (verified: `touch /sdcard/Download/...` → permission denied as the app UID). SAF is the only Play-safe route.
- **Save path:** yt-dlp writes into the app cache → `FolderBridge.save` copies bytes into the folder (optionally a playlist sub-folder). The cache copy is deleted.
- **Discovery:** `LibrarySync.sync()` runs on launch and on `AppLifecycleState.resumed`.
- **Remove vs delete:** "Remove from ReelTunes" unlists and remembers `fileName`; "Delete audio and file" is confirmed and deletes the document. Removing/deleting the playing track advances to the next audio.
- **Duplicate protection:** re-import opens a Skip / Add anyway sheet; re-pasting a saved link asks the same question.
- **Reinstall:** the SAF grant is revoked, the user links the same folder once → mirror restores playlists/titles/order, scan restores files.

## Engine (extraction)
- **Payload (all in the APK, no runtime downloads):** CPython 3.12 (PSF-2.0), QuickJS (MIT, via yt-dlp `--js-runtimes quickjs`), yt-dlp **2026.10.26** zipapp (Unlicense), zlib/OpenSSL from the CPython distribution. No ffmpeg.
- **GPL strip:** `tools/repack_engine.py` rebuilds `libpython.zip.so` without readline/history/gdbm and the GPL-linked modules; verified 0 GPL strings.
- **Packaging:** `android/app/src/main/jniLibs/<abi>/` holds `libpython.so`, `libpython.zip.so`, `libqjs.so`, `libytdlp.so` for arm64-v8a / armeabi-v7a / x86_64. Requires `extractNativeLibs="true"` + `useLegacyPackaging=true`.
- **`EngineBridge.kt`:** unpacks the stdlib zip to `files/python-3.12/usr`, materialises the zip's symlink stubs (`libz.so.1` ships as 13 bytes of text) via `Os.symlink`, then runs `libpython.so` with `PYTHONHOME=<usr>`, `LD_LIBRARY_PATH=<usr>/lib`, `SSL_CERT_FILE=<usr>/etc/tls/cert.pem`, `TMPDIR=cache`. Streams stdout/stderr, reports progress, supports cancel.
- **Dart side:** `lib/engine.dart` (channel wrapper), `lib/extractor.dart` (naming, cache→folder save, Track creation). **yt-dlp updates only ship through Play releases.**

## Auth Flow
None — no account, no login. Playback/library access is anonymous. The plan (Free / trial / Pro) comes from `lib/entitlements.dart` (trial clock + store state + code grants); purchases go through RevenueCat → Play Billing (`lib/billing.dart`). Code grants are server-validated by the Cloudflare Worker; the app only ever holds `grantUntilMs / grantLifetime / grantCode`.

## Routing (screens)
Bottom navigation: **Home / Library / Search / More**.

- **RootScreen (main.dart)** — instant `runApp`; store init + ≥1.4 s splash; `LibrarySync.init()`; legal consent gate (`ConsentService.load()` → `showConsentDialog` when `needsAgreement`); first-run `FirstRunSheet` when nothing is linked; share-intent listener; lifecycle observer re-scans and calls `PromoEngine.syncGrantEffects()`. `IndexedStack` of the 4 nav screens with `BottomNavigationBar` (accent `#2C8BFF`).
- **HomeScreen** — featured banner, recently played, playlists, import FAB column, "Add reel" FAB. AppBar: Settings + coin shop (Free only).
- **LibraryScreen** — always-visible search bar, filter chips, playlist chip strip, tracks list/grid.
- **SearchScreen** — same library content with search pre-focused.
- **SettingsScreen** — Appearance, storage, playback, survive-recents-swipe, privacy (Ad privacy choices), legal, Pro card, redeem code, restore purchases, reminders, debug tiers. **No code dashboard row — admin is web only.**
- **PlayerSheet** — caption, title, source, slider, loop chips (Smart / Custom range; tapping the active chip = no loop), animated transport, queue. Listens to `AppStore` too, so a rename updates instantly.
- **AddReelSheet** — URL (+`initialUrl` from share), optional name, playlist multi-select, "Extract & save audio", "Or import an audio file instead". Rejects unsupported links (`linkProblem`) and asks Skip / Add anyway on duplicates.
- Menus: track long-press (rearrange / rename / playlists / remove / delete), playlist long-press (rearrange / shuffle / rename / emoji / delete), sort & filter, guide, folder create, delete/remove confirmations, duplicate import/link sheets.

## Components / Lib (per file)
### lib/entitlements.dart
- `Entitlements.I` (`ChangeNotifier`) — single source of truth for the plan. Trial clock (`trialStartMs`, 7 days, starts at first folder link, adopted from the mirror), `purchased` (+ expiry, 3-day offline grace), `billingTrial`, `willRenew`, `subscriptionEndsAt`, `debugPro`, `debugFree`, `isPro = !debugFree && (purchased || debugPro || codeGrantActive || trialActive)`, `capped`, `showAds` (`capped && !CoinWallet.adFree`), `maxTracks` (25 + coin bonus, up to 50), `maxPlaylists` (2), `canUseCustomRange`, Smart `smartMin/Max`, `importBlockReason`, `dueTrialReminder`, `setStoreEntitlement`, `statusLabel`, debug tier controls.
### lib/billing.dart
- RevenueCat wrapper. `init()` (no-op without `RC_ANDROID_KEY`), `refresh()`, `loadOfferings()`, `planView`, `annualSaving`, `packageFor`, `purchase`, `purchasePlan`, `restore`, `_mapError`, `_apply(CustomerInfo)` → `Entitlements.setStoreEntitlement`. `PurchaseReport{success,cancelled,pending,unavailable,failed}`.
### lib/models.dart
- `Track`, `Folder` + JSON; enums `AppThemeMode`, `ViewMode`, `RtLoop`, `SortBy`, `DateFilter`; `AppStore.I` with tracks/folders, prefs, filters, Free cap (`_freeCapIds`), `hiddenByFreeCap`, `reorderVisibleTracks`, `trackById/BySourceUrl/ByFileName`, `addTrack`, `removeTrackKeepFile`, `removeTrack`, `save()` (local JSON + mirror).
### lib/folder_access.dart
- Dart wrapper for `com.buildwithanshul.reeltunes/folder`: `state`, `link`, `unlink`, `scan`, `save`, `readText`, `writeText`, `delete`; models `LinkedFolder`, `FolderFile`.
### lib/library_sync.dart
- `init`, `link`, `unlink`, `sync`, `mirror`, `restoreIfEmpty`, `ensureFolderAccess()`, `reLinkFolder()`.
### lib/player.dart — `RtPlayer.I`
- One process-wide `just_audio` player. `_boot()` creates the `AudioPlayer` after the session is configured; every op goes through `_whenReady()`. Looping: with a loop mode active every track is armed `LoopMode.one`; a position-wrap counter counts passes and the **final pass flips to `LoopMode.off` at its start**; `_targetLoops` random in `rangeMin..rangeMax` (Smart samples `loopHistory`, +1 under 30 s); queue end → seek(0) + play. `RtLoop.off` arms `LoopMode.off` immediately. `unawaited(_ap.play())` everywhere. `removeIfCurrent(id)` is index-surgical (queue fixed first, `_queueSurgery` guards platform events, then `removeAudioSourceAt`). The playlist is always **flat** (`setAudioSources([...], initialIndex:)`), never nested.
- Pushes title/artist/art/position/playing state into `PlaybackNotification` (Kotlin `PlaybackService`); button callbacks come back through `handleCommand`.
### lib/media_notification.dart
- `PlaybackNotification` — `MethodChannel('com.buildwithanshul.reeltunes/playback')`. `available` flag for Settings diagnostics, `onPlay/onPause/onToggle/onNext/onPrev/onSeek/onStop` callbacks, `show/update/hide`, and `handleCommand`. Dart owns playback; Kotlin owns only the session UI.
### lib/ads.dart
- AdMob entry point. `Ads extends ChangeNotifier`; `init()` (idempotent) loads the unit preference, initializes `MobileAds`, runs the **UMP** flow, preloads rewarded + app-open. `privacyOptionsRequired()` / `showPrivacyOptions()` power Settings → Ad privacy choices (falls back to Google ad settings when AdMob has no form).
- `AdBanner` — anchored **adaptive** banner (`getLargeAnchoredAdaptiveBannerAdSizeWithOrientation`) above the mini bar; the platform view is only made visible after `onAdLoaded`, with a `surface`-coloured `ColoredBox` behind it so no black bar shows while loading. 12 px gap from the mini bar (placement-policy safe). Retries on fail with backoff 30 s → 60 s → 2 min, resets on `AppLifecycleState.resumed` and on unit change.
- `PlaylistAdCard` — inline `AdSize.banner` in the lists.
- `showRewarded()` / `showDownloadAd()` / `maybeShowAppOpen()` **wait for the ad to close** (`Completer` closed from `onAdDismissedFullScreenContent` / `onAdFailedToShowFullScreenContent`) before resolving, so the reward/coin path is never disposed early. `RewardedOutcome{earned, dismissed, failed}`.
- Every step logs `RTADS: …` (request, loaded, impression, failed(code,msg), retry, rewarded earned/dismissed, app-open, init failure) — grep `RTADS` in logcat.
### lib/ad_config.dart
- The only place ad ids live. Live app id `ca-app-pub-5837741403938321~1070877733`; units banner `…/1283639888`, rewarded `…/4971428445`, app-open `…/1962121722`, playlist `…/2022006489`; also `…/1020962184`. Google sample units are the fallback. `useTestAds` = `ADMOB_TEST_ADS=true` or the debug Settings switch (persisted).
### lib/coins.dart
- `CoinWallet.I` — local ledger: `balance`, `adFree`/`adFreeUntil`, `bonusTracks`, `coinsPerAd` (5), `adFreeCost` (20) / 24 h, `extraTracksCost` (25) / +25 slots for 30 days, `addFromAd`, `add`, `spend`, `buyAdFree`, `buyExtraTracks`, `debugGrant`/`debugReset`, expiry `Timer`. Local until an AdMob SSV worker exists.
### lib/shop_sheet.dart
- `showShopSheet()`: balance header, gold **Watch ad · +5 coins**, the two perks with live expiry, note that Pro removes the limits. `CoinBalanceChip` is the gold app-bar pill.
### lib/extractor.dart
- `extractAndAdd(store,url,{title,folderIds,onStatus})`: `Engine.getVideoInfo` → sanitised name → yt-dlp into the cache → `LibrarySync.ensureFolderAccess()` → `FolderAccess.save` → Track with `fileName`, `sourceUrl`, URI, duration.
### lib/link_rules.dart
- `linkProblem(raw)` → null or one actionable sentence: `https` only, ≤2048 chars, YouTube Shorts / Instagram Reels / Facebook / TikTok allowlist. Also `linkRejectedMessage` and `canonicalLink`.
### lib/engine.dart · lib/extraction_errors.dart
- Method-channel wrapper (`getVideoInfo`, `downloadAudio` with progress + cancel, `cancel`). `extraction_errors.dart` maps yt-dlp text to one plain sentence and holds the in-app error guide.
### lib/consent.dart
- `ConsentService.I` + `showConsentDialog` — legal gate before any import/playback. Fast copy in prefs, durable copy in `Download/ReelTunes/consent.json` via the native `ConsentBridge` channel (`com.buildwithanshul.reeltunes/consent`). Accept = explicit button; no dismissal by tapping outside.
### lib/cover_art.dart · lib/ui.dart · lib/first_time_card.dart
- `kNeonBlue`, 48 cover indices, glow helpers. `UiMetrics` sizing extension (see Design System). First-run card shown on Home.
### lib/top_toast.dart · lib/error_report.dart
- Overlay top toast, single instance, slide+fade, tap to dismiss. `rootMessengerKey`, `reportError` (debugPrint + microtask-deferred single toast), `installErrorReporting`.
### lib/library.dart · lib/home_screen.dart · lib/sheets.dart · lib/main.dart · lib/settings_screen.dart
- Library: chip strip, playlist header/collapse, sort+filter sheet, guide bar, idle FAB, rearrange, track/playlist menus, always-mounted MiniBar, SAF import (`_pickMedia`, `importMediaFiles`, `importMediaFolder`, `importAudioFile`, `_askDuplicateImport`).
- Sheets: `AddReelSheet`, `PlayerSheet`, playlist sheets, guide sheet, emoji picker, `showInputSheet`, `showPaywallSheet` (live Play prices, plans, purchase/restore/manage), `showTrialReminderSheet`, `showConsentDialog`.
- main: `main()`, `RootScreen`, `FirstRunSheet`, `CoinLoader`.
- settings: guide card, appearance, storage, playback switches, feedback mailto, privacy + terms rows, Pro card, redeem code, restore purchases, reminders, debug tiers (force Pro/Free, trial jump/end/reset, coin balance, "Use test ad units", ads readout).
### lib/promo.dart
- `PromoEngine` (ChangeNotifier): normalise (uppercase, strip `space - _`), local code registry (`promoCodes`), redemption log (`promoLog`, 500 rows), per-device once check (`promoDeviceId`), grant application through `Entitlements.setCodeGrant`. Built-ins `ANSHUL2012` (lifetime Pro, debug only) and `FREEVERSION` (clears store/debug/grant and ends the trial, debug only) live in `kDebugMode` branches and are compiled out of release.
- `redeem()` posts to the Worker first; the local registry is the offline fallback for codes created on this phone. `syncGrantEffects()` runs on launch/resume: asks `GET /api/grant?code=` and, when the owner pressed **Remove effects**, clears that code grant (`Entitlements.clearCodeGrant` + mirror). A Play purchase and a live trial are never touched. **No admin methods, no admin token, no server cache — all admin work lives in the web dashboard.**
### lib/promo_api.dart
- HTTP transport only: `POST /api/redeem`, `GET /api/grant?code=`. Base URL `https://reeltunes-codes.buildwise.workers.dev`, overridable with `--dart-define=PROMO_API=…`. Throws `PromoApiException` on network/5xx so the engine can fall back; 4xx answers are authoritative.
### lib/redeem_sheet.dart
- `showRedeemSheet` — code field (uppercase, 24 chars), busy state, inline error, success pops with a `PromoResult` the caller toasts. States the "codes add time, Play owns price" rule.
### Android
- **MainActivity** — engine bridge, folder bridge, consent bridge, SAF media picker channel, back-press flag, notification permission request.
- **PlaybackService.kt** — `MediaSessionCompat` + `MediaStyle` notification, `foregroundServiceType="mediaPlayback"`; `PlaybackLink.kt` wires the service and MainActivity to the `playback` MethodChannel. Notification, lock screen, headset and Bluetooth buttons all go through this one session. Why: `audio_service` never reached `startForeground` on ColorOS.
- **FolderBridge.kt** — SAF link/unlink/scan/save/text/delete/open, `probe()` grant check, `ensureDefaultFolder()` creates `Downloads/ReelTune Audios`.
- **ConsentBridge.kt** — reads/writes `Download/ReelTunes/consent.json` through `MediaStore` (raw mkdir on API ≤ 28).
- **EngineBridge.kt** — CPython launcher (unpack, symlinks, TLS, progress, cancel).
- **ReminderScheduler.kt / ReminderReceiver.kt / BootReceiver.kt** — AlarmManager reminders, restored after reboot/update.
- **Manifest** — INTERNET, FOREGROUND_SERVICE(+MEDIA_PLAYBACK), WAKE_LOCK, POST_NOTIFICATIONS, SCHEDULE_EXACT_ALARM, RECEIVE_BOOT_COMPLETED, BILLING, WRITE_EXTERNAL_STORAGE(`maxSdkVersion=28`); `PlaybackService`, reminder/boot receivers, SEND share target, `singleTask`, mailto query, AdMob `APPLICATION_ID` = `ca-app-pub-5837741403938321~1070877733`.
- **build.gradle.kts** — `applicationId com.buildwithanshul.reeltunes`, `minSdk 24`, `useLegacyPackaging = true`, `doNotStrip "**/*.zip.so"`; release signed with `android/upload-keystore.jks` (alias `upload`), credentials in `android/key.properties`, both gitignored. Release adds `proguard-rules.pro`.
- **proguard-rules.pro** — keeps Room's generated `WorkDatabase_Impl.<init>()`; without it R8 full mode kills the process before Flutter starts (bug 43).

## Build & Deploy
```powershell
cd E:\Projects\ReelTune
flutter analyze                                  # gate: zero errors/warnings (style infos only)
flutter test

# Play bundle (always this key, never the test key)
flutter build appbundle --release --dart-define=RC_ANDROID_KEY=goog_cGOTfYvUekciFKVVNAqpWNosUKV
# add --dart-define=ADMOB_TEST_ADS=true while AdMob throttles live units

# Phone build of the same config
flutter build apk --release --target-platform android-arm64 --dart-define=RC_ANDROID_KEY=goog_cGOTfYvUekciFKVVNAqpWNosUKV
& E:\Android\Sdk\platform-tools\adb.exe -s PBFIINYP7LGE4PPV install -r build\app\outputs\flutter-apk\app-release.apk
```
- **No build without explicit approval.** The user runs device tests; the agent reads logcat.
- Local APKs use the upload key, so a Play-signed install must be **uninstalled** first (`adb uninstall com.buildwithanshul.reeltunes`) — that wipes app data; the folder mirror restores playlists.
- **versionCode rule:** it comes from `pubspec.yaml` (`version: 0.0.4+13`). Play burns every uploaded code even if the release is deleted. Bump both `versionName` and the trailing code before every upload. Renaming an AAB does nothing.
- Artifacts: `build\app\outputs\bundle\release\app-release.aab` (~112 MB), `build\app\outputs\flutter-apk\app-release.apk` (~61 MB arm64 release, ~157 MB debug 3-ABI).
- Web deploys: `npx wrangler deploy --config worker/codes/wrangler.jsonc` and `npx wrangler deploy --config privacy/wrangler.jsonc`.

## Bugs & Gotchas (hit & fixed — empirical)
1. **Gradle `excludes` deletes the engine** — use `doNotStrip` + `useLegacyPackaging=true`.
2. **ColorOS renders dialog scrims invisible** — use bottom sheets.
3. **Sheet + keyboard** — `isScrollControlled` + `Padding(bottom: viewInsets.bottom)`.
4. **Bottom sheets capture the store once** — wrap in `ListenableBuilder(AppStore.I)`.
5. **Shuffle repeated across restarts** — seed `Random(now ^ salt)` per call.
6. **`AudioPlayer.play()` completes when playback stops** — never await it; `unawaited(...)`.
7. **Stale-APK install trap** — gate installs on a fresh "Built" line.
8. **Error-reporter wedge** — never show a SnackBar synchronously in a frame; microtask + one at a time.
9. **Scoped storage blocks folder listing** — raw `ls /sdcard/Download` is denied as the app UID; SAF only.
10. **App could not write to Download at all** — proven with `run-as touch`; this is why the SAF save path exists.
11. **Engine: `library "libandroid-support.so" not found`** — `PYTHONHOME` / `LD_LIBRARY_PATH` must point at `python-3.12/usr` (+ `/lib`).
12. **Zip stores symlinks as text** — `libz.so.1` arrived as 13 bytes; the unpacker turns stubs into real `Os.symlink` links.
13. **`CERTIFICATE_VERIFY_FAILED`** — no trust store on Android; set `SSL_CERT_FILE=<usr>/etc/tls/cert.pem`.
14. **YouTube `HTTP Error 403`** — bundled yt-dlp was a year old; updated to 2026.10.26 (SHA-256 verified).
15. **Instagram "isn't available to everyone"** — audience-restricted reel; requires cookies the app deliberately does not ship.
16. **Raw `PlatformException(…, null, null)` toasts** — replaced by a generic top toast.
17. **Folder scan re-adds removed tracks** — `hiddenFileNames` suppresses them until re-added.
18. **Delete semantics** — "Remove from ReelTunes" unlists; "Delete audio and file" is confirmed and only deletes documents inside the linked folder.
19. **Two apps after the package rename** — old `com.reeltune.app.reel_tune` had to be uninstalled; its 431-track metadata is kept in `backup/old_library.json`.
20. **Recents-swipe must clear the media notification** — broadcast `ACTION_NOTIFICATION_DELETE` by class name.
21. **`adb shell` path mangling on Windows** — quote paths; `pm grant` is blocked on this ColorOS build.
22. **Stock FAB `isExtended` does not animate** — custom intrinsic-width pill in a fixed-width slot.
23. **Media-session skip restarted the track** — `just_audio_background` returned the current index under `repeatMode == one`. Moot now: the fork is gone and the native service calls Dart's skip.
24. **Media notification survived Recents swipe** — the old fork's `onTaskRemoved()` was a no-op; the native service stops only when paused.
25. **Mojibake in `library.dart`** — a PowerShell rewrite re-encoded the file. Scan for `[\u00C2\u00C3\u00C5\u00E2\u00F0\uFFFD]` after any shell-based file edit.
26. **Do not use `Set-Content -Encoding utf8` on Dart sources** — produced mojibake. Use `[System.IO.File]::WriteAllText(path, text, UTF8Encoding($false))`.
27. **Rename is display-only** — the file on disk keeps its old name.
28. **Removing the playing track stopped playback** — `removeIfCurrent` removes from engine *and* queue, seeks to the replacement index and resumes.
29. **Remove-from-queue desynced title and audio** — nested `ConcatenatingAudioSource`; fixed with a flat playlist + state-first removal + `_queueSurgery`.
30. **Mini bar was conditional** — now always mounted so the banner ad has a stable slot.
31. **`use_build_context_synchronously` after awaits** — guard `context.mounted`; import helpers take `BuildContext?`.
32. **Over-cap Free library was invisible-bug-shaped** — `_baseVisible()` filters to the newest `maxTracks`; a notice row explains hidden files and every add path asks the same cap.
33. **Widget survives Recents swipe + player buttons dead when killed** — the widget receiver needs `onDisabled`/`onDeleted` and a background path; still open.
34. **Loop stutter on final pass** — detect the position wrap and switch to `LoopMode.off` at the start of the final pass.
35. **No hot reload on playlist changes** — listeners must propagate to `_TracksView` on every `_persist()`.
36. **Free restrictions did not re-apply** when Pro/perk lapsed — every gate must re-evaluate.
37. **`flutter_local_notifications` removed** — 13-19 fail with AGP 9; native `ReminderScheduler` instead.
38. **"Audio handler not initialised" + app stuck on loading** — an awaited background-service init hung on ColorOS. Keep `runApp()` first; playback init is lazy.
39. **"Source error (0)" — audios present but unplayable** — Android dropped the SAF grant. `FolderBridge.probe()` + `folderAccessLost` + reconnect prompt + stop-instead-of-skip on a dead folder.
40. **Playlist counts didn't refresh** — `const _FoldersGrid()` / `const _FoldersList()` skipped rebuilds; `const` removed at both call sites.
41. **Notification player killed by Recents swipe** — native service keeps running while playing.
42. **No media notification on Android 13+** — `POST_NOTIFICATIONS` was never declared/requested. Added and requested in `MainActivity`.
43. **Release build died before the splash ("ReelTunes keeps stopping")** — R8 full mode stripped Room's generated `WorkDatabase_Impl.<init>()`; WorkManager instantiates it by reflection inside `InitializationProvider`. Fixed in `proguard-rules.pro`.
44. **RevenueCat "Wrong API Key" closes release builds** — never pass `RC_ANDROID_KEY=test_…` to a release build. Only `goog_…`.
45. **AdMob UMP consent unconfigured** — log: "Publisher misconfiguration … no form(s) configured for the input app ID". Ads still load; Settings falls back to Google's ad settings until a message exists in AdMob → Privacy & messaging.
46. **Paywall said "Manage subscription" on a fresh install** — `isPro` is true before a folder is linked; added `Entitlements.paidPro` for the paywall's branch.
47. **Rewarded ad played but no coins** — `Ad.show()` resolves when the ad is *presented*, not when it closes, so the old code disposed it immediately and the reward callback never fired. Fixed by awaiting a `Completer` closed from `onAdDismissedFullScreenContent` / `onAdFailedToShowFullScreenContent` in `showRewarded`, `showDownloadAd` and `maybeShowAppOpen`. Verified in logcat: `RTADS: rewarded earned`, `rewarded dismissed · earned=true`.
48. **Banner showed a black bar** — a fixed 320×50 request left the platform view black while empty. Use the anchored adaptive size, mount the view only after `onAdLoaded`, and put a `surface`-coloured `ColoredBox` behind it. Gap to the mini bar raised to 12 px for placement-policy safety.
49. **Live banners fail with `error 3` + `HTTP 403` while rewarded fills** — the AdMob **account** is under "limited ad serving"; the banner request is refused server-side. Not a code bug. Google's sample units ignore the limit, so release builds ship `ADMOB_TEST_ADS=true` until it lifts. Lifting needs a verified app, complete identity/payment checks, app-ads.txt on the developer-website domain, and real traffic.
50. **In-app code dashboard was still shipping as dead code** — its Settings entry was removed in `937bfee` (before version 9), but `lib/code_admin.dart` stayed in the repo and `PromoEngine` still carried the admin API. Deleted 2026-11-15; admin is web-only.
51. **`test/widget_test.dart` was stale** — asserted the text "ReelTune", which no longer exists, and the app needs plugins + a 1.4 s splash. Replaced with `test/link_rules_test.dart`.
52. **Dead top-level helpers** — `linkAllowed`, `currentPurchaseRecord`, `importAudioPickFolder`, `downloadErrorFor`, `firstRunDefaultPathHint`, `_dateFrom`, `_toggleSearch`, `_searchOpen`, `expandedWidth`, `emoji.dart` were unreferenced. Removed; `flutter analyze` went from 33 issues (2 warnings) to 27 infos, 0 errors/warnings.

## Release build (Play)
- Upload keystore: `android/upload-keystore.jks` (alias `upload`), credentials in `android/key.properties`, both gitignored — **back them up**. Certificate SHA-256: `81:51:D7:9F:B1:00:2B:D4:3D:61:C8:4A:39:AB:0C:82:A7:9D:94:26:48:E0:4E:71:65:00:44:9A:52:E2:CB:05`.
- Bundle command (add `--dart-define=ADMOB_TEST_ADS=true` while the account is throttled):
  ```powershell
  flutter build appbundle --release --dart-define=RC_ANDROID_KEY=goog_cGOTfYvUekciFKVVNAqpWNosUKV
  ```
- **Current artifact:** `build\app\outputs\bundle\release\app-release.aab` — versionName **0.0.4**, versionCode **13**, package `com.buildwithanshul.reeltunes`, ~112 MB. versionCode 11 is live; 12 was the test-ads upload.
- Shipping test ad units to production is against AdMob policy. Keep such a build on internal/closed testing, or rebuild without the define once limited ad serving lifts.
- Play updates (same package + signature) keep the SAF grant, so users don't re-link after a normal update.

## Legal pages (privacy + terms)
- Source `privacy/` in this repo, deployed as the assets-only worker **`reeltunes-privacy`** (`privacy/wrangler.jsonc`): `npx wrangler deploy --config privacy/wrangler.jsonc`.
- **Privacy:** https://reeltunes-privacy.buildwise.workers.dev/ · **Terms:** https://reeltunes-privacy.buildwise.workers.dev/terms
- URLs in `lib/legal.dart`; opened from Settings → Privacy.
- Icons for both sites are generated from `assets/play-store-icon-512.png` by `.scratch/build_web_icons.py` → `favicon.ico` (16/32/48), `favicon-32.png`, `icon-192.png`, `icon-512.png`, `apple-touch-icon-180.png`. Both sites and the codes dashboard were redeployed and verified live on 2026-11-15 (correct MIME types, new `<link>` tags, `theme-color` `#0A1122`, `og:image` = `icon-512.png`).
- Policy covers: on-device storage, internet use for downloads from a pasted link, RevenueCat, AdMob, permissions, deletion requests, no account. Terms cover: user responsibility for content, Google Play billing, coins/perks expiry, liability, India/Karnataka law.
- Data safety: Purchase history (collected, not shared); Approximate location, App interactions, Diagnostics, Device or other IDs (collected + shared for advertising/analytics/fraud). Content rating: Teen / PEGI 12. Browsers cache favicons aggressively — check in a private tab.

## Code backend (Cloudflare Worker + D1)
- Worker `reeltunes-codes`, source `worker/codes/`, live at https://reeltunes-codes.buildwise.workers.dev. **The web dashboard is the only admin surface** (static `public/` assets + `/api/admin/*`), admin token pasted once into the browser and stored in localStorage.
- D1 database `reeltunes-codes` (`52fe2891-0753-4787-95df-8a3d11c04ad7`), schema `worker/codes/schema.sql`: `codes`, `redemptions`, `redeem_attempts`, `master_devices`. `codes.effects_removed` powers "Remove effects".
- App transport `lib/promo_api.dart`; rules/cache in `lib/promo.dart`. `redeem()` calls the Worker first and falls back to locally created codes when offline. Server codes are never cached as strings, so a revoked code cannot be replayed.
- **Revoke vs Remove effects:** `revoked = 1` only blocks future redemptions; time already granted keeps running. `effects_removed = 1` is the claw-back: every device that redeemed the code drops that grant on its next launch/resume (`GET /api/grant?code=` → `syncGrantEffects`). The web dashboard shows an "effects off" badge and a `Remove effects` / `Restore effects` button per code.
- Secrets: `ADMIN_TOKEN` and optional `MASTER_CODE`. Never in the APK.
- Redeploy: `npx wrangler deploy --config worker/codes/wrangler.jsonc`. Schema: `npx wrangler d1 execute reeltunes-codes --remote --file=… --config …`.
- Rate limit 5/hour, 20/day per device; one redemption per code per device (unique index).
- Not built: creator ladder, campaign overview, Play Integrity verdicts, signed entitlement tokens.

## Design Decisions
- **On-device bundled engine, no runtime code downloads** — CPython + yt-dlp ride in the APK; updates ship through Play.
- **GPL-free payload** — no ffmpeg; `tools/repack_engine.py` documents the strip.
- **SAF folder as source of truth** — saves, discovery and uninstall survival come from the user's own folder.
- **Portable mirror over a hidden database** — playlists survive reinstall because they live next to the audio.
- **Native media session over audio_service** — the plugin's service never reliably reached `startForeground` on ColorOS; a 12 KB Kotlin service that owns one `MediaSessionCompat` is smaller and starts every time.
- **Wait for the ad to close, not for it to show** — the reward and the coin are granted in the dismissal callback; resolving `show()` early is what silently broke rewards.
- **Test ad units over live units while throttled** — Google's samples bypass account-level limited ad serving, so the ad surfaces stay testable; live units come back with one build flag.
- **Web-only admin** — codes are created, revoked, deleted and clawed back from the Cloudflare dashboard; the APK carries no admin token and no admin UI.
- **Playlists wording, `Folder` model** — renaming the model would touch every call site for no user benefit.
- **Reference imports, never copies** — SAF imports point at the original document and are never deleted.
- **Generic user-facing failures** — one plain sentence; the precise reason stays in logcat.
- **Platform repeat-one for looping** rather than Dart timers (works backgrounded/screen-off).
- **Duplicate identity is content-shaped** — links compare `canonicalLink(sourceUrl)`, files compare `fileName` case-insensitively.
- **RevenueCat over a hand-rolled purchase server** — it verifies receipts with the Play Developer API and restores per Google account.
- **Play owns the prices** — the paywall renders `storeProduct.priceString`.
- **Download ad after the save, not before** — an ad before a slow extraction gets blamed for the wait. 60 s floor so a burst shows one ad.
- **Ads live outside the playback path** — banner above the mini bar, in-list card, post-save interstitial. Nothing over the player.
- **Queue surgery is index-aligned** — one flat engine playlist, state-first removal, guard flag while the platform catches up.

## Production readiness (open)
- **Play:** live, versionCode 11 (0.0.3). New personal accounts need a closed test with ≥12 testers for 14 continuous days before production access; the upload path is already proven.
- **AdMob:**
  - **Limited ad serving** is active on the account. Banners return `error 3` / HTTP 403; rewarded occasionally fills. It lifts automatically after app verification, identity/payment checks, app-ads.txt and real traffic. Nothing in the code can speed it up.
  - **app-ads.txt** not published. Use the existing portfolio domain from the Play listing (Google reads the host of the developer website and ignores the path). File at the **root**: `google.com, pub-5837741403938321, DIRECT, f08c47fec0942fa0`. Then AdMob → Apps → ReelTunes → app-ads.txt → Verify.
  - **UMP consent form** not configured (bug 45). Settings falls back to Google ad settings.
- **Coins:** local `CoinWallet`; before scale, move balance/spend to an SSV worker so the APK cannot mint coins.
- **`allowBackup` / `dataExtractionRules`** — audit before the next policy pass.
- Play Console forms (data safety, content rating, target audience, ads, AD_ID) are console-only; the Publisher API cannot fill them.
- Extraction IP/ToS exposure and Play's stance on bundled interpreters remain the headline product risk.
- 16 KB page-size support for `libpython*.so` / `libqjs.so` not verified.

## File Tree
```
E:\Projects\ReelTune\
├─ android/app/build.gradle.kts                # appId, minSdk 24, doNotStrip zip.so, upload keystore
├─ android/app/proguard-rules.pro              # Room keeps for WorkDatabase_Impl.<init>()
├─ android/app/src/main/AndroidManifest.xml    # SAF, PlaybackService, receivers, AdMob app id
├─ android/app/src/main/jniLibs/<abi>/         # libpython.so, libpython.zip.so, libqjs.so, libytdlp.so
├─ android/app/src/main/kotlin/com/buildwithanshul/reeltunes/
│  ├─ MainActivity.kt                          # channels, SAF picker, notification permission
│  ├─ PlaybackService.kt · PlaybackLink.kt     # MediaSessionCompat + MediaStyle + MethodChannel
│  ├─ EngineBridge.kt                          # CPython launcher, unpack, symlinks, TLS, progress
│  ├─ FolderBridge.kt                          # SAF audios folder: link/scan/save/text/delete
│  ├─ ConsentBridge.kt                         # durable consent.json via MediaStore
│  └─ ReminderScheduler.kt · ReminderReceiver.kt · BootReceiver.kt
├─ lib/ (33 files)
│  ├─ main.dart · home_screen.dart · library.dart · sheets.dart · player.dart
│  ├─ models.dart · ui.dart · cover_art.dart · top_toast.dart
│  ├─ entitlements.dart · billing.dart · purchase_record.dart · receipt_pdf.dart
│  ├─ coins.dart · shop_sheet.dart
│  ├─ ads.dart · ad_config.dart
│  ├─ extractor.dart · engine.dart · link_rules.dart · extraction_errors.dart
│  ├─ library_sync.dart · folder_access.dart
│  ├─ media_notification.dart · notification_service.dart · consent.dart · first_time_card.dart
│  ├─ promo.dart · promo_api.dart · redeem_sheet.dart
│  └─ settings_screen.dart · legal.dart · error_report.dart
├─ privacy/                                    # index.html + terms.html + icon set + wrangler.jsonc
├─ worker/codes/                               # src/index.js (D1 API) + public/ (dashboard + icons)
├─ assets/play-store-icon-512.png · assets/feature-graphic-1024x500.png · assets/covers/ (48)
├─ test/link_rules_test.dart                   # only test: link allowlist rules
├─ tools/repack_engine.py                      # reproducible GPL strip of libpython.zip.so
├─ .scratch/build_web_icons.py                 # regenerates favicons/icons for both sites
├─ LICENSES/ · THIRD_PARTY_NOTICES.md
├─ backup/old_library.json                     # metadata of the dead old-app library
├─ docs/free-vs-pro.md · docs/ads.md · docs/promo-codes.md · docs/admob-setup.md
├─ pc.md                                       # THIS file
└─ build/                                      # repo-ignored
```

## Skills & MCPs
- **Skills:** `apple-design`, `savefile` (this file + vault copy), `vault` (session logs), `multi-author-commits` (commit rules), `opencode`, plus the Cloudflare skill set installed under `~/.agents/skills`.
- **MCP:** `cloudflare` (remote, `https://mcp.cloudflare.com/mcp`, OAuth) in `~/.config/opencode/opencode.jsonc`. Account `d77090059bcf2448a72aab38cb9a3617`. Deploys run through `npx wrangler deploy` (wrangler is authenticated with broad token permissions).
- **Commit rules (owner `UnfilteredAnshul`):** author = Anshul (`anshul091103@gmail.com`); committer = random pick per commit between Anshul / **Simran Rajpal** (`contact.simran.rajpal@gmail.com`) and **Shreya Rajpal** (`shreya.rajpal111@gmail.com`). Never push unless explicitly asked. Tokens live in Windows Credential Manager only.
- **Identity trap:** `Simran Kaur` and `buildwithsimran@gmail.com` are wrong; `buildwithsimran` is only a GitHub username.

## Purchase summary, cancellation and reminders (2026-11-11)
- **Receipt PDF** — `lib/receipt_pdf.dart` builds a "Purchase summary" with `pdf` and saves it through `FilePicker.saveFile` (SAF). Merchant-of-record disclaimer, test-purchase warning, auto-pay amount/date and a purchase-history table. Nothing is emailed or uploaded.
- **Purchase data** — `lib/purchase_record.dart` + `Entitlements`: latest and original purchase dates, sandbox flag, price string, store label, local history (prefs JSON, max 25, cleared on uninstall). `Billing._apply` fills them from RevenueCat.
- **Cancellation** — Pro sheet has `Cancel subscription` (confirmation explains Pro lasts to period end; opens `Billing.manageUrlFor`). Test Store purchases get a local "End test Pro" path.
- **Reminders** — native `ReminderScheduler` + receivers on channel `com.buildwithanshul.reeltunes/reminders`; alarms at end-3 days, end-1 day and the exact end minute. Auto-renew messages state the amount Play will charge; ending messages state the app returns to Free and nothing is deleted. Schedule mirrored to prefs and restored after reboot/update. Exact timing uses `SCHEDULE_EXACT_ALARM` when granted, otherwise `setAndAllowWhileIdle`.
- **Settings** — reminder toggle, exact-alarm permission row, debug "Send a test reminder", Download purchase summary, Cancel subscription.
- Play declarations unchanged: PDF and reminders are local, no email collected. `SCHEDULE_EXACT_ALARM` may trigger Play's exact-alarm review; if rejected, drop the permission and keep the inexact fallback.

## Remaining work (bugs + features)
1. **Hot reload on playlist changes** — propagate every `_persist()` to `_TracksView`.
2. **Free restriction re-apply** — all gates must re-evaluate when Pro/perk lapses.
3. **AdMob limited ad serving** — console-only; rebuild without `ADMOB_TEST_ADS` once it lifts.
4. **UMP consent form** — create a GDPR / US-states message in AdMob → Privacy & messaging.
5. **app-ads.txt** — publish at the portfolio domain root and verify in AdMob.
6. **AdMob SSV** — move the coin ledger server-side.
7. **Widget after Recents swipe** — receiver `onDisabled`/`onDeleted` and a background path for the buttons.
8. **16 KB page-size** — verify the bundled `.so` files.
