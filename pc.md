# Project: ReelTune

## Project Identity
- **Name:** ReelTune (`com.reeltune.app.reel_tune`, label "ReelTune")
- **What it is:** Android Flutter music player for short-form video audio. User pastes a TikTok / Instagram Reel / YouTube Shorts link → the app extracts the audio **on-device** with a bundled yt-dlp engine → plays it offline through an advanced looping player.
- **Pitch:** ReelTune is a fully local, 100% on-device audio library. No cloud, no login, no server, no database. Uninstalling the app deletes everything. Users build category folders (Motivation, Edits…), share links straight from social apps, and listen with per-track random loop counts ("reel-style" repeat) via Smart or Custom-range looping with always-on session-fresh shuffle.
- **Status (2026-10-29):** Full-pro development build working end-to-end on a physical Realme RMX3381 (Android 16 / ColorOS). Extraction confirmed working for YouTube Shorts + TikTok + LimeTube links.

## Tech Stack
- **Flutter** 3.47.8 (`C:\src\flutter\bin` on PATH), Dart M3, Material 3
- **Android SDK** 36 at `E:\Android\Sdk`, **NDK** 28.2.13676358, **Java/Gradle** via Android Studio `C:\Program Files\Android\Android Studio\jbr`; `minSdk 24`
- **Package deps (pubspec.yaml):** `just_audio` 0.10.6, `just_audio_background`, `audio_session`, `receive_intent`, `ytdlp_flutter` ^0.1.0 (bundles yt-dlp + Python runtime per ABI; **GPLv3 note**), `path_provider`, `shared_preferences`, `url_launcher`, `file_picker`
- **Device:** adb at `E:\Android\Sdk\platform-tools\adb.exe`, device serial `PBFIINYP7LGE4PPV`
- **No** cloud services at all; no Firebase; no auth.

## Design System
- Single accent **`Color(0xFF0A5CD6)`** (blue) via `ColorScheme.fromSeed`.
- Neutral Material 3 theme; apple-design (HIG) sensibility: generous spacing, `showDragHandle: true` bottom sheets, `surfaceContainerHighest` tiles, 44px leading squares, circular 68px primary play button.
- Light/dark/system selectable (Settings), defaults follow the OS.
- ** emojis** used as folder icons/avatars from `emojiPalette` (`lib/emoji.dart`) — tapping emoji strip in create sheet picks the emoji.
- **Frustration-driven platform rule:** `AlertDialog`s rendered *via showDialog on this ColorOS device* show only a scrim with no box (see Bugs). → **All** interactive UI (add reel, create folder, rename, confirm-delete, folder pick, sort) uses `showModalBottomSheet` instead.

## Database Schema
No SQL database. Two persistence stores:
1. **`library.json`** (app documents dir, e.g. `/data/user/0/com.reeltune.app.reel_tune/app_flutter/library.json`):
   ```json
   {
     "tracks": [ { "id": "t1698...", "title": "...", "source": "YouTube",
                  "path": "/storage/emulated/0/Download/ReelTune Audios/....mp3",
                  "durationMs": 42000, "addedAtMs": 1793269571000,
                  "folderIds": ["f1698..."] } ],
     "folders": [ { "id": "f1698...", "name": "Motivation", "emoji": "🎯" } ]
   }
   ```
   `library.json` is the single source of truth. "All" view = full `tracks` list. The filesystem layout is an *optimization* (extraction writes into per-category subfolders), never truth — a track's `path` is what plays.
2. **SharedPreferences** keys:
   | key | type | default | meaning |
   |---|---|---|---|
   | `themeMode` | int (AppThemeMode asList index) | 0 | system/light/dark |
   | `folderView` | int (ViewMode index: list=0, grid=1) | 1 | folders view |
   | `trackView` | int | 0 | audios view |
   | `saveFolder` | string | '' | absolute path to root audio dir (e.g. `/storage/emulated/0/Download/ReelTune Audios`); empty = use app-private `.../audio` fallback |
   | `firstRunDone` | bool | false | first-run save-folder prompt done |
   | `rangeMin` / `rangeMax` | int | 3 / 5 | custom loop range for Advanced Looping |
   | `confirmDelete` | bool | true | ask before delete |
   | `playDuringCalls` | bool | false | keep playing during call interruptions |
   | `sortBy` | int (SortBy index: manual=0, name=1, dateAdded=2) | 0 | track sort |
   | `sortAsc` | bool | true | ascending/descending (for non-manual sort) |

## Auth Flow
None. No login, no accounts. `AppStore.I.fullPro` is `true` while in dev — everything unlocked. The per-feature free/pro contract lives in **`docs/free-vs-pro.md`** (free: 50 tracks, 5 folders, basic looping, no background-in-calls; pro: unlimited, Smart + custom-range looping, EQ, sleep timer, crossfade, no ads). **Gating checklist must be followed when `fullPro` flips to `false`.** Ads/payment integration is not started.

## Routing (screens)
- **`RootScreen` (`lib/main.dart`)** — wraps `LibraryScreen`; on start: `AppStore.I.init()`, share-intent listeners, first-run save-folder AlertDialog (this one IS a dialog and works — it's shown from the route root, not from a bottom sheet).
- **`LibraryScreen` (`lib/library.dart`)** — home. AppBar: ➕ New folder, Add-via-file (`playlist_add`), ⚙ Settings. Body `CustomScrollView`: `_FolderStrip` (chips: 🎧 All, each folder, ➕ New folder-opens-create-sheet) → "Folders (n)" header + segmented list/grid toggle → folders grid (cards) or reorderable list → tracks header ("All audios (n)" / "In `<folder>` (n)") + **sort button** + view toggle → tracks grid/cards or reorderable list. FAB: "Add reel" (link modal). `MiniBar` bottom bar when something is playing (tap opens player).
- **`PlayerSheet` (`lib/sheets.dart`)** — modal bottom sheet player: title, 'from <source> · audio only', position slider + mmss, **"Advanced Looping"** section with exactly 2 chips: **Smart (auto)** and **Custom range (N-Mx)** (label shows live stored range; tapping opens `_openRangePicker` = two steppers min/max with +/− buttons, Apply persists via `store.setRangeMin/setRangeMax` and switches player to `RtLoop.customRange`), transport row (shuffle / 1-play button that cycles 1x delloops… / prev / big circular play / next / repeat).
- **`AddReelSheet` (`lib/sheets.dart`)** — URL field (**`initialUrl` prefilled when opened from a share intent**), optional title, folder dropdown (options: `📁 ReelTune Audios (root)`, each category, `➕ New folder…`), or "import an audio file instead". Extract button runs `Extractor.extractAndAdd`, states idle/running/done; **dev-phase failure shows a raw error toast** (first 300 chars); `Navigator.pop` + `_onExtractionFailed` fallback (website wrapper + file import) is **commented out, not deleted** (reactivated after dev phase).
- **`FolderCreateSheet` (`lib/sheets.dart`)** — name field (autofocus, Enter=Create), emoji strip, Create button.
- **`SettingsScreen` (`lib/settings_screen.dart`)** — Appearance radios; Storage: audios folder picker + 'Delete on uninstall' explainer; Playback: Confirm-before-delete switch, Keep-playing-during-calls switch; Account: ReelTune Pro explainer.

## Components / Lib (per file)
### lib/models.dart
- `class Track { id; title; source; path; durationMs; addedAtMs; folderIds }` (JSON map).
- `class Folder { id; name; emoji }`.
- Enums: `AppThemeMode{system,light,dark}`, `ViewMode{list,grid}`, `RtLoop{smart,customRange}`, `SortBy{manual,name,dateAdded}`.
- **`AppStore` (ChangeNotifier singleton `AppStore.I`):** holds `tracks`, `folders`, prefs fields above. Key methods:
  - `init()` — load prefs + library.json; `save()` — write JSON + prefs; `_persist()` = save + notifyListeners.
  - `addFolder(name, emoji)`, `deleteFolder(id)` (also strips folderId from tracks; dir stays on disk), `renameTrack(id, title)`, `setTrackFolders(id, ids)`, `updateTrackDuration(id, ms)`, `removeTrack(id)`, `addTrack(t)`.
  - `visibleTracks` — filter by `selectedFolderId`; **`visibleTracksSorted`** — sorted per `sortBy`/`sortAsc`, ties broken by store order (Dart sort is unstable);
  - `reorderVisibleTracks(oldIndex, newIndex)` — drag reorder inside the visible slice (handles filtering; switches `sortBy` to manual); `reorderFolders(oldIndex, newIndex)`.
  - `directoryForFolder(folderId?)` — root or `root/`+ sanitized `'<emoji-letters>_<f.id>'` subdirectory (created recursive; falls back to root); `saveFolderWithRoot()` — saveFolder or `_createFallbackRoot()` app docs `…/audio`.
  - `setSaveFolder/setThemeMode/setTrackView/setFolderView/setRangeMin/setRangeMax/setConfirmDelete/setPlayDuringCalls/setSortBy/setSortAsc` — all `_mutateSetting` (persist+notify).
  - **`fullPro` — returns `true` for now.**
- `randomLoopCount([min, max])` — inclusive random in clamped [1..999].
- `mmss(ms)` — 'm:ss' formatting (in library.dart? it's exported from models area and used everywhere).

### lib/player.dart — `RtPlayer` (ChangeNotifier singleton `RtPlayer.I`)
- Wraps ONE `AudioPlayer` with **`handleInterruptions: false`** (manual control).
- **Background playback + media notification/lock-screen/system media widget** via `just_audio_background`: queue is a `ConcatenatingAudioSource` of `AudioSource.file(path, tag: MediaItem(id, title, artist: source, duration))`, started at `initialIndex`.
- State: `current`, `queue` (shuffled), `queueIndex`, `loop` (RtLoop), `shuffleOn = true` (always), `_targetLoops`, `_loopsDone`.
- **`Play(track, contextTracks)`** → Fisher–Yates with **fresh seed each call** `Random(DateTime.now().microsecondsSinceEpoch ^ 0x5f4d9e17)`; tapped track moved to front; identical sequences never repeat across app restarts.
- **`_onState`** — on `ProcessingState.completed`: `_loopsDone++`; if `< _targetLoops` → seek(0) + play (loop again); else → `skipNext()` (next track draws its own random count via `_loopsTarget()`).
- `_loopsTarget()` — range from store; Smart mode boosts max+1 for clips < 30s.
- Interruptions: `audio_session` `interruptionEventStream` → if `playDuringCalls` setting off → pause + resume after; if on → re-assert play (kept playing during calls). `becomingNoisyEventStream` → pause (headphones unplugged).
- `currentIndexStream` — keeps `queueIndex`/`current` in sync when the media notification changes track.
- `removeIfCurrent(id)` — deleted track stops playback gracefully; `seek(fraction)`, `toggle()`, `skipPrev()` (restarts if >3s), `skipNext()`.

### lib/extractor.dart — `Extractor`
- `extractAndAdd(store, url, {title, folderIds, onStatus})`:
  1. `Ytdlp.init()` (unpacks engine; slow first run)
  2. `Ytdlp.getVideoInfo(url)` for real title
  3. Name: user title → info.title sanitized (`[/\\:*?"<>|]` → `_`) → fallback `'TikTok · HH:mm'`-style platform+time
  4. Output dir = `store.directoryForFolder(folderIds.firstOrNull)`
  5. `Ytdlp.downloadAudio(url, path)` → Track(addedAtMs=now) → `store.addTrack`
- Sources seen in logs (LimeTube + YouTube Shorts confirmed working on device).

### lib/library.dart
- Widgets: `LibraryScreen`, `_FolderStrip` (chips w/ '+ New folder' opens `showFolderCreate`), `_FilterChipWrap`, `_FoldersGrid` (incl. ➕ New-folder tile; empty-visible), `_FoldersList` (**`SliverReorderableList`** + drag handle + `_NewFolderRow`), `_FoldersHeader` w/ `_ViewToggle` (generalized `value`/`on` segmented button), sort sheet `showTrackSortSheet` (RadioGroup Manual/Name/Date-added + ascending switch when non-manual), `_TracksView` (grid cards or **`SliverReorderableList`**), `_TrackCard`, `TrackTile` (optional `handle` widget for drag), `_EmptyLibrary`.
- `_trackMenu(context, track)` — bottom-sheet menu: **Rename** (via `showInputSheet`), **Manage folders** (via `showFolderPick` multi-select checkbox sheet → `setTrackFolders`), **Delete** (red → `deleteTrackWithConfirm`).
- `deleteTrackWithConfirm` — if `store.confirmDelete`: bottom sheet with title/text + **'Don't ask again' CheckboxListTile** (sets `confirmDelete=false`) + red FilledButton Delete; then `File(path).deleteSync()` + `store.removeTrack` + `RtPlayer.I.removeIfCurrent`.
- `MiniBar` — persistent bottom playback bar.
- `importAudioFile` / `importAudioPickFolder` — file_picker import (copy into save dir, Track id via `_trackId()`).

### lib/sheets.dart
- `AddReelSheet` (+ `initialUrl`), `_openRangePicker`, `_LoopChip`, `_RangeStepper`, `PlayerSheet`, `showFolderCreate(context)` + `FolderCreateSheet`, `showInputSheet(...)` (generic rename sheet), `showFolderPick(context, track)` (multi-select).
- `fallbackWebsiteUrl` — const for the Cobalt-on-Vercel wrapper (used by `_onExtractionFailed`, currently commented).

### lib/main.dart
- `main()`: `WidgetsFlutterBinding.ensureInitialized()` → `JustAudioBackground.init(androidNotificationChannelId: 'com.reeltune.app.reel_tune.playback', channelName 'ReelTune playback', ongoing, stopForegroundOnPause)` → `runApp`.
- Share intents (`package:receive_intent` as `ri`): `getInitialIntent` + `receivedIntentStream` → extract URL from `extra['android.intent.extra.TEXT']` or `data` → open `AddReelSheet(initialUrl: …)`.
- `FirstRunDialog` — default `Downloads/ReelTune Audios` prompt ('Use default' pre-creates `/storage/emulated/0/Download/ReelTune Audios`).

## Environment Variables
None. No .env. Android SDK + Java live in machine PATH env (`E:\Android\Sdk`, `C:\Program Files\Android\Android Studio\jbr`) — set per build command in this shell script:
```powershell
$env:Path = "C:\src\flutter\bin;$env:Path"; $env:ANDROID_SDK_ROOT = 'E:\Android\Sdk'
```
Tokens: GitHub in **Windows Credential Manager** (`git:https://github.com` etc.) — never pasted.

## Migrations
None. Schema evolved in place: `addedAtMs` + prefs keys added to `Track`/`AppStore` with defaults; old `library.json` loads fine (missing keys default).

## Seed Data
None in code. Test data = real extracted reels on the test phone. Manual test matrix documented above.

## Build & Deploy
```powershell
# every session, one-liner pattern:
$env:Path = "C:\src\flutter\bin;$env:Path"; $env:ANDROID_SDK_ROOT = 'E:\Android\Sdk'; $env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
cd E:\Projects\ReelTune
flutter analyze
flutter build apk --debug
E:\Android\Sdk\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-debug.apk
```
- Debug APK is ~246 MB (all 4 engine ABIs). Release: use `flutter build apk --release --split-per-abi` → ~40 MB arm64 is the plan (untested yet; engine must still get `doNotStrip`/legacy packaging).
- **Android config (critical) — `android/app/build.gradle.kts`:**
  ```kotlin
  minSdk = 24
  packaging { jniLibs {
      useLegacyPackaging = true
      doNotStrip += listOf("**/*.zip.so")   // engine zips-as-.so; NEVER use `excludes`
  } }
  ```
  plus `android/gradle.properties`: `kotlin.incremental=false`.
- Manifest permissions: `INTERNET`; activity `android:launchMode="singleTask"` (share-target single-instance) + `ACTION_SEND text/plain` intent-filter (share sheet entry).
- No CI/CD; not deployed anywhere (fully local app).

## Bugs & Gotchas (all hit & fixed)
1. **`PlatformException(YTDLP_ERROR, failed to initialize, yt-dlp=unknown, update=not-attempted)`** on extract. Root cause: `packaging { jniLibs { excludes += listOf("**/*.zip.so") } }` — in Gradle, `excludes` **deletes files from the APK**, stripping the Python/yt-dlp engine; APK size stayed 112 MB. Fix: remove `excludes` entirely, keep `doNotStrip += "**/*.zip.so"` + `useLegacyPackaging = true`. APK jumped 112 → **246 MB** (4 ABIs × engine) and extraction started working.
2. **Vanishing AlertDialogs on ColorOS/Realme** — `showDialog` from any context (dropdown, appbar) shows only the light scrim, no dialog box. Every dialog was converted to `showModalBottomSheet` (input/pick/confirm/sort all sheets). First-run dialog survives because it's triggered standalone early on the route root.
3. **Excess build noise** — init error came from strip noise on `zip.so`: solved by `doNotStrip`, plus `kotlin.incremental=false` in gradle.properties, `minSdk 24`, `INTERNET` permission.
4. **Keyboard overlaps Add-reel form** — sheet must combine scroll-controlled showModalBottomSheet + `Padding(bottom: MediaQuery.of(context).viewInsets.bottom)` inside the sheet itself.
5. **Folder dropdown never showed folders** — AppStore.I snapshot cached at sheet open; wrapped in `ListenableBuilder(listenable: AppStore.I)`. Also user had no folders because there was NO create-folder entry point in the main screen (only deep in add sheet) — added AppBar icon + strip chip + grid tile + dropdown item.
6. **Shuffle repeating identical order across app restarts** — same Random default seed. Fix: `Random(DateTime.now().microsecondsSinceEpoch ^ DartHashSeedRandomSalt)` per call, tapped track front-pinned.
7. **`flutter analyze` unused/warnings after dev-phase changes** — dev-phase error toast (`ScaffoldMessenger` in `_extract`), `_onExtractionFailed` + `fallbackWebsiteUrl` intentionally kept but commented; analyzer warns `unused_element`/`unused_local_variable` — expected until dev phase ends.
8. **just_audio 0.10.6 has no public `interruptionEventStream`**, and `handleInterruptions:false` kills built-in handling → use **`audio_session`** package (`AudioSession.instance.interruptionEventStream` / `becomingNoisyEventStream`) manually.
9. **ri.Intent vs flutter Intent** — `import 'package:receive_intent/receive_intent.dart' as ri;` to avoid Material Intent clash. ri.Intent exposes `extra` (Map?) + `data` (String?) — no `dataString`.
10. **Stale-APK install pitfall** — when build fails, the previous `build/app/outputs/flutter-apk/app-debug.apk` still exists and `adb install -r` "succeeds" with old code. Always gate install on a fresh `Built …apk` line; cross-check APK `LastWriteTime`.
11. **`SliverReorderableList` has no `buildDefaultDragHandles`** — attach explicit `ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle))` trailing handles; long-press stays free for the context menu.
12. **Dart sorts are unstable** — tracks sharing keys (e.g. all legacy `addedAtMs=0`) scramble on every rebuild; sort ties on store index.

## Design Decisions
- **Bundled `ytdlp_flutter` over server-side Cobalt:** user wanted zero network dependency beyond the source-request; Cobalt is Node (impossible in-app); Vercel-hosted Cobalt kept only as an extraction-failure fallback website (dev-phase-showed, production = file-import fallback + info sheet).
- **100% local-first:** extraction to `Downloads/ReelTune Audios/<category>`, library index in private app storage; uninstall = total delete (checked off 'Delete on uninstall' warning in Settings).
- **library.json as the single index** and shards on real FS as optimization — lets 'All' never be empty even when physical dirs get moved/deleted.
- **"All" = full track list** by design; folder selection = just `visibleTracks` filter.
- **Bottom sheets over dialogs**, because of the FlexBeth color-scheme device bug (#2) — consistent UI pattern got adopted app-wide.
- **Dev-phase raw errors:** during dev, extraction failures show the raw exception text in a toast; the production fallback sheet is commented but kept in code (`_onExtractionFailed`), switched on later.
- **Chips in player:** only Smart (auto) + Custom range (le off, fixed, infinite menu modes dropped from UI); both live off the same persisted 3–5 default range; custom-range dialog via steppers.
- **Shuffle always on** + per-session random seed for "reel-style" repeated tracks + non-repeating sequences.
- **`audio_service`/just_audio_background:** just_audio_background chosen over full audio_service setup (same engine internally, way less boilerplate, immediate MediaSession + notification).
- **Later/big features parked:** audio-service background customizer, EQ, sleep timer, crossfade, ads/paywall, download-permissions (all listed in docs/free-vs-pro.md gating).

## File Tree
```
E:\Projects\ReelTune\
├─ android/
│  ├─ app/build.gradle.kts          # minSdk 24, doNotStrip/or packaging engine fix
│  ├─ app/src/main/AndroidManifest.xml  # INTERNET; SEND share-target; singleTask
│  ├─ gradle.properties             # kotlin.incremental=false
│  └─ src/main/kotlin/com/reeltune/app/reel_tune/MainActivity.kt  # FlutterActivity()
├─ lib/
│  ├─ main.dart                     # main(), JustAudioBackground.init, share intents, FirstRunDialog, RootScreen
│  ├─ models.dart                   # Track/Folder + enums, AppStore.I: prefs, queries, reorders, directoryForFolder
│  ├─ player.dart                   # RtPlayer.I: queue/shuffle/loop-engine, audio_session interruptions, MediaItem tags
│  ├─ extractor.dart                # Extractor.extractAndAdd via ytdlp_flutter
│  ├─ library.dart                  # home screen: folders strip/grid/list(+reorder), tracks sort view, menus, MiniBar
│  ├─ sheets.dart                   # AddReelSheet, PlayerSheet+looping UI, FolderCreateSheet, pickers/inputs
│  ├─ settings_screen.dart          # theme, storage, playback switches, Pro card
│  └─ emoji.dart                    # emojiPalette for folder icons
├─ pubspec.yaml                     # deps incl just_audio(0.10.6)+just_audio_background+receive_intent+audio_session
├─ docs/
│  ├─ free-vs-pro.md                # per-feature contract + licensing (yt-dlp GPLv3, Cobalt AGPL-3)
│  └─ architecture.md               # original architecture notes (partially outdated)
├─ pc.md                            # THIS file
├─ device_log.txt                   # last logcat dump (repo-ignored)
└─ build/                           # (repo-ignored)
```

## Skills & MCPs
- **Skills used:** `apple-design` (UI/HIG style for sheets/player), `multi-author-commits` (GitHub backup rules: owner/an author/committer randomization rules; no-push default unless explicitly asked), `savefile` (this pc.md + vault copy), `vault` (second-brain session log), `opencode` (harness), `agent-reach` (not needed yet).
- **MCP:** none configured.
- **Workflow rules for commits on this repo (owner UnfilteredAnshul):** author = `Anshul Rajpal <anshul091103@gmail.com>`, committer = random pick among Anshul/Shreya (`shreyanotfound404`)/Simran (`buildwithsimran`) identities; never store tokens in files (Windows Credential Manager); push only when explicitly requested.
