// Audio extraction: yt-dlp bundled on-device (CPython + yt-dlp zipapp).
//
// Everything needed to extract runs inside the APK: no WebView, no server,
// no runtime download of executable code. The engine only changes when the
// app is updated through Google Play.
//
// Retries and verification live here, not in the engine: a site hiccup often
// returns a non-zero exit *after* writing a complete file, which used to show
// "can't download" for an audio that was already in the library. Every attempt
// checks for the produced file before reporting failure, and up to four
// attempts run with a short backoff.

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'folder_access.dart';
import 'library_sync.dart';
import 'models.dart';

class Extractor {
  static bool _ready = false;

  /// Initial attempt plus three retries. Instagram/TikTok flakiness usually
  /// clears on the second or third try; more than this just wastes time.
  static const int maxAttempts = 4;

  static Future<void> init() async {
    if (_ready) return;
    await Engine.init();
    _ready = true;
  }

  /// Extracts the audio of [url] and moves it into the linked audios folder.
  /// Returns the saved Track, or throws for the UI layer to surface.
  static Future<Track> extractAndAdd(AppStore store, String url,
      {String? title, List<String> folderIds = const [],
      void Function(String)? onStatus}) async {
    await init();
    onStatus?.call('Fetching reel…');

    // Info itself can fail on a transient network error, so it retries too.
    final info = await _retry(
      () => Engine.getVideoInfo(url),
      onStatus: onStatus,
      label: 'Fetching reel',
    );

    var base = (title ?? info.title ?? '')
        .replaceAll(RegExp(r'[/\\:*?\"<>|]'), '_')
        .trim();
    if (base.isEmpty) {
      // default naming methodology: platform + time of import
      final hosts = Uri.tryParse(url)?.host ?? '';
      final plat = hosts.contains('tiktok')
          ? 'TikTok'
          : hosts.contains('instag')
              ? 'Instagram'
              : hosts.contains('youtu')
                  ? 'YouTube'
                  : 'Reel';
      final now = DateTime.now();
      base = '$plat · ${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
    }
    base = base.replaceAll(RegExp(r'[/\\:*?\"<>|]'), '_').trim();
    // Two reels called "Video from Instagram" must not look identical in the
    // library or in a playlist.
    final name = store.uniqueTitle(base);

    // yt-dlp can only write to a real directory, and Android denies that in
    // Download, so it writes into the app cache; the bytes are then copied
    // into the user's folder through SAF.
    final scratch = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}reeltune_out');
    if (!scratch.existsSync()) scratch.createSync(recursive: true);

    onStatus?.call('Extracting audio…');
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final taskId = 'reeltune-$startedAt';
    final result = await _retry(
      () async {
        try {
          final r = await Engine.downloadAudio(
            url: url,
            outputDir: scratch.path,
            baseName: name,
            taskId: taskId,
            onProgress: (percent) =>
                onStatus?.call('Extracting audio… ${percent.round()}%'),
          );
          // The engine says it wrote a file: verify it before trusting it.
          final f = File(r.path);
          if (!f.existsSync() || f.lengthSync() == 0) {
            throw Exception('extractor finished but the file is missing');
          }
          return r;
        } catch (e) {
          // A non-zero exit does not always mean nothing was written. Look for
          // a complete file produced during this attempt before giving up.
          final produced = _producedFile(scratch, name, startedAt);
          if (produced != null) {
            return EngineResult(
              path: produced.path,
              fileName: produced.uri.pathSegments.last,
              sizeBytes: produced.lengthSync(),
            );
          }
          rethrow;
        }
      },
      onStatus: onStatus,
      label: 'Extracting audio',
    );

    final built = File(result.path);
    final fileName = built.uri.pathSegments.last;

    if (!store.audiosLinked) {
      throw Exception(
          'No audios folder linked yet. Choose one in Settings first.');
    }
    onStatus?.call('Saving…');
    // The SAF grant can be revoked by Android 16+, permission resets, or OEM
    // clean-up even when the folder looks linked. Probe before writing so we
    // can tell the user to re-link instead of failing silently.
    final grantOk = await LibrarySync.ensureFolderAccess();
    if (!grantOk) {
      throw Exception(
          'Folder access lost. Link your audios folder again to save downloads.');
    }
    final saved = await FolderAccess.save(
      sourcePath: built.path,
      fileName: fileName,
      subdir: _subdirFor(store, folderIds.firstOrNull),
    );
    // A null save means the copy genuinely failed. When the bridge returns a
    // URI, the bytes were written: some document providers cannot answer a
    // follow-up query, and failing there was one source of "can't download"
    // shown over an audio that was already in the library.
    if (saved == null) {
      throw Exception(
          'Folder access lost. Link your audios folder again to save downloads.');
    }
    if (!await FolderAccess.exists(saved.uri)) {
      debugPrint('save verify: provider did not answer for ${saved.uri}');
    }
    // The folder now owns the file; the cache copy is just garbage.
    try {
      built.deleteSync();
    } catch (_) {}

    final hosts = Uri.tryParse(url)?.host ?? '';
    String source = 'web';
    if (hosts.contains('tiktok')) source = 'TikTok';
    if (hosts.contains('instag')) source = 'Instagram';
    if (hosts.contains('youtu')) source = 'YouTube';

    final t = Track(
      id: 't${DateTime.now().microsecondsSinceEpoch}',
      title: name,
      source: source,
      path: saved.uri,
      fileName: saved.name,
      sourceUrl: url,
      durationMs: ((info.durationSeconds ?? 0) * 1000).round(),
      addedAtMs: DateTime.now().millisecondsSinceEpoch,
      folderIds: List.of(folderIds),
    );
    store.addTrack(t);
    return t;
  }

  /// Runs [run] up to [maxAttempts] times with a short backoff. The last error
  /// is rethrown untouched, so the caller can log the real reason.
  static Future<T> _retry<T>(
    Future<T> Function() run, {
    required String label,
    void Function(String)? onStatus,
  }) async {
    Object? last;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await run();
      } catch (e) {
        last = e;
        if (attempt >= maxAttempts) break;
        onStatus?.call('$label failed. Retrying (${attempt + 1}/$maxAttempts)…');
        await Future<void>.delayed(Duration(milliseconds: 900 * attempt));
      }
    }
    throw last!;
  }

  /// Newest non-empty file in [dir] whose name starts with [base], created at
  /// or after [sinceMs]. Used to salvage an attempt that exited non-zero after
  /// writing a complete audio file.
  static File? _producedFile(Directory dir, String base, int sinceMs) {
    try {
      final prefix = base.length > 40 ? base.substring(0, 40) : base;
      File? best;
      for (final entry in dir.listSync()) {
        if (entry is! File) continue;
        final fileName = entry.uri.pathSegments.last.toLowerCase();
        if (!fileName.startsWith(prefix.toLowerCase())) continue;
        if (entry.lengthSync() <= 0) continue;
        if (entry.statSync().modified.millisecondsSinceEpoch < sinceMs) {
          continue;
        }
        if (best == null || entry.lengthSync() > best.lengthSync()) {
          best = entry;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  /// Playlist name when the reel was saved into one (a sub-folder keeps the
  /// folder tidy for file-manager users), otherwise the folder root.
  static String? _subdirFor(AppStore store, String? folderId) {
    if (folderId == null) return null;
    final f = store.folderById(folderId);
    if (f == null) return null;
    final safe = f.name.replaceAll(RegExp(r'[/\\:*?\"<>|]'), '_').trim();
    return safe.isEmpty ? null : safe;
  }
}
