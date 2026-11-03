// Bridge to the on-device extractor (bundled CPython 3.12 + yt-dlp).
//
// The engine lives entirely inside the APK: the interpreter, the standard
// library and the extractor are shipped as native libraries and unpacked on
// first run. Nothing is fetched over the network at runtime, so the version
// that ships with a Play release is the version that runs.

import 'dart:async';

import 'package:flutter/services.dart';

class EngineInfo {
  const EngineInfo({
    this.title,
    this.durationSeconds,
    this.webpageUrl,
    this.ext,
  });

  final String? title;
  final double? durationSeconds;
  final String? webpageUrl;
  final String? ext;
}

class EngineResult {
  const EngineResult({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
  });

  final String path;
  final String fileName;
  final int sizeBytes;
}

class Engine {
  static const MethodChannel _channel =
      MethodChannel('com.buildwithanshul.reeltunes/engine');
  static const EventChannel _events =
      EventChannel('com.buildwithanshul.reeltunes/engine/progress');

  static bool _ready = false;
  static bool _listening = false;
  static final Map<String, void Function(double)> _progress = {};

  static Future<void> init() async {
    if (_ready) return;
    _listen();
    await _channel.invokeMethod<void>('init');
    _ready = true;
  }

  static Future<EngineInfo> getVideoInfo(String url) async {
    await init();
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'getVideoInfo',
      {'url': url},
    );
    if (raw == null) throw const EngineException('No metadata returned');
    return EngineInfo(
      title: raw['title'] as String?,
      durationSeconds: (raw['durationSeconds'] as num?)?.toDouble(),
      webpageUrl: raw['webpageUrl'] as String?,
      ext: raw['ext'] as String?,
    );
  }

  static Future<EngineResult> downloadAudio({
    required String url,
    required String outputDir,
    required String baseName,
    required String taskId,
    void Function(double percent)? onProgress,
  }) async {
    await init();
    if (onProgress != null) _progress[taskId] = onProgress;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'downloadAudio',
        {
          'url': url,
          'outputDir': outputDir,
          'baseName': baseName,
          'taskId': taskId,
        },
      );
      if (raw == null || raw['path'] is! String) {
        throw const EngineException('Extraction produced no file');
      }
      return EngineResult(
        path: raw['path'] as String,
        fileName: (raw['fileName'] as String?) ?? '',
        sizeBytes: (raw['sizeBytes'] as num?)?.toInt() ?? 0,
      );
    } finally {
      _progress.remove(taskId);
    }
  }

  static Future<void> cancel(String taskId) async {
    _progress.remove(taskId);
    try {
      await _channel.invokeMethod<void>('cancel', {'taskId': taskId});
    } catch (_) {
      // The task may already have finished.
    }
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final id = event['taskId']?.toString();
        final percent = (event['progress'] as num?)?.toDouble();
        if (id == null || percent == null) return;
        _progress[id]?.call(percent);
      },
      onError: (_) {},
    );
  }
}

class EngineException implements Exception {
  const EngineException(this.message);

  final String message;

  @override
  String toString() => message;
}
