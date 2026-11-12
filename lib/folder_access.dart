// The audios folder, as a Storage Access Framework tree.
//
// Android 11+ blocks raw file access to Download (verified on device: EACCES as
// the app UID), so the folder the user's audio lives in is reached through
// documents, not paths. Everything about it lives here:
//
//   * link / unlink the folder (one picker, grant persisted)
//   * scan it for audio + video files the user dropped in with a file manager
//   * save extracted audio into it (optionally a playlist sub-folder)
//   * read/write the portable library mirror that lives inside it

import 'package:flutter/services.dart';

const MethodChannel _channel =
    MethodChannel('com.buildwithanshul.reeltunes/folder');

/// File name of the portable metadata file kept inside the audios folder.
const String libraryMirrorName = '.reeltunes-library.json';

class LinkedFolder {
  final bool linked;
  final String? uri;
  final String? name;
  final bool writable;
  const LinkedFolder({
    required this.linked,
    this.uri,
    this.name,
    this.writable = false,
  });
}

class FolderFile {
  final String uri;
  final String name;
  final String mime;
  final String relative; // first-level sub-folder, '' when at the root
  final int size;
  final int modifiedMs;
  const FolderFile({
    required this.uri,
    required this.name,
    required this.mime,
    required this.relative,
    required this.size,
    required this.modifiedMs,
  });
}

/// Where a saved file landed, after the bridge made its name unique.
class FolderSaveResult {
  final String uri;
  final String name;
  const FolderSaveResult({required this.uri, required this.name});
}

class FolderAccess {
  /// Current link state (the grant lives in Android's prefs, not ours).
  static Future<LinkedFolder> state() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('state');
      if (raw == null || raw['linked'] != true) {
        return const LinkedFolder(linked: false);
      }
      return LinkedFolder(
        linked: true,
        uri: raw['uri']?.toString(),
        name: raw['name']?.toString(),
        writable: raw['writable'] == true,
      );
    } on MissingPluginException {
      return const LinkedFolder(linked: false);
    } on PlatformException {
      return const LinkedFolder(linked: false);
    }
  }

  /// True when the saved folder still resolves (grant alive + root readable).
  /// False means the library entries are fine but their content:// paths are
  /// dead until the user re-links the folder.
  static Future<bool> probe() async {
    try {
      return await _channel.invokeMethod<bool>('probe') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the folder picker. Returns null when the user backs out.
  /// [preferDefault] creates Downloads/ReelTune Audios when needed and parks
  /// the picker INSIDE it, so the user only has to tap "Use this folder".
  static Future<LinkedFolder?> link({bool preferDefault = false}) async {
    try {
      if (preferDefault) await ensureDefault();
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'link', {'preferDefault': preferDefault});
      if (raw == null) return null;
      return await state();
    } on PlatformException {
      return null;
    }
  }

  /// Makes sure `Downloads/ReelTune Audios` exists before the first picker
  /// opens. Returns false when the platform could not create it (the picker
  /// then opens on Download instead). Never throws: setup must not dead-end.
  static Future<bool> ensureDefault() async {
    try {
      return await _channel.invokeMethod<bool>('ensureDefault') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// True when a saved document URI still resolves. Used to verify a save
  /// actually landed before telling the user it failed.
  static Future<bool> exists(String uri) async {
    try {
      return await _channel
              .invokeMethod<bool>('exists', {'uri': uri}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> unlink() async {
    try {
      return await _channel.invokeMethod<bool>('unlink') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Every audio/video file under the linked folder.
  static Future<List<FolderFile>> scan() async {
    try {
      final rows = await _channel.invokeMethod<List<dynamic>>('scan') ??
          const <dynamic>[];
      return [
        for (final row in rows)
          if (row is Map && row['uri'] != null)
            FolderFile(
              uri: row['uri'].toString(),
              name: row['name']?.toString() ?? '',
              mime: row['mime']?.toString() ?? '',
              relative: row['relative']?.toString() ?? '',
              size: (row['size'] as num?)?.toInt() ?? 0,
              modifiedMs: (row['modified'] as num?)?.toInt() ?? 0,
            ),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Copies [sourcePath] into the linked folder. Returns where it landed (the
  /// bridge appends " 2", " 3" instead of overwriting an existing file), or
  /// null when the folder is not linked / not writable.
  static Future<FolderSaveResult?> save({
    required String sourcePath,
    required String fileName,
    String? subdir,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'save',
        {
          'sourcePath': sourcePath,
          'fileName': fileName,
          'subdir': subdir,
        },
      );
      final uri = raw?['uri']?.toString();
      if (uri == null || uri.isEmpty) return null;
      return FolderSaveResult(
        uri: uri,
        name: raw?['name']?.toString() ?? fileName,
      );
    } on PlatformException {
      return null;
    }
  }

  static Future<String?> readText(String name) async {
    try {
      return await _channel.invokeMethod<String>('readText', {'name': name});
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> writeText(String name, String text) async {
    try {
      return await _channel
              .invokeMethod<bool>('writeText', {'name': name, 'text': text}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> delete(String uri) async {
    try {
      return await _channel.invokeMethod<bool>('delete', {'uri': uri}) ?? false;
    } on PlatformException {
      return false;
    }
  }
}
