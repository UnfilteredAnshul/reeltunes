// Audio extraction: yt-dlp bundled on-device (CPython + yt-dlp zipapp).
//
// Everything needed to extract runs inside the APK: no WebView, no server,
// no runtime download of executable code. The engine only changes when the
// app is updated through Google Play.

import 'dart:io';

import 'engine.dart';
import 'folder_access.dart';
import 'models.dart';

class Extractor {
  static bool _ready = false;

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

    final info = await Engine.getVideoInfo(url);
    var name = (title ?? info.title ?? '')
        .replaceAll(RegExp(r'[/\\:*?\"<>|]'), '_')
        .trim();
    if (name.isEmpty) {
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
      name = '$plat · ${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
    }
    name = name.replaceAll(RegExp(r'[/\\:*?\"<>|]'), '_').trim();

    // yt-dlp can only write to a real directory, and Android denies that in
    // Download, so it writes into the app cache; the bytes are then copied
    // into the user's folder through SAF.
    final scratch = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}reeltune_out');
    if (!scratch.existsSync()) scratch.createSync(recursive: true);

    onStatus?.call('Extracting audio…');
    final taskId = 'reeltune-${DateTime.now().millisecondsSinceEpoch}';
    final result = await Engine.downloadAudio(
      url: url,
      outputDir: scratch.path,
      baseName: name,
      taskId: taskId,
      onProgress: (percent) =>
          onStatus?.call('Extracting audio… ${percent.round()}%'),
    );

    final built = File(result.path);
    final fileName = built.uri.pathSegments.last;

    if (!store.audiosLinked) {
      throw Exception(
          'No audios folder linked yet. Choose one in Settings first.');
    }
    onStatus?.call('Saving…');
    final uri = await FolderAccess.save(
      sourcePath: built.path,
      fileName: fileName,
      subdir: _subdirFor(store, folderIds.firstOrNull),
    );
    if (uri == null) {
      throw Exception("Couldn't write into the audios folder.");
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
      path: uri,
      fileName: fileName,
      durationMs: ((info.durationSeconds ?? 0) * 1000).round(),
      addedAtMs: DateTime.now().millisecondsSinceEpoch,
      folderIds: List.of(folderIds),
    );
    store.addTrack(t);
    return t;
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
