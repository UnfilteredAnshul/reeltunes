# Project: ReelTunes

## Project Identity
- **Name:** ReelTunes (display name; internal package id stays `com.reeltune.app.reel_tune` / Dart package `reel_tune`)
- **What it is:** Android Flutter music player for short-form video audio. Paste a TikTok / Instagram Reel / YouTube Shorts link → the app extracts the audio **on-device** with a bundled yt-dlp engine → plays it offline through an advanced looping player. Also imports real device media: **audio files AND whole folders of videos — videos play their audio track with zero copy/extract**.
- **Pitch:** ReelTunes is a fully local, 100% on-device audio library. No cloud, no login, no server, no database. Uninstalling the app deletes everything the app owns. Users organize category folders (Motivation, Edits… — multi-membership, emoji avatars), share links straight from social apps, and listen with per-track random loop counts ("reel-style" repeat) via Smart / Custom-range / ∞-infinite looping and shuffle-on-by-default playback with Spotify-style state indication.
- **Status (2026-10-30):** Full-pro dev build stable on physical Realme RMX3381 (Android 16 / ColorOS). Playback, background media session, folder UX, grid + list drag-reorder, error toasts, video-folder import all working end-to-end.

## Tech Stack
- **Flutter** 3.47.8 (`C:\src\flutter\bin` on PATH), Dart M3, Material 3
- **Android SDK** 36 at `E:\Android\Sdk`, NDK 28.2.13676358, Java/Gradle via Android Studio `C:\Program Files\Android\Android Studio\jbr`; `minSdk 24`
- **Deps (pubspec.yaml):** `just_audio` 0.10.6, `just_audio_background` 0.0.1-beta.17 (→ transitively `audio_service` 0.18.19), `audio_session`, `receive_intent`, `reorderable_grid_view` 2.2.8, `ytdlp_flutter` ^0.1.0 (bundles yt-dlp + Python per ABI; **GPLv3 note**), `path_provider`, `shared_preferences`, `url_launcher`, `file_picker` 13.3.0 (**nonstandard fork API**: `FilePicker.pickFiles` returns `List<PlatformFile>` directly; no `multiple` param; `FilePicker.getDirectoryPath()` for folders)
- **Device:** adb at `E:\Android\Sdk\platform-tools\adb.exe`, serial `PBFIINYP7LGE4PPV`
- No cloud/auth/Firebase. `AppStore.I.fullPro` = `true` in dev.

## Design System
- Accent `Color(0xFF0A5CD6)` via `ColorScheme.fromSeed`, Material 3, light/dark/system.
- Bottom sheets everywhere (`showDragHandle: true`) — SEE BUG #2 (ColorOS dialogs = invisible scrim).
- Splash: **coin loader only** (no logo image; `assets/logo.png` still registered in pubspec for launcher use).
- App display name **ReelTunes** everywhere visible (launcher label, app bar, splash tagline, "ReelTunes Pro", notification channel 'ReelTunes playback'). Physical folder `ReelTune Audios` deliberately NOT renamed (would orphan on-device data).
- Active-state indication like Spotify: shuffle/repeat icon buttons color `scheme.primary` when active; repeat shows `Icons.repeat_on` while ∞ looping.

## Database Schema
No SQL DB. Two stores:
1. **`library.json`** (app documents dir) — source of truth:
   ```json
   { "tracks": [ { "id","title","source","path","durationMs","addedAtMs","folderIds": ["f…"] } ],
     "folders": [ { "id","name","emoji" } ] }
   ```
   - `source` values seen: `'TikTok'/'YouTube'/'Instagram'` (extracted), `'import'` (copied file flow), `'file'` (reference-imported audio), `'video'` (reference-imported video).
   - `folderIds` — multi-membership; empty = "All only". Delete-folder keeps tracks; delete-track removes the file **only if `path` starts with the save root** (reference-imported videos are unlisted, never deleted from disk).
2. **SharedPreferences keys:** `themeMode`(0), `folderView`(1), `trackView`(0), `saveFolder('')`, `firstRunDone(false)`, `rangeMin(3)`/`rangeMax(5)`, `confirmDelete(true)`, `playDuringCalls(false)`, `sortBy(0 manual|1 name|2 dateAdded)`, `sortAsc(true)`.

## Physical folder layout ("how categories are handled")
- `library.json` is the index; the FS is an optimization, never truth.
- Extraction output dir: `directoryForFolder(folderIds.firstOrNull)` → save root, or `<root>/<emojiLetters>_<folderId>/` subfolder (created recursively; falls back to root). Multi-folder tracks: file lives in the FIRST chosen folder's dir; membership of others is JSON-only.
- Reference imports (`importMediaFiles`/`importMediaFolder`): create Tracks pointing at the **original path** — not copied, not moved, storage cost zero; delete never touches them (root-guard in `deleteTrackWithConfirm`).
- "All" lists every track; selecting a folder filters `folderIds.contains(selectedId)`; that selection is the **active playlist** shown as `playing from <name>` in the player (default "All").

## Auth Flow
None. Free/pro gating contract in `docs/free-vs-pro.md` via `AppStore.I.fullPro` (currently true). Ads/payment not started.

## Routing (screens)
- **RootScreen (main.dart)** — instant `runApp`; store init + share-intent listening + ≥1.4 s splash (logo REMOVED — coin loader + 'warming up your library…' only); FirstRunDialog (save folder) on first launch only.
- **LibraryScreen (library.dart)** — AppBar: ➕ New folder, ⚙ Settings (corner Add-via-file button removed). FAB column: **"Import audio"** (opens import choose-sheet) stacked above **"Add reel"**. Body: `_FolderStrip` → folders header + list/grid toggle → reorderable folders (grid via `ReorderableGridView.builder`, list via `SliverReorderableList`) → tracks header + sort + view toggle → reorderable tracks. `MiniBar` persistent when `current != null` (tap re-opens player).
- **PlayerSheet (sheets.dart)** — `playing from <folder>` small caption above title; title; `from <source>` (**'· audio only' removed**); position slider + mmss; "Advanced Looping" chips: **Smart (auto)** / **Custom range (N-Mx)** (steppers sheet, persisted) / **Loop ∞ (forever)**; transport: shuffle (accent when on, toggles `toggleShuffle`), prev (restart >3 s else previous track, wrap-around), big circular play/pause, next, repeat (∞ accent + `repeat_on` glyph, toggles infinite loop).
- **MiniBar (library.dart)** — tile: leading art box, title, subtitle "m:ss / total" + engine-driven `playingStream` play/pause button (never stale), 2 px `LinearProgressIndicator` progress line below.
- **AddReelSheet (sheets.dart)** — URL (`initialUrl` for share intents) + optional title + **folder MULTI-SELECT checkboxes (optional; none = shows in All)** + "New folder" row; "Extract & save audio"; dev-phase raw error toast; polished fallback `_onExtractionFailed` commented but kept.
- **FolderCreateSheet** — name + emoji strip; **emoji DEFAULTS TO RANDOM from `emojiPalette`** (every creation path funnels here: strip chip, grid card, Manage folders, folder menus).
- **SettingsScreen** — Appearance, storage, playback switches, ReelTunes Pro card.
- **Import choose-sheet** — "Import files (audio or video)" → `importMediaFiles()`; "Import a folder of videos" → `importMediaFolder()` (top-level scan, `_isMediaPath` extension filter, original-path Tracks).

## Components / Lib (per file)
### lib/models.dart
- `Track {id,title,source,path,durationMs,addedAtMs,folderIds}` + JSON; `Folder {id,name,emoji}`.
- Enums: `AppThemeMode{system,light,dark}`, `ViewMode{list,grid}`, **`RtLoop{smart,customRange,infinite}`**, `SortBy{manual,name,dateAdded}`.
- `AppStore.I` (ChangeNotifier): `tracks`, `folders`, prefs above, `selectedFolderId`. Queries: `visibleTracks`, `visibleTracksSorted` (ties by store order — Dart sort unstable), `folderById`. Mutations: `addFolder/deleteFolder/renameTrack/setTrackFolders/updateTrackDuration/addTrack/removeTrack`, view/reorder/sort setters, `fullPro=true`.
- `reorderVisibleTracks(o,n)` — writes drag order back, switches sort to manual; `reorderFolders(o,n)`.
- `directoryForFolder(id?)`, `saveFolderWithRoot()`, `randomLoopCount([min,max])`, `mmss(ms)`.

### lib/player.dart — `RtPlayer.I` (ChangeNotifier)
- **Boot order law:** `JustAudioBackground.init()` MUST complete before any `AudioPlayer` exists. `main()` calls `runApp` then `RtPlayer.I.ensureBackgroundService()`; `RtPlayer._boot()` awaits it, then creates `AudioPlayer(handleInterruptions: false)`; all ops go through `_whenReady()`.
- Queue = `ConcatenatingAudioSource(children: AudioSource.file(path, tag: MediaItem(id,title,artist: source,duration)))`; `initialIndex = queueIndex`.
- `play(track, {context, playingFrom})` — Fisher–Yates fresh-epoch-salt shuffle (`Random(now ^ 0x5f4d9e17)`), tapped track pinned front; sets `playingFrom` (explicit param, else from `selectedFolderId`). NOTE: PlayerSheet `startPlayback:false` mode exists — for folder-shuffle where the queue was already built (re-issuing play() with empty context would DESTROY the queue).
- `_onState`: on `completed` → `_loopsDone++`; `< _targetLoops` OR `loop == RtLoop.infinite` → seek(0)+play; else `skipNext()`.
- `_loopsTarget()`: range store.min..max; Smart boosts `<30 s` clips (max+1).
- **`skipNext()` — gapless:** `_ap.seek(Duration.zero, index: (queueIndex+1)%len)` inside the loaded queue (no `setAudioSource` reload); currentIndexStream listener syncs `queueIndex/current` + redraws loop count. Fallback reload path on error. `skipPrev()` — restart >3 s else seek-index to previous (wrap).
- `_loadFailures` guard: failed loads skip until queue exhausted, then STOP (was the 2 s crash loop).
- `playingStream` getter (engine-authored truth) — powers MiniBar glyph.
- Interruptions via `audio_session` (`playDuringCalls` respected); `becomingNoisy` → pause; `removeIfCurrent` graceful stop.
- `_silentFire()` → notifyListeners (UI in both screens uses `ListenableBuilder(RtPlayer.I)`).

### lib/extractor.dart — `Extractor.extractAndAdd(store,url,{title,folderIds,onStatus})` — Ytdlp.init/update, getVideoInfo naming (sanitize → platform+time fallback), `Ytdlp.downloadAudio` into `directoryForFolder(folderIds.firstOrNull)`, Track with `addedAtMs=now`.

### lib/library.dart
- `LibraryScreen`, `_FolderStrip`, `(_ViewToggle, _FoldersGrid|_FoldersList, _TracksView)` — drag-reorder in BOTH grid & list for folders & tracks.
- `_trackMenu` (Rename / Manage folders / red Delete) → `showFolderPick` multi-select (contains a **"➕ New folder" row** stacked create-sheet), `deleteTrackWithConfirm` — 'Don't ask again' sets `confirmDelete=false`; **root-guarded file delete**; `RtPlayer.removeIfCurrent`.
- `MiniBar` (engine-stream reactive, progress + timing).
- `importMediaFiles()` / `importMediaFolder()` / `_trackFromPath` (video → `source:'video'`, no copy) + `_trackId()`.
- `importAudioFile` ([context]) — legacy copied-import flow (copy into save root → owned → delete-able).

### lib/sheets.dart
- `AddReelSheet(+initialUrl)` (+ checkbox folder multi-select), `PlayerSheet(+startPlayback flag)`, `_LoopChip/_RangeStepper/_openRangePicker(+∞ chip)`, `showFolderCreate→FolderCreateSheet` (random default emoji; returns Future), `showInputSheet`, `showFolderPick(+"New folder")`, `showFolderMenu` — **Shuffle** (folder tracks, random head, `play(playingFrom: name)`, opens PlayerSheet with `startPlayback:false`) / Rename / Edit emoji / Delete, `showEmojiPickerSheet`.

### lib/main.dart
- `main()`: `installErrorReporting()` → `runApp` (instant) → `RtPlayer.I.ensureBackgroundService()` deferred. `installErrorReporting()` — FlutterError.onError + PlatformDispatcher.onError → `reportError`.
- `reportError` (error_report.dart): `debugPrint '⚠️ …'` + **microtask-deferred snack toast, ONE at a time** (`_toastInFlight` guard; 1 s spacing) — snackbar-in-frame dispatch froze the whole app once.
- `_SplashScreen` — coin loader only. `CoinLoader` — flipping-circle loader. Share-intent intake (`receive_intent` as `ri`; `extra['android.intent.extra.TEXT']`/`data` → URL → `AddReelSheet(initialUrl)`). `FirstRunDialog` (`Downloads/ReelTune Audios` default).

### Android (critical config)
- **Manifest (added 09:20 build):** `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `WAKE_LOCK`; `<service android:name="com.ryanheise.audioservice.AudioService" android:foregroundServiceType="mediaPlayback" android:exported="true">` + `MediaBrowserService` intent-filter; `<receiver com.ryanheise.audioservice.MediaButtonReceiver>` + `MEDIA_BUTTON` intent-filter.
- **`MainActivity : AudioServiceActivity`** (interface for the media session engine).
- `build.gradle.kts`: minSdk 24, `useLegacyPackaging=true`, `doNotStrip "**/*.zip.so"` (NEVER `excludes` — deletes engine); `gradle.properties`: kotlin.incremental=false. Share-target `SEND` filter + `singleTask` intact.

## Environment Variables
None. Build env set per-command. GitHub token in Windows Credential Manager — never in files.

## Build & Deploy
```powershell
$env:Path = "C:\src\flutter\bin;$env:Path"; $env:ANDROID_SDK_ROOT = 'E:\Android\Sdk'; $env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
cd E:\Projects\ReelTune
flutter analyze 2>&1 | Select-String ' error '        # gate: zero errors before build
flutter build apk --debug 2>&1 | Select-String 'Built |BUILD FAILED|error:'
E:\Android\Sdk\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-debug.apk  # ONLY after a fresh 'Built' line
```
Debug APK ~246 MB (4 ABIs × engine). Release plan: `--release --split-per-abi` (~40 MB arm64) untested.

## Bugs & Gotchas (hit & fixed — empirical)
1. **Gradle `excludes` deletes the yt-dlp engine** — `excludes += "**/*.zip.so"` stripped Python/yt-dlp from APK (112 MB, `PlatformException(YTDLP_ERROR … failed to initialize)`). Fix: `doNotStrip += "**/*.zip.so"` + `useLegacyPackaging=true`. 112 → 246 MB.
2. **ColorOS AlertDialog invisible** — `showDialog` renders scrim only on this device. ALL interactive confirmations are `showModalBottomSheet`. (FirstRunDialog survives — route-root standalone.)
3. **Sheet must handle keyboard** — `isScrollControlled` + inner `Padding(bottom: viewInsets.bottom)`.
4. **Store snapshotcached in sheets** — wrap in `ListenableBuilder(AppStore.I)`.
5. **Identical shuffle order across restarts** — seeded `Random(now ^ DartHashSeedRandomSalt)` per call.
6. **just_audio 0.10.6 lacks public interruption stream** — `audio_session` manual listeners + `handleInterruptions:false`.
7. **Stale-APK install trap** — failed build leaves old APK; gate install on fresh `Built` timestamp.
8. **SliverReorderableList** needs explicit `ReorderableDragStartListener` handles; grid drag needs `reorderable_grid_view` 2.2.8 `ReorderableGridView.builder` (NOT default `ReorderableGridView` — that constructor requires `childrenDelegate`; and index semantics = classic `removeAt/insert`).
9. **Error-reporter wedge (app froze on splash after logo)** — showing a SnackBar *synchronously inside frame dispatch* (`FlutterError.onError`) re-enters the scheduler → `'_FrameCallbackEntry.debugCurrentCallbackStack == null'` assertion → that error itself re-reports → infinite error cascade → permanent wedge at first painted frame. Fix: microtask-deferred toast + one-at-a-time `_toastInFlight` guard + swallow reporter-internal errors.
10. **just_audio_background silently failed init → `_audioHandler` LateInitializationError → play impossible + 2 s crash** — root cause 1: manifest was missing EVERYTHING the package needs (AudioService service/MediaBrowserService intent-filter, MediaButtonReceiver, FOREGROUND_SERVICE permissions) and MainActivity was plain `FlutterActivity` — platform-side `AudioService.init` fails, Dart `late final _audioHandler` stays unset, EVERY load throws. Root cause 2 (amplifier): `_startCurrent` catch called `skipNext()` → retried → threw → infinite fail/skip storm (logcat: same error every ms, DeadObjectException, process death in ~2 s). Fixes: full manifest wiring (above) + `MainActivity : AudioServiceActivity` + `_loadFailures` counter (skip ≤ queue length, then stop).
11. **file_picker 13.3.0 fork API** — `pickFiles` returns `List<PlatformFile>` (no FilePickerResult wrapper), no `multiple` param; `getDirectoryPath()` for folders.
12. **Deleting reference-imported files would nuke user videos** — delete flow now root-guards (`path.startsWith(saveFolderWithRoot())`); external files are only unlisted.
13. **Playing video audio directly works** — just_audio plays the audio layer of local mp4/mkv/webm; no extraction needed (user's pre-saved video library plays with zero conversion/storage cost).
14. **No compile errors known** as of 09:20:31 build 2026-10-30; analyzer warnings list is pre-existing dev-phase noise only.

## Design Decisions
- **Bundled ytdlp_flutter over Cobalt/Web:** zero-network extraction; Vercel Cobalt kept ONLY as commented failure fallback.
- **library.json single source of truth; FS layout = optimization** (All never breaks).
- **Sheets over dialogs** (ColorOS bug, app-wide pattern).
- **Dev-phase raw error toasts** on everything (`error_report.dart`), production fallback commented in place.
- **just_audio_background over raw audio_service** for MediaSession with per-track MediaItem tags; manifest wiring is mandatory (see bug 10).
- **Folder = filter + optional physical dir; multi-membership by design; empty = All-only.** Selecting a folder = active playlist ("playing from …").
- **Reference-import for local media:** videos play as-is via just_audio's audio layer; nothing copied; delete guard protects originals (user's explicit storage promise).
- **Shuffle on by default with toggle; ∞ loop added** as third loop mode (plain infinite repeat) alongside Smart/Custom — Spotify-style accent indication.
- **Gapless skips:** seek-by-index inside ConcatenatingAudioSource instead of full reload (also keeps media session state transitions clean).
- **Display name ReelTunes; internal ids unchanged** (renaming folder/on-disk path or package id would migrate/brick existing data).
- Parked: audio_service lock-screen polish, media widget play/pause verification (needs device retest post-manifest fix), EQ/sleep timer/crossfade, ads/paywall per `docs/free-vs-pro.md`.

## File Tree
```
E:\Projects\ReelTune\
├─ android/
│  ├─ app/build.gradle.kts                  # minSdk 24; useLegacyPackaging; doNotStrip zip.so
│  ├─ app/src/main/AndroidManifest.xml      # FOREGROUND_SERVICE(+MEDIA_PLAYBACK), WAKE_LOCK, AudioService svc, MediaButtonReceiver, SEND share-target, singleTask, label ReelTunes
│  ├─ gradle.properties                     # kotlin.incremental=false
│  └─ .../kotlin/com/reeltune/app/reel_tune/MainActivity.kt  # AudioServiceActivity()
├─ assets/logo.png                          # registered; splash no longer shows it
├─ lib/
│  ├─ main.dart                             # runApp-first, error reporting install, splash(coin only), share intents, FirstRunDialog
│  ├─ error_report.dart                     # rootMessengerKey + reportError (microtask, 1-at-a-time) + installErrorReporting
│  ├─ models.dart                           # Track/Folder/enums(+RtLoop.infinite), AppStore, mmss, randomLoopCount
│  ├─ player.dart                           # RtPlayer.I — boot law, MediaItem queue, ∞/smart/range loops, gapless skip, playingStream
│  ├─ extractor.dart                        # Extractor.extractAndAdd (ytdlp_flutter)
│  ├─ library.dart                          # home screen, drag reorder list+grid, track menus, delete guard, MiniBar, import pipeline
│  ├─ sheets.dart                           # AddReelSheet(checkbox folders), PlayerSheet(∞+indication, startPlayback flag), folder sheets+menu(Shuffle)
│  ├─ settings_screen.dart                  # theme/storage/playback/ReelTunes Pro
│  └─ emoji.dart                            # emojiPalette
├─ pubspec.yaml / pubspec.lock              # deps (just_audio_background beta.17 + audio_service 0.18.19 transitively)
├─ docs/free-vs-pro.md                      # gating contract; architecture.md (partially outdated)
├─ pc.md                                    # THIS file
└─ build/                                   # repo-ignored
```

## Skills & MCPs
- **Skills:** `apple-design`, `savefile` (this file + vault copy), `vault` (session/bug logs), `multi-author-commits` (commit rules below), `opencode` harness; `agent-reach` unused so far.
- **MCP:** none configured.
- **Commit rules (owner `UnfilteredAnshul`):** author = Anshul (`anshul091103@gmail.com`); committer = random pick among the 3 identities (Anshul / shreyanotfound404 / buildwithsimran); never push unless explicitly asked; tokens in Credential Manager only.
