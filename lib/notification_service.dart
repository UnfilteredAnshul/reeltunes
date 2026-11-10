// Local subscription reminders.
//
// Three alarms per subscription: 3 days before the period ends, 1 day before,
// and at the exact end / renewal minute. Android's AlarmManager delivers them
// even when the app is killed; the schedule is restored after a reboot by
// BootReceiver. Nothing is emailed or uploaded, and no Firebase is involved.
//
// The dispute here is *not* the notification permission: the media player
// already needs POST_NOTIFICATIONS. Exact alarms need a second Android 12+
// grant, requested from Settings → Notifications → "Exact reminders". Without
// it the alarms still fire, just not to the minute.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'entitlements.dart';

const _channel = MethodChannel('com.buildwithanshul.reeltunes/reminders');
const _kNotifSoundUri = 'notif_sound_uri';
const _kNotifVibrate = 'notif_vibrate';
const _kSubscriptionReminders = 'subscription_reminders';

class NotificationService {
  NotificationService._();
  static final NotificationService I = NotificationService._();

  SharedPreferences? _prefs;
  bool _initialized = false;
  bool _exactAllowed = true;

  String? get soundUri => _prefs?.getString(_kNotifSoundUri);
  bool get vibrate => _prefs?.getBool(_kNotifVibrate) ?? true;

  /// On unless the user turns it off. Reminders are a billing safeguard, so
  /// default-on is the honest default.
  bool get subscriptionRemindersEnabled =>
      _prefs?.getBool(_kSubscriptionReminders) ?? true;

  /// Android 12+: false means reminders are scheduled inexactly and may arrive
  /// a few minutes late. Always true below Android 12.
  bool get exactAlarmsAllowed => _exactAllowed;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
    await refreshExactAlarmStatus();
    await refreshProNotifications();
    debugPrint('notification service: ready '
        '(reminders ${subscriptionRemindersEnabled ? 'on' : 'off'}, '
        'exact ${exactAlarmsAllowed ? 'yes' : 'no'})');
  }

  Future<void> setSoundUri(String? uri) async {
    if (_prefs == null) return;
    if (uri == null) {
      await _prefs?.remove(_kNotifSoundUri);
    } else {
      await _prefs?.setString(_kNotifSoundUri, uri);
    }
  }

  Future<void> setVibrate(bool v) async {
    if (_prefs == null) return;
    await _prefs?.setBool(_kNotifVibrate, v);
    await refreshProNotifications();
  }

  Future<void> setSubscriptionReminders(bool v) async {
    if (_prefs == null) return;
    await _prefs?.setBool(_kSubscriptionReminders, v);
    if (v) {
      await refreshProNotifications();
    } else {
      await cancelProNotifications();
    }
  }

  Future<bool> refreshExactAlarmStatus() async {
    try {
      _exactAllowed = await _channel.invokeMethod<bool>(
            'exactAlarmStatus',
          ) ??
          true;
    } catch (_) {
      // Desktop / tests / a build without the native bridge.
      _exactAllowed = true;
    }
    return _exactAllowed;
  }

  Future<void> openExactAlarmSettings() async {
    try {
      await _channel.invokeMethod<void>('openExactAlarmSettings');
    } catch (e) {
      debugPrint('notification service: exact alarm settings unavailable $e');
    }
  }

  /// Posts an immediate sample, so the user can see the wording without
  /// waiting three days. Debug row only.
  Future<void> sendTestReminder() async {
    try {
      await _channel.invokeMethod<void>('test', {
        'title': 'Pro renews tomorrow',
        'body': 'This is a sample reminder. Google Play would charge your '
            'plan automatically unless you cancel.',
        'vibrate': vibrate,
      });
    } catch (e) {
      debugPrint('notification service: test reminder failed $e');
    }
  }

  /// Rebuilds the alarm schedule from the current store entitlement. Safe to
  /// call on every launch, resume, purchase and renewal: it replaces the whole
  /// set, so it can never stack duplicates.
  Future<void> refreshProNotifications() async {
    if (_prefs == null) return;
    final e = Entitlements.I;
    final end = e.subscriptionEndsAt;
    if (!subscriptionRemindersEnabled || !e.purchased || end == null) {
      await cancelProNotifications();
      return;
    }

    final now = DateTime.now();
    final reminders = <Map<String, Object?>>[];
    final sandbox = e.sandboxPurchase;
    final renew = e.willRenew;
    final plan = e.planLabel;
    final price = e.receiptPrice.isNotEmpty ? e.receiptPrice : 'your plan price';

    for (final days in const [3, 1]) {
      final at = end.subtract(Duration(days: days));
      if (!at.isAfter(now.add(const Duration(minutes: 2)))) continue;
      reminders.add({
        'id': days == 3 ? 7303 : 7301,
        'atMs': at.millisecondsSinceEpoch,
        'title': _title(plan, days, renew: renew, sandbox: sandbox),
        'body': _body(
          plan: plan,
          days: days,
          end: end,
          price: price,
          renew: renew,
          sandbox: sandbox,
        ),
        'vibrate': vibrate,
      });
    }

    if (end.isAfter(now)) {
      reminders.add({
        'id': 7300,
        'atMs': end.millisecondsSinceEpoch,
        'title': renew
            ? (sandbox ? 'Test Pro renews now' : 'Pro renews now')
            : (sandbox ? 'Test Pro ends now' : 'Pro ends now'),
        'body': renew
            ? 'Google Play is charging $price now. $plan continues for '
                'another period; cancel in Google Play to stop the next one.'
            : '$plan ends now. You move to the Free plan and your audios, '
                'playlists and files stay on this device. Nothing is deleted.',
        'vibrate': vibrate,
      });
    }

    try {
      await _channel.invokeMethod<void>('schedule', {'reminders': reminders});
    } catch (e) {
      debugPrint('notification service: schedule failed $e');
    }
  }

  Future<void> cancelProNotifications() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      // No native bridge (desktop/tests): nothing to cancel.
    }
  }

  /// Perks are short and visible in the shop; deliberately no notifications.
  /// Kept as a no-op so `Entitlements` does not need to change.
  Future<void> refreshPerkNotifications() async {}

  Future<void> cancelPerkNotifications() async {}

  String _title(String plan, int days, {required bool renew, required bool sandbox}) {
    final prefix = sandbox ? 'Test Pro' : 'Pro';
    final tail = days == 3 ? 'in 3 days' : 'tomorrow';
    return renew ? '$prefix renews $tail' : '$prefix ends $tail';
  }

  String _body({
    required String plan,
    required int days,
    required DateTime end,
    required String price,
    required bool renew,
    required bool sandbox,
  }) {
    final test = sandbox ? 'Test purchase — no money is charged. ' : '';
    final date = _date(end);
    if (renew) {
      return '${test}Google Play will charge $price automatically on $date. '
          '$plan continues unless you cancel before then.';
    }
    return '$test$plan ends on $date. You will move to the Free plan; your '
        'audios, playlists and files stay on this device. Nothing is deleted.';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _date(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year} at '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
