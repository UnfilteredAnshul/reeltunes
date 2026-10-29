// Audio extraction: real yt-dlp bundled on-device via ytdlp_flutter.
// Fallback web wrapper only fires when this fails.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';

import 'models.dart';

class Extractor {
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    _ready = true; // set first so concurrent callers don't re-init
    await Ytdlp.init(); // idempotent; downloads engine on Android first run
    // best-effort engine freshness so extractors track platform changes
    try {
      await Ytdlp.update();
    } catch (_) {}
  }

  /// Extract audio of [url] into [store.saveFolder]. Returns the saved Track
  /// or throws for the UI layer to route into the web-wrapper fallback.
  static Future<Track> extractAndAdd(AppStore store, String url,
      {String? title, List<String> folderIds = const [],
      void Function(String)? onStatus}) async {
    await init();
    onStatus?.call('Fetching reel…');

    final info = await Ytdlp.getVideoInfo(url);
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

    // root / category-subfolder; root itself is store-managed
    final dir = store.directoryForFolder(folderIds.firstOrNull) ??
        Directory.systemTemp.path;
    Directory(dir).createSync(recursive: true);

    onStatus?.call('Extracting audio…');
    final taskId = 'reeltune-${DateTime.now().millisecondsSinceEpoch}';
    final path = await Ytdlp.downloadAudio(
      url: url,
      outputDir: dir,
      taskId: taskId,
      onProgress: (p) => onStatus?.call('Extracting audio… $p'),
    );

    final hosts = Uri.tryParse(url)?.host ?? '';
    String source = 'web';
    if (hosts.contains('tiktok')) source = 'TikTok';
    if (hosts.contains('instag')) source = 'Instagram';
    if (hosts.contains('youtu')) source = 'YouTube';

    final t = Track(
      id: 't${DateTime.now().microsecondsSinceEpoch}',
      title: name,
      source: source,
      path: path!,
      durationMs: ((info.durationSeconds ?? 0) * 1000).round(),
      addedAtMs: DateTime.now().millisecondsSinceEpoch,
      folderIds: List.of(folderIds),
    );
    store.addTrack(t);
    return t;
  }
}
