// Notification service stub — preferences stored, real notifications to be
// wired once flutter_local_notifications builds cleanly with AGP 9.
// The now-playing notification is already handled by just_audio_background
// (audio_service) in the manifest.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'coins.dart';
import 'entitlements.dart';

const _kNotifSoundUri = 'notif_sound_uri';
const _kNotifVibrate = 'notif_vibrate';

class NotificationService {
  NotificationService._();
  static final NotificationService I = NotificationService._();

  SharedPreferences? _prefs;
  bool _initialized = false;

  String? get soundUri => _prefs?.getString(_kNotifSoundUri);
  bool get vibrate => _prefs?.getBool(_kNotifVibrate) ?? true;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
    debugPrint('notification service: initialised (stub)');
  }

  Future<void> setSoundUri(String? uri) async {
    if (_prefs == null) return;
    if (uri == null) await _prefs?.remove(_kNotifSoundUri);
    else await _prefs?.setString(_kNotifSoundUri, uri);
  }

  Future<void> setVibrate(bool v) async {
    if (_prefs == null) return;
    await _prefs?.setBool(_kNotifVibrate, v);
  }

  Future<void> refreshPerkNotifications() async {
    // Stub — real notifications wired later.
    debugPrint('notification service: refreshPerkNotifications (stub)');
  }

  Future<void> cancelPerkNotifications() async {
    // Stub.
  }

  Future<void> refreshProNotifications() async {
    // Stub — real notifications wired later.
    debugPrint('notification service: refreshProNotifications (stub)');
  }

  Future<void> cancelProNotifications() async {
    // Stub.
  }
}
