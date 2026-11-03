// Keeps the on-phone audios folder and the library in step.
//
// Three jobs:
//   1. Scan the linked folder so files dropped in by a file manager appear in
//      the app, and files removed outside the app disappear from it.
//   2. Mirror playlists + titles into `.reeltunes-library.json` inside that
//      folder, so nothing is lost on uninstall.
//   3. After a reinstall, rebuild the library from that mirror as soon as the
//      folder is linked again.

import 'dart:async';
import 'dart:convert';

import 'entitlements.dart';
import 'folder_access.dart';
import 'models.dart';

class LibrarySync {
  static LinkedFolder folder = const LinkedFolder(linked: false);

  static Timer? _mirrorTimer;

  /// Called once at startup: load the grant, restore if needed, scan.
  static Future<void> init() async {
    folder = await FolderAccess.state();
    _applyToStore();
    AppStore.I.onLibrarySaved = () async => _scheduleMirror();
    await restoreIfEmpty();
    // A mirror carries an older trial start; only start a fresh clock when
    // there was none (first install).
    if (folder.linked) await Entitlements.I.startTrialIfNeeded();
    await sync();
  }

  static Future<void> refreshState() async {
    folder = await FolderAccess.state();
    _applyToStore();
  }

  /// Opens the folder picker. Returns the folder, or null if the user backed
  /// out. On success the mirror is restored (first install after a reinstall)
  /// and the folder is scanned.
  static Future<LinkedFolder?> link({bool preferDefault = false}) async {
    final picked = await FolderAccess.link(preferDefault: preferDefault);
    if (picked == null || !picked.linked) return null;
    folder = picked;
    _applyToStore();
    await restoreIfEmpty();
    await Entitlements.I.startTrialIfNeeded();
    await sync();
    await mirror();
    return picked;
  }

  static Future<void> unlink() async {
    await FolderAccess.unlink();
    folder = const LinkedFolder(linked: false);
    _applyToStore();
  }

  static void _applyToStore() {
    AppStore.I.setAudiosFolder(
      linked: folder.linked,
      uri: folder.uri ?? '',
      name: folder.name ?? '',
      writable: folder.writable,
    );
  }

  // ---- scanning ----------------------------------------------------------

  /// Merges the folder into the library. Returns how many tracks were added.
  static Future<int> sync() async {
    if (!folder.linked) return 0;
    final files = await FolderAccess.scan();
    if (files.isEmpty) {
      AppStore.I.setFolderOverflow(0);
      return 0;
    }

    final store = AppStore.I;
    final entitlements = Entitlements.I;
    final byName = <String, Track>{
      for (final t in store.tracks)
        if (t.fileName.isNotEmpty) t.fileName: t,
    };
    final scanned = <String>{};
    var added = 0;
    var blocked = 0;
    var changed = false;

    for (final f in files) {
      if (f.name.isEmpty) continue;
      // "Removed from ReelTunes" keeps the file but not the entry.
      if (store.hiddenFileNames.contains(f.name)) continue;
      scanned.add(f.name);
      final existing = byName[f.name];
      if (existing != null) {
        if (existing.path != f.uri) {
          existing.path = f.uri;
          changed = true;
        }
        continue;
      }
      // Older entries predate `fileName`; match them by title instead of
      // adding a second copy of the same file.
      final legacy = store.tracks.where((t) =>
          t.fileName.isEmpty && t.title == _titleOf(f.name)).firstOrNull;
      if (legacy != null) {
        legacy.fileName = f.name;
        legacy.path = f.uri;
        byName[f.name] = legacy;
        changed = true;
        continue;
      }
      // Free tier: the folder may hold more files than the library allows.
      // Extra files are counted, never imported, never touched on disk.
      if (store.tracks.length >= entitlements.maxTracks) {
        blocked++;
        continue;
      }
      final playlist = _playlistIdFor(f.relative);
      store.tracks.add(Track(
        id: 't${DateTime.now().microsecondsSinceEpoch}${added.toString().padLeft(3, '0')}',
        title: _titleOf(f.name),
        source: _sourceOf(f.name),
        path: f.uri,
        fileName: f.name,
        addedAtMs: f.modifiedMs > 0
            ? f.modifiedMs
            : DateTime.now().millisecondsSinceEpoch,
        folderIds: playlist == null ? const [] : [playlist],
      ));
      added++;
    }

    // Anything that came from this folder and is no longer on disk was
    // deleted (or renamed) outside the app.
    final prefix = folder.uri ?? '';
    final before = store.tracks.length;
    if (prefix.isNotEmpty) {
      store.tracks.removeWhere((t) =>
          t.path.startsWith(prefix) &&
          t.fileName.isNotEmpty &&
          !scanned.contains(t.fileName));
    }
    final removed = before - store.tracks.length;
    store.setFolderOverflow(blocked);

    if (added > 0 || removed > 0 || changed) {
      await store.save();
      store.refresh();
    }
    return added;
  }

  static String? _playlistIdFor(String relative) {
    if (relative.isEmpty) return null;
    for (final f in AppStore.I.folders) {
      if (f.name.toLowerCase() == relative.toLowerCase()) return f.id;
    }
    return null;
  }

  // ---- mirror ------------------------------------------------------------

  static void _scheduleMirror() {
    if (!folder.linked) return;
    _mirrorTimer?.cancel();
    _mirrorTimer = Timer(const Duration(milliseconds: 700), () => mirror());
  }

  /// Writes a portable snapshot (names + playlists, no device URIs) into the
  /// audios folder itself.
  static Future<void> mirror() async {
    if (!folder.linked) return;
    final store = AppStore.I;
    final prefix = folder.uri ?? '';
    final payload = {
      'v': 1,
      // Survives uninstall with the folder, so a reinstall cannot restart the
      // 7-day trial (docs/free-vs-pro.md §7).
      'trialStartMs': Entitlements.I.trialStartedAt?.millisecondsSinceEpoch,
      // Pro time from a redeemed code travels with the folder as well, so a
      // reinstall restores what the user already earned.
      'grant': Entitlements.I.codeGrantMirror,
      'folders': [for (final f in store.folders) f.toMap()],
      'tracks': [
        for (final t in store.tracks)
          if (prefix.isEmpty || t.path.startsWith(prefix) || t.fileName.isNotEmpty)
            {
              'name': t.fileName.isNotEmpty ? t.fileName : _nameOf(t.path),
              'title': t.title,
              'source': t.source,
              'durationMs': t.durationMs,
              'addedAtMs': t.addedAtMs,
              'folderIds': t.folderIds,
            }
      ],
    };
    await FolderAccess.writeText(libraryMirrorName, jsonEncode(payload));
  }

  /// Restores playlists + titles from the mirror when the library is empty
  /// (fresh install or reinstall) and the folder still has the files.
  static Future<bool> restoreIfEmpty() async {
    final store = AppStore.I;
    if (!folder.linked || store.tracks.isNotEmpty) return false;
    final raw = await FolderAccess.readText(libraryMirrorName);
    if (raw == null || raw.isEmpty) return false;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }

    // The folder remembers when the trial started; adopt it before importing
    // anything so caps are applied with the right plan.
    await Entitlements.I.adoptTrialStart((data['trialStartMs'] as num?)?.toInt());
    final grant = data['grant'];
    if (grant is Map) {
      await Entitlements.I.adoptCodeGrant(
        untilMs: (grant['untilMs'] as num?)?.toInt(),
        lifetime: grant['lifetime'] == true,
        code: grant['code']?.toString(),
      );
    }
    var blocked = 0;

    for (final m in (data['folders'] as List? ?? const [])) {
      if (m is! Map) continue;
      final id = m['id']?.toString() ?? '';
      if (id.isEmpty || store.folders.any((f) => f.id == id)) continue;
      store.folders.add(Folder(
        id: id,
        name: m['name']?.toString() ?? 'Playlist',
        emoji: m['emoji']?.toString() ?? '📁',
      ));
    }

    final files = await FolderAccess.scan();
    final byName = {for (final f in files) f.name: f};
    for (final m in (data['tracks'] as List? ?? const [])) {
      if (m is! Map) continue;
      final name = m['name']?.toString() ?? '';
      final file = byName[name];
      if (file == null) continue;
      if (store.tracks.length >= Entitlements.I.maxTracks) {
        blocked++;
        continue;
      }
      store.tracks.add(Track(
        id: 't${DateTime.now().microsecondsSinceEpoch}${store.tracks.length}',
        title: m['title']?.toString() ?? _titleOf(name),
        source: m['source']?.toString() ?? _sourceOf(name),
        path: file.uri,
        fileName: name,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        addedAtMs: (m['addedAtMs'] as num?)?.toInt() ?? 0,
        folderIds: List<String>.from(m['folderIds'] as List? ?? const []),
      ));
    }
    await store.save();
    store.setFolderOverflow(blocked);
    store.refresh();
    return store.tracks.isNotEmpty;
  }

  // ---- helpers -----------------------------------------------------------

  static String _titleOf(String fileName) => fileName
      .replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '')
      .trim();

  static String _nameOf(String pathOrUri) {
    final clean = Uri.decodeFull(pathOrUri);
    final cut = clean.split('/').last;
    return cut;
  }

  static String _sourceOf(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return const {'mp4', 'mkv', 'webm', 'avi', 'm4v', 'mov', '3gp'}.contains(ext)
        ? 'video'
        : 'file';
  }
}
