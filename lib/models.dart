// ReelTune data models + central store.
// Library persists as JSON in the app documents dir; settings in
// SharedPreferences. Migrate to Hive later if needed.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'entitlements.dart';
import 'link_rules.dart';

enum AppThemeMode { system, light, dark }

enum ViewMode { list, grid }

enum RtLoop { off, smart, customRange, infinite }

enum SortBy { manual, name, dateAdded }

/// Date-added filter for the library. Session-only on purpose: a fresh
/// launch always shows the whole library.
enum DateFilter { any, today, week, month }

extension DateFilterLabel on DateFilter {
  String get label => switch (this) {
        DateFilter.any => 'Any time',
        DateFilter.today => 'Today',
        DateFilter.week => 'Last 7 days',
        DateFilter.month => 'Last 30 days',
      };
}

class Folder {
  final String id;
  String name;
  String emoji;
  Folder({required this.id, required this.name, required this.emoji});

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'emoji': emoji};
  static Folder fromMap(Map<String, dynamic> m) =>
      Folder(id: m['id'], name: m['name'], emoji: m['emoji'] ?? '📁');
}

class Track {
  final String id;
  String title;
  final String source; // 'import' for now; tiktok/ig/yts once extraction lands
  String path; // absolute path or content:// URI of the audio file
  /// File name inside the audios folder. It is how the folder and the library
  /// are matched, and it is what the metadata mirror stores (URIs do not
  /// survive a reinstall, names do).
  String fileName;
  /// The link this track was extracted from (`''` for imports). Used to stop
  /// the same reel being added twice.
  String sourceUrl;
  int durationMs; // filled after the first successful load
  List<String> folderIds;
  int addedAtMs; // epoch ms of import; 0 for tracks added before this field

  Track({
    required this.id,
    required this.title,
    required this.source,
    required this.path,
    this.fileName = '',
    this.sourceUrl = '',
    this.durationMs = 0,
    int? addedAtMs,
    List<String>? folderIds,
  })  : addedAtMs = addedAtMs ?? 0,
        folderIds = folderIds ?? [];

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'source': source,
        'path': path,
        'fileName': fileName,
        'sourceUrl': sourceUrl,
        'durationMs': durationMs,
        'addedAtMs': addedAtMs,
        'folderIds': folderIds,
      };

  static Track fromMap(Map<String, dynamic> m) => Track(
        id: m['id'],
        title: m['title'],
        source: m['source'] ?? 'import',
        path: m['path'],
        fileName: m['fileName'] ?? '',
        sourceUrl: m['sourceUrl'] ?? '',
        durationMs: (m['durationMs'] ?? 0) as int,
        addedAtMs: (m['addedAtMs'] ?? 0) as int,
        folderIds: List<String>.from(m['folderIds'] ?? const []),
      );
}

/// Central app state — library + settings. Single instance `AppStore.I`.
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore I = AppStore._();

  final List<Track> tracks = [];
  final List<Folder> folders = [];

  // settings
  AppThemeMode themeMode = AppThemeMode.system;
  ViewMode folderView = ViewMode.grid;
  ViewMode trackView = ViewMode.list;
  String saveFolder = ''; // absolute path; empty until first-run setup
  bool firstRunDone = false;

  /// The audios folder as a SAF tree. Android denies raw paths in Download, so
  /// this is the real storage location; [saveFolder] is legacy display state.
  bool audiosLinked = false;
  String audiosUri = '';
  String audiosName = '';
  bool audiosWritable = false;

  /// Set by LibrarySync: mirrors playlists into the audios folder after saves.
  Future<void> Function()? onLibrarySaved;

  /// File names the user took out of the library with "Remove from ReelTunes".
  /// The file stays in the audios folder, so without this list the folder scan
  /// would quietly put it back.
  List<String> hiddenFileNames = [];

  void setAudiosFolder({
    required bool linked,
    String uri = '',
    String name = '',
    bool writable = false,
  }) {
    audiosLinked = linked;
    audiosUri = uri;
    audiosName = name;
    audiosWritable = writable;
    notifyListeners();
  }

  // Advanced looping: user's custom loop-count range (persisted; 3-5 default)
  int rangeMin = 3;
  int rangeMax = 5;

  // per-feature prefs
  bool confirmDelete = true; // ask before deleting a track
  bool confirmRemove = true; // ask before removing a track from the library
  bool playDuringCalls = false; // keep audio playing when a call comes in
  SortBy sortBy = SortBy.manual; // manual = user-drag order (tracks)
  bool sortAsc = true; // ascending when sortBy != manual

  String? selectedFolderId; // null = All audios

  /// The track the player loaded last. The mini bar uses it on a fresh launch
  /// (the engine has nothing loaded yet), so the bar is never empty even
  /// though playback always starts paused.
  String lastTrackId = '';

  // Library search + date filter (session state — deliberately not persisted,
  // so relaunching always shows everything).
  String searchQuery = '';
  DateFilter dateFilter = DateFilter.any;

  /// Whether the playlist list/grid under the chip strip is open. Session
  /// state: collapsing is a quick "get it out of the way", not a preference.
  bool playlistsExpanded = true;

  /// The "how it works" bar on the home screen. Hidden for good once the
  /// user opens the guide or closes the bar.
  bool guideBannerDismissed = false;

  /// Rolling history of custom-range loop counts the user actually let play
  /// out. Smart looping samples this, so someone who keeps choosing 6-8 stops
  /// being served 3-5. Capped to recent behavior, not all-time.
  List<int> loopHistory = [];
  static const int maxLoopHistory = 12;

  bool get fullPro => Entitlements.I.isPro;

  /// Files the folder scan had to leave out because the free tier is full.
  /// Drives the "N more files in your folder · Pro to add" row. Never a
  /// deletion: the files stay on disk and in the file manager.
  int folderOverflow = 0;
  void setFolderOverflow(int n) {
    if (folderOverflow == n) return;
    folderOverflow = n;
    notifyListeners();
  }

  late SharedPreferences _prefs;
  File? _libFile;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final docs = await getApplicationDocumentsDirectory();
    _libFile = File(
        '${docs.path}${Platform.pathSeparator}library.json');

    themeMode = AppThemeMode.values[_prefs.getInt('themeMode') ?? 0];
    folderView = ViewMode.values[_prefs.getInt('folderView') ?? 1];
    trackView = ViewMode.values[_prefs.getInt('trackView') ?? 0];
    saveFolder = _prefs.getString('saveFolder') ?? '';
    firstRunDone = _prefs.getBool('firstRunDone') ?? false;
    rangeMin = _prefs.getInt('rangeMin') ?? 3;
    rangeMax = _prefs.getInt('rangeMax') ?? 5;
    if (rangeMin < 1) rangeMin = 1;
    if (rangeMax < rangeMin) rangeMax = rangeMin;
    confirmDelete = _prefs.getBool('confirmDelete') ?? true;
    confirmRemove = _prefs.getBool('confirmRemove') ?? true;
    playDuringCalls = _prefs.getBool('playDuringCalls') ?? false;
    sortBy = SortBy.values[_prefs.getInt('sortBy') ?? 0];
    sortAsc = _prefs.getBool('sortAsc') ?? true;
    guideBannerDismissed = _prefs.getBool('guideBannerDismissed') ?? false;
    hiddenFileNames = _prefs.getStringList('hiddenFileNames') ?? const [];
    lastTrackId = _prefs.getString('lastTrackId') ?? '';
    loopHistory = (_prefs.getStringList('loopHistory') ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toList();

    if (_libFile!.existsSync()) {
      try {
        final data = jsonDecode(_libFile!.readAsStringSync())
            as Map<String, dynamic>;
        folders
          ..clear()
          ..addAll((data['folders'] as List? ?? [])
              .map((m) => Folder.fromMap(m as Map<String, dynamic>)));
        tracks
          ..clear()
          ..addAll((data['tracks'] as List? ?? [])
              .map((m) => Track.fromMap(m as Map<String, dynamic>)));
      } catch (_) {/* start empty rather than crash */}
    }
    notifyListeners();
  }

  Future<void> save() async {
    final data = {
      'folders': folders.map((f) => f.toMap()).toList(),
      'tracks': tracks.map((t) => t.toMap()).toList(),
    };
    _prefs.setInt('themeMode', themeMode.index);
    _prefs.setInt('folderView', folderView.index);
    _prefs.setInt('trackView', trackView.index);
    _prefs.setString('saveFolder', saveFolder);
    _prefs.setBool('firstRunDone', firstRunDone);
    _prefs.setInt('rangeMin', rangeMin);
    _prefs.setInt('rangeMax', rangeMax);
    _prefs.setBool('confirmDelete', confirmDelete);
    _prefs.setBool('confirmRemove', confirmRemove);
    _prefs.setBool('playDuringCalls', playDuringCalls);
    _prefs.setInt('sortBy', sortBy.index);
    _prefs.setBool('sortAsc', sortAsc);
    _prefs.setBool('guideBannerDismissed', guideBannerDismissed);
    _prefs.setStringList('hiddenFileNames', hiddenFileNames);
    _prefs.setString('lastTrackId', lastTrackId);
    _prefs.setStringList(
        'loopHistory', [for (final n in loopHistory) '$n']);
    try {
      await _libFile!.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {/* preview: ignore write errors */}
    // Mirror into the audios folder so a reinstall can restore playlists.
    final hook = onLibrarySaved;
    if (hook != null) {
      try {
        await hook();
      } catch (_) {/* the folder may be unlinked or read-only */}
    }
  }

  void _persist() {
    save();
    notifyListeners();
  }

  // ---- mutations ----
  void addFolder(String name, String emoji) {
    folders.add(Folder(
        id: 'f${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        emoji: emoji.isEmpty ? '📁' : emoji));
    _persist();
  }

  void deleteFolder(String id) {
    folders.removeWhere((f) => f.id == id);
    if (selectedFolderId == id) selectedFolderId = null;
    for (final t in tracks) {
      t.folderIds.remove(id);
    }
    _persist();
  }

  void renameFolder(String id, String name) {
    final f = folderById(id);
    if (f == null || name.isEmpty || f.name == name) return;
    f.name = name;
    _persist();
  }

  void setFolderEmoji(String id, String emoji) {
    final f = folderById(id);
    if (f == null || emoji.isEmpty || f.emoji == emoji) return;
    f.emoji = emoji;
    _persist();
  }

  void addTrack(Track t) {
    // Adding something explicitly always wins over an earlier "remove from
    // ReelTunes", otherwise the folder scan would keep suppressing it.
    if (t.fileName.isNotEmpty) {
      hiddenFileNames.removeWhere((n) => n == t.fileName);
    }
    tracks.add(t);
    _persist();
  }

  /// "Remove from ReelTunes" (file stays in the audios folder). Remembering the
  /// file name stops the next folder scan from re-adding it.
  void removeTrackKeepFile(String id) {
    final t = trackById(id);
    if (t == null) return;
    if (t.fileName.isNotEmpty && !hiddenFileNames.contains(t.fileName)) {
      hiddenFileNames.add(t.fileName);
    }
    removeTrack(id);
  }

  void updateTrackDuration(String id, int ms) {
    final t = trackById(id);
    if (t != null && t.durationMs == 0) {
      t.durationMs = ms;
      _persist();
    }
  }

  void removeTrack(String id) {
    tracks.removeWhere((t) => t.id == id);
    if (lastTrackId == id) {
      lastTrackId = '';
      _prefs.setString('lastTrackId', '');
    }
    _persist();
  }

  /// Records what the player has loaded so the mini bar can show it again after
  /// a relaunch. Plain pref write (no library save/mirror) — this fires on every
  /// track change.
  void setLastPlayedId(String id) {
    if (lastTrackId == id) return;
    lastTrackId = id;
    _prefs.setString('lastTrackId', id);
    notifyListeners();
  }

  void renameTrack(String id, String title) {
    final t = trackById(id);
    if (t != null) {
      t.title = title;
      _persist();
    }
  }

  void setTrackFolders(String id, List<String> ids) {
    final t = trackById(id);
    if (t != null) {
      t.folderIds
        ..clear()
        ..addAll(ids);
      _persist();
    }
  }

  void setThemeMode(AppThemeMode m) => _mutateSetting(() => themeMode = m);
  void setFolderView(ViewMode v) => _mutateSetting(() => folderView = v);
  void setTrackView(ViewMode v) => _mutateSetting(() => trackView = v);
  void setSaveFolder(String p) => _mutateSetting(() => saveFolder = p);

  void setConfirmDelete(bool v) => _mutateSetting(() => confirmDelete = v);
  void setConfirmRemove(bool v) => _mutateSetting(() => confirmRemove = v);
  void setPlayDuringCalls(bool v) => _mutateSetting(() => playDuringCalls = v);
  void setSortBy(SortBy s) => _mutateSetting(() => sortBy = s);
  void setSortAsc(bool v) => _mutateSetting(() => sortAsc = v);

  void setRangeMin(int v) =>
      _mutateSetting(() => rangeMin = v.clamp(1, rangeMax));
  void setRangeMax(int v) =>
      _mutateSetting(() => rangeMax = v.clamp(rangeMin, 999));
  /// Sets both ends in one go (a min above the old max must not get clamped
  /// away before the new max lands).
  void setRange(int min, int max) => _mutateSetting(() {
        rangeMin = min.clamp(1, 999);
        rangeMax = max.clamp(1, 999);
        if (rangeMax < rangeMin) rangeMax = rangeMin;
      });
  String get rangeLabel => '$rangeMin-${rangeMax}x';

  /// Remembers a loop session the user actually listened through. Only full
  /// custom-range completions are recorded — a skip is not a preference.
  void recordLoopCount(int count) {
    if (count < 1 || count > 99) return;
    loopHistory.add(count);
    while (loopHistory.length > maxLoopHistory) {
      loopHistory.removeAt(0);
    }
    _prefs.setStringList(
        'loopHistory', [for (final n in loopHistory) '$n']);
  }

  /// One of the user's recent custom-range counts, or null when Smart has no
  /// signal yet (it then falls back to the 3-5 style range).
  int? learnedLoopCount() {
    if (loopHistory.isEmpty) return null;
    return loopHistory[Random().nextInt(loopHistory.length)].clamp(1, 99);
  }

  // ---- physical folders (Downloads/ReelTune Audios/<category>) ----
  /// Sub-directory on disk for a library folder: root/category-name.
  /// Tracks keep living in library.json — the fs layout is an optimization,
  /// never the source of truth, so "All" always lists everything.
  String? directoryForFolder(String? folderId) {
    if (folderId == null) return saveFolderWithRoot();
    final f = folderById(folderId);
    if (f == null) return saveFolderWithRoot();
    final root = saveFolderWithRoot();
    if (root == null) return null;
    final safe =
        f.emoji.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '').trim() +
            '_' +
            f.id;
    final dir = '$root${Platform.pathSeparator}$safe';
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {
      return root; // fallback: root instead of crashing the intake flow
    }
    return dir;
  }

  String? saveFolderWithRoot() {
    // root preference; when unset use app-private dir (path from extractor)
    if (saveFolder.trim().isNotEmpty) return saveFolder;
    if (_fallbackRootCase == null) {
      _createFallbackRoot();
    }
    return _fallbackRootCase;
  }

  static String? _fallbackRootCase;
  Future<void> _createFallbackRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = '${docs.path}${Platform.pathSeparator}audio';
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {}
    _fallbackRootCase = dir;
  }
  void completeFirstRun(String folder) {
    saveFolder = folder;
    firstRunDone = true;
    _persist();
  }

  void _mutateSetting(VoidCallback f) {
    f();
    _persist();
  }

  // ---- queries ----
  void selectFolder(String? id) {
    selectedFolderId = id;
    notifyListeners();
  }

  void setSearchQuery(String q) {
    if (searchQuery == q) return;
    searchQuery = q;
    notifyListeners();
  }

  void setDateFilter(DateFilter f) {
    if (dateFilter == f) return;
    dateFilter = f;
    notifyListeners();
  }

  void togglePlaylists() {
    playlistsExpanded = !playlistsExpanded;
    notifyListeners();
  }

  void dismissGuideBanner() {
    if (guideBannerDismissed) return;
    guideBannerDismissed = true;
    _persist();
  }

  // ---- grid rearrange mode (menu-invoked; never persisted) ----
  bool arrangingFolders = false;
  bool arrangingTracks = false;
  bool get anyArranging => arrangingFolders || arrangingTracks;
  void startArranging({required bool folders}) {
    arrangingFolders = folders;
    arrangingTracks = !folders;
    notifyListeners();
  }

  void stopArranging() {
    arrangingFolders = false;
    arrangingTracks = false;
    notifyListeners();
  }

  void refresh() {
    notifyListeners();
  }

  /// Tracks matching the current folder + name search + date filter, in
  /// store order. One place so the count, list, grid and play queue agree.
  List<Track> _baseVisible() {
    final sel = selectedFolderId;
    final q = searchQuery.trim().toLowerCase();
    final now = DateTime.now();
    final sinceMs = switch (dateFilter) {
      DateFilter.any => 0,
      DateFilter.today =>
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
      DateFilter.week =>
        now.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
      DateFilter.month =>
        now.subtract(const Duration(days: 30)).millisecondsSinceEpoch,
    };
    return tracks.where((t) {
      if (sel != null && !t.folderIds.contains(sel)) return false;
      if (q.isNotEmpty && !t.title.toLowerCase().contains(q)) return false;
      if (sinceMs > 0 && (t.addedAtMs <= 0 || t.addedAtMs < sinceMs)) {
        return false;
      }
      return true;
    }).toList();
  }

  Iterable<Track> get visibleTracks => _baseVisible();

  /// visibleTracks in display order: store order when sortBy==manual,
  /// otherwise name/date added with the asc/desc preference.
  List<Track> get visibleTracksSorted {
    final list = _baseVisible();
    final order = {
      for (var i = 0; i < list.length; i++) list[i].id: i,
    };
    if (sortBy == SortBy.name) {
      list.sort((a, b) {
        var c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        if (c == 0) c = order[a.id]!.compareTo(order[b.id]!);
        return sortAsc ? c : -c;
      });
    } else if (sortBy == SortBy.dateAdded) {
      list.sort((a, b) {
        var c = a.addedAtMs.compareTo(b.addedAtMs);
        if (c == 0) c = order[a.id]!.compareTo(order[b.id]!);
        return sortAsc ? c : -c;
      });
    }
    return list;
  }

  /// Drag-reorder inside the currently visible slice (folder + search +
  /// date filter). Only the matching tracks are resequenced; everything else
  /// keeps its place in the store.
  void reorderVisibleTracks(int oldIndex, int newIndex) {
    final visible = _baseVisible();
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    newIndex =
        (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, visible.length);
    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);
    final ids = {for (final t in visible) t.id};
    var vi = 0;
    for (var i = 0; i < tracks.length; i++) {
      if (ids.contains(tracks[i].id)) tracks[i] = visible[vi++];
    }
    // A drag = the user wants manual control again.
    sortBy = SortBy.manual;
    _persist();
  }

  /// Drag-reorder of the folders strip/grid/list (manual at all times).
  void reorderFolders(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= folders.length) return;
    newIndex =
        (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, folders.length);
    final f = folders.removeAt(oldIndex);
    folders.insert(newIndex, f);
    _persist();
  }

  Folder? folderById(String id) =>
      folders.where((f) => f.id == id).firstOrNull;

  Track? trackById(String id) =>
      tracks.where((t) => t.id == id).firstOrNull;

  /// Existing track saved from the same link, ignoring tracking parameters.
  Track? trackBySourceUrl(String url) {
    final key = canonicalLink(url);
    for (final t in tracks) {
      if (t.sourceUrl.isNotEmpty && canonicalLink(t.sourceUrl) == key) return t;
    }
    return null;
  }

  /// Existing track for an imported file, matched by name the same way the
  /// folder scan and the mirror do.
  Track? trackByFileName(String fileName) {
    final key = fileName.toLowerCase();
    for (final t in tracks) {
      if (t.fileName.toLowerCase() == key) return t;
    }
    return null;
  }
}

String mmss(int ms) {
  final d = Duration(milliseconds: ms);
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

int randomLoopCount([int? min, int? max]) {
  final lo = min ?? AppStore.I.rangeMin;
  final hi = max ?? AppStore.I.rangeMax;
  final safeMin = lo.clamp(1, 999);
  final safeMax = hi.clamp(safeMin, 999);
  return safeMin + Random().nextInt(safeMax - safeMin + 1);
}

/// The fallback wrapper around Cobalt, hosted on Vercel free plan.
/// Fill in your deployed domain; used by the extraction-failure sheet.
const fallbackWebsiteUrl = 'https://YOUR-VERCEL-DOMAIN.vercel.app/reel?url=';
/// building it needs external storage grants we only get with a real pick
/// or MediaStore write; the flag plus string is still persisted now.
const defaultSaveFolderName = 'ReelTune Audios';
String firstRunDefaultPathHint = 'Downloads/$defaultSaveFolderName';
