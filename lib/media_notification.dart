// Native media session: the notification-shade player, the lock-screen player
// and Bluetooth/headset buttons.
//
// Why not audio_service / just_audio_background: on ColorOS their service
// sometimes never reached startForeground, so playback worked but no
// notification ever appeared. This bridge talks to a small Kotlin service that
// owns one MediaSessionCompat and one MediaStyle notification, so every state
// change the app makes is pushed there directly.
//
// Dart owns playback; Kotlin owns only the session UI and forwards button
// presses back through [handleCommand].
import 'package:flutter/services.dart';

class PlaybackNotification {
  static const MethodChannel _channel =
      MethodChannel('com.buildwithanshul.reeltunes/playback');

  /// True once the native service answered. Kept for Settings diagnostics.
  static bool available = false;

  /// Button callbacks. RtPlayer assigns these during boot.
  static Future<void> Function()? onPlay;
  static Future<void> Function()? onPause;
  static Future<void> Function()? onToggle;
  static Future<void> Function()? onNext;
  static Future<void> Function()? onPrevious;
  static Future<void> Function()? onStop;
  static Future<void> Function(int positionMs)? onSeek;

  static bool _hooked = false;

  static Future<bool> init() async {
    if (!_hooked) {
      _hooked = true;
      _channel.setMethodCallHandler(handleCommand);
    }
    try {
      final ok = await _channel.invokeMethod<bool>('init');
      available = ok ?? false;
    } catch (_) {
      available = false;
    }
    return available;
  }

  /// Entry point for every press that arrives from the system UI.
  static Future<dynamic> handleCommand(MethodCall call) async {
    switch (call.method) {
      case 'play':
        await onPlay?.call();
        break;
      case 'pause':
        await onPause?.call();
        break;
      case 'toggle':
        await (onToggle ?? onPlay)?.call();
        break;
      case 'next':
        await onNext?.call();
        break;
      case 'previous':
        await onPrevious?.call();
        break;
      case 'stop':
        await onStop?.call();
        break;
      case 'seek':
        final ms = (call.arguments as num?)?.toInt();
        if (ms != null) await onSeek?.call(ms);
        break;
    }
    return null;
  }

  /// Pushes the current track/state. Safe to call often: the service replaces
  /// the existing notification instead of stacking a new one.
  static Future<void> update({
    required String id,
    required String title,
    required String artist,
    required String album,
    required int cover,
    required bool playing,
    required int positionMs,
    required int durationMs,
    required bool hasNext,
    required bool hasPrevious,
  }) async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'cover': cover,
        'playing': playing,
        'position': positionMs,
        'duration': durationMs,
        'hasNext': hasNext,
        'hasPrevious': hasPrevious,
      });
    } catch (_) {
      // A dead engine must never break playback.
    }
  }

  /// Takes the notification and the lock-screen controls away.
  static Future<void> clear() async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (_) {}
  }
}
