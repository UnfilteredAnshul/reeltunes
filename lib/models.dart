// ReelTune data models + central store.
// Library persists as JSON in the app documents dir; settings in
// SharedPreferences. Migrate to Hive later if needed.

import 'dart:convert';
import 'dart:io';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { system, light, dark }

enum ViewMode { list, grid }

enum RtLoop { smart, customRange, infinite }

enum SortBy { manual, name, dateAdded }

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
  final String path; // absolute path of the saved audio file
  int durationMs; // filled after the first successful load
  List<String> folderIds;
  int addedAtMs; // epoch ms of import; 0 for tracks added before this field

  Track({
    required this.id,
    required this.title,
    required this.source,
    required this.path,
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
        'durationMs': durationMs,
        'addedAtMs': addedAtMs,
        'folderIds': folderIds,
      };

  static Track fromMap(Map<String, dynamic> m) => Track(
        id: m['id'],
        title: m['title'],
        source: m['source'] ?? 'import',
        path: m['path'],
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

  // Advanced looping: user's custom loop-count range (persisted; 3-5 default)
  int rangeMin = 3;
  int rangeMax = 5;

  // per-feature prefs
  bool confirmDelete = true; // ask before deleting a track
  bool playDuringCalls = false; // keep audio playing when a call comes in
  SortBy sortBy = SortBy.manual; // manual = user-drag order (tracks)
  bool sortAsc = true; // ascending when sortBy != manual

  String? selectedFolderId; // null = All audios

  bool get fullPro => true; // full pro for now; restrictions come later

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
    playDuringCalls = _prefs.getBool('playDuringCalls') ?? false;
    sortBy = SortBy.values[_prefs.getInt('sortBy') ?? 0];
    sortAsc = _prefs.getBool('sortAsc') ?? true;

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
    _prefs.setBool('playDuringCalls', playDuringCalls);
    _prefs.setInt('sortBy', sortBy.index);
    _prefs.setBool('sortAsc', sortAsc);
    try {
      await _libFile!.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {/* preview: ignore write errors */}
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
    tracks.add(t);
    _persist();
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
    _persist();
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
  void setPlayDuringCalls(bool v) => _mutateSetting(() => playDuringCalls = v);
  void setSortBy(SortBy s) => _mutateSetting(() => sortBy = s);
  void setSortAsc(bool v) => _mutateSetting(() => sortAsc = v);

  void setRangeMin(int v) =>
      _mutateSetting(() => rangeMin = v.clamp(1, rangeMax));
  void setRangeMax(int v) =>
      _mutateSetting(() => rangeMax = v.clamp(rangeMin, 999));
  String get rangeLabel => '$rangeMin-${rangeMax}x';

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

  void refresh() {
    notifyListeners();
  }

  Iterable<Track> get visibleTracks => selectedFolderId == null
      ? tracks
      : tracks.where((t) => t.folderIds.contains(selectedFolderId));

  /// visibleTracks in display order: store order when sortBy==manual,
  /// otherwise name/date added with the asc/desc preference.
  List<Track> get visibleTracksSorted {
    final sel = selectedFolderId;
    final list = (sel == null
            ? tracks.toList()
            : tracks.where((t) => t.folderIds.contains(sel)).toList())
        .whereType<Track>()
        .toList();
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

  /// Drag-reorder inside the currently visible slice (works with filtering).
  void reorderVisibleTracks(int oldIndex, int newIndex) {
    final sel = selectedFolderId;
    final visible = (sel == null
            ? tracks.toList()
            : tracks.where((t) => t.folderIds.contains(sel)).toList())
        .whereType<Track>()
        .toList();
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    newIndex =
        (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, visible.length);
    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);
    var vi = 0;
    for (var i = 0; i < tracks.length; i++) {
      final keep = sel == null
          ? true
          : tracks[i].folderIds.contains(sel);
      if (keep) tracks[i] = visible[vi++];
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
