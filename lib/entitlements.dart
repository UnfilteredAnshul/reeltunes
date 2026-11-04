// Free vs Pro — the single source of truth for every gate in the app.
//
// Nothing here talks to Play yet. `purchased` is flipped by the billing layer
// when it lands, and by a debug-only shortcut so both tiers are testable
// without waiting a week.
//
// Rules (see docs/free-vs-pro.md):
//   • The 7-day trial starts when the audios folder is first linked.
//   • During the trial the app behaves as Pro and shows no ads.
//   • After it: 25 audios, 2 playlists, Smart 3-6, no custom range, ads.
//   • A lapsed Pro never hides or deletes anything already in the library —
//     the cap only applies to what is imported next.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'coins.dart';

class Entitlements extends ChangeNotifier {
  Entitlements._();
  static final Entitlements I = Entitlements._();

  static const int trialDays = 7;
  static const int freeMaxTracks = 25;
  static const int freeMaxPlaylists = 2;
  static const int smartMin = 3;
  static const int smartMax = 6;

  SharedPreferences? _prefs;
  DateTime? _trialStartedAt;
  bool _purchased = false;
  bool _billingTrial = false;
  bool _willRenew = false;
  DateTime? _subscriptionEndsAt;
  String? _productId;
  bool _debugPro = false;
  /// Debug only: force the Free plan even when a purchase, code grant or the
  /// trial would otherwise make the app Pro. Without this, "Force Pro off" and
  /// "end trial" appear to do nothing on a device that redeemed a Pro code.
  bool _debugFree = false;

  /// Pro time granted by a promo/creator code (`lib/promo.dart`). Kept
  /// separate from the store fields on purpose: a code grant must never look
  /// like a Play purchase, and clearing one must not touch the other.
  DateTime? _grantUntil;
  bool _grantLifetime = false;
  String? _grantCode;

  /// Offline allowance past the store's expiry date. Play renews silently, so a
  /// phone that is offline at renewal should not drop to Free mid-commute; a
  /// genuinely cancelled plan still reverts, just a few days later.
  static const Duration storeGrace = Duration(days: 3);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final ms = prefs.getInt('trialStartMs');
    if (ms != null && ms > 0) {
      _trialStartedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    _purchased = prefs.getBool('proPurchased') ?? false;
    _billingTrial = prefs.getBool('proTrial') ?? false;
    _willRenew = prefs.getBool('proWillRenew') ?? false;
    final endMs = prefs.getInt('proEndsMs');
    if (endMs != null && endMs > 0) {
      _subscriptionEndsAt = DateTime.fromMillisecondsSinceEpoch(endMs);
    }
    _productId = prefs.getString('proProductId');
    _debugPro = prefs.getBool('debugPro') ?? false;
    _debugFree = prefs.getBool('debugFree') ?? false;
    _grantLifetime = prefs.getBool('grantLifetime') ?? false;
    final grantMs = prefs.getInt('grantUntilMs');
    if (grantMs != null && grantMs > 0) {
      _grantUntil = DateTime.fromMillisecondsSinceEpoch(grantMs);
    }
    _grantCode = prefs.getString('grantCode');
    // A coin-shop perk (ad-free window, extra slots) must rebuild every gate
    // that reads `showAds` / `maxTracks`.
    if (!_coinsHooked) {
      _coinsHooked = true;
      CoinWallet.I.addListener(_changed);
    }
  }

  bool _coinsHooked = false;

  void _changed() => notifyListeners();

  // ---- trial -------------------------------------------------------------

  DateTime? get trialStartedAt => _trialStartedAt;

  DateTime? get trialEndsAt =>
      _trialStartedAt?.add(const Duration(days: trialDays));

  /// Called every time a folder is linked successfully. The first link is the
  /// moment the app is really in use, so that is when the clock starts.
  Future<void> startTrialIfNeeded() async {
    if (_trialStartedAt != null) return;
    _trialStartedAt = DateTime.now();
    await _prefs?.setInt(
        'trialStartMs', _trialStartedAt!.millisecondsSinceEpoch);
    _changed();
  }

  /// A mirror found in the user's audios folder carries the original trial
  /// start, so reinstalling the app cannot restart the trial.
  Future<void> adoptTrialStart(int? ms) async {
    if (ms == null || ms <= 0) return;
    final existing = _trialStartedAt?.millisecondsSinceEpoch;
    if (existing != null && existing <= ms) return;
    _trialStartedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    await _prefs?.setInt('trialStartMs', ms);
    _changed();
  }

  /// No folder linked yet = nothing to limit, so the app behaves as Pro.
  bool get trialActive {
    final end = trialEndsAt;
    if (end == null) return true;
    return DateTime.now().isBefore(end);
  }

  Duration get trialLeft {
    final end = trialEndsAt;
    if (end == null) return const Duration(days: trialDays);
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whole days remaining, rounded up so "6 hours left" reads as 1 day.
  int get trialDaysLeft {
    final ms = trialLeft.inMilliseconds;
    if (ms <= 0) return 0;
    return (ms / Duration.millisecondsPerDay).ceil();
  }

  // ---- plan --------------------------------------------------------------

  /// True while the store says the Pro entitlement is active. The local flag is
  /// cached so a cold start without network still knows the plan, but the
  /// expiry date is what actually decides — a cancelled subscription reverts
  /// after [storeGrace] even if the app never reaches Play again.
  bool get purchased {
    if (!_purchased) return false;
    final end = _subscriptionEndsAt;
    if (end == null) return true; // lifetime, or the store reported no end
    return DateTime.now().isBefore(end.add(storeGrace));
  }

  bool get debugPro => _debugPro;

  /// Debug only: Free is forced, regardless of purchase / code / trial.
  bool get debugFree => _debugFree;

  /// True when the active subscription is still in its Play introductory
  /// (free-trial) phase.
  bool get billingTrial => purchased && _billingTrial;

  bool get willRenew => _willRenew;

  /// End of the current billing period / trial, as reported by Play.
  DateTime? get subscriptionEndsAt => purchased ? _subscriptionEndsAt : null;

  String? get productId => _productId;

  /// True while a redeemed code is still paying for Pro.
  bool get codeGrantActive {
    if (_grantLifetime) return true;
    final end = _grantUntil;
    if (end == null) return false;
    return DateTime.now().isBefore(end);
  }

  /// End of the code grant, or null for a lifetime code / no grant.
  DateTime? get codeGrantUntil => codeGrantActive ? _grantUntil : null;

  String? get codeGrantCode => codeGrantActive ? _grantCode : null;

  bool get codeGrantLifetime => codeGrantActive && _grantLifetime;

  bool get isPro =>
      !_debugFree && (purchased || _debugPro || codeGrantActive || trialActive);

  /// The end a new code should extend from: an active grant, else now.
  DateTime get codeGrantBase {
    if (codeGrantActive && !_grantLifetime && _grantUntil != null) {
      return _grantUntil!;
    }
    return DateTime.now();
  }

  /// True once the trial is over and nothing is bought.
  bool get capped => !isPro;

  /// Whether the coin shop / Pro upsell is allowed to show. Per the plan the
  /// shop opens on day 8 — not during the trial.
  bool get shopAvailable => capped;

  int get maxTracks =>
      isPro ? 1 << 20 : freeMaxTracks + CoinWallet.I.bonusTracks;
  int get maxPlaylists =>
      isPro ? 1 << 20 : freeMaxPlaylists + CoinWallet.I.bonusPlaylists;
  bool get canUseCustomRange =>
      isPro || CoinWallet.I.customRangeActive;

  /// Ads are on for Free only — and a coin-shop "no ads" purchase pauses them
  /// without changing the plan (the shop and earn button stay available).
  bool get showAds => capped && !CoinWallet.I.adFree;

  bool canAddTracks(int current, [int adding = 1]) =>
      isPro || current + adding <= maxTracks;

  bool canAddPlaylist(int current) =>
      isPro || current < maxPlaylists;

  /// One plain sentence for a blocked import. Null when allowed.
  String? importBlockReason(int current) {
    if (isPro) return null;
    final max = maxTracks;
    if (current >= max) {
      return 'Free tier holds $max audios · Pro for more';
    }
    return null;
  }

  // ---- trial-ending reminders -------------------------------------------

  /// 3 or 1 on the day a nudge is due, otherwise null. Each one is shown once,
  /// which is why the day is stored rather than a plain bool.
  int? get dueTrialReminder {
    if (purchased || _debugPro || codeGrantActive || _trialStartedAt == null) {
      return null;
    }
    final prefs = _prefs;
    if (prefs == null) return null;
    final days = trialDaysLeft;
    if (days <= 0) return null;
    if (days <= 1 && !(prefs.getBool('reminderShown1') ?? false)) return 1;
    if (days <= 3 && !(prefs.getBool('reminderShown3') ?? false)) return 3;
    return null;
  }

  Future<void> markReminderShown(int days) async {
    await _prefs?.setBool(
        days <= 1 ? 'reminderShown1' : 'reminderShown3', true);
    _changed();
  }

  // ---- billing hooks / debug --------------------------------------------

  /// Written by `lib/billing.dart` on every CustomerInfo: launch, purchase,
  /// restore, renewal. The only place store state enters the app.
  Future<void> setStoreEntitlement({
    required bool active,
    bool trial = false,
    bool willRenew = false,
    DateTime? endsAt,
    String? productId,
  }) async {
    final wasPro = purchased;
    _purchased = active;
    _billingTrial = active && trial;
    _willRenew = active && willRenew;
    _subscriptionEndsAt = active ? endsAt : null;
    _productId = active ? productId : null;

    final p = _prefs;
    if (p != null) {
      await p.setBool('proPurchased', _purchased);
      await p.setBool('proTrial', _billingTrial);
      await p.setBool('proWillRenew', _willRenew);
      if (_subscriptionEndsAt == null) {
        await p.remove('proEndsMs');
      } else {
        await p.setInt(
            'proEndsMs', _subscriptionEndsAt!.millisecondsSinceEpoch);
      }
      if (_productId == null) {
        await p.remove('proProductId');
      } else {
        await p.setString('proProductId', _productId!);
      }
    }
    // A fresh subscription retires the trial-end nudges: there is nothing left
    // to nag about, and a later lapse should not replay an old reminder.
    if (!wasPro && purchased) {
      await p?.remove('reminderShown3');
      await p?.remove('reminderShown1');
    }
    _changed();
  }

  /// Writes/extends a code grant. [until] is ignored for a lifetime grant.
  Future<void> setCodeGrant({
    DateTime? until,
    required String code,
    bool lifetime = false,
  }) async {
    if (!lifetime && until == null) return;
    _grantLifetime = lifetime;
    _grantUntil = lifetime ? null : until;
    _grantCode = code;
    final p = _prefs;
    if (p != null) {
      if (_grantUntil == null) {
        await p.remove('grantUntilMs');
      } else {
        await p.setInt('grantUntilMs', _grantUntil!.millisecondsSinceEpoch);
      }
      await p.setBool('grantLifetime', _grantLifetime);
      await p.setString('grantCode', code);
      // A grant retires the trial-end nudges; nagging a user who just got
      // free Pro is how you get uninstalled.
      await p.remove('reminderShown3');
      await p.remove('reminderShown1');
    }
    _changed();
  }

  Future<void> clearCodeGrant() async {
    _grantUntil = null;
    _grantLifetime = false;
    _grantCode = null;
    final p = _prefs;
    if (p != null) {
      await p.remove('grantUntilMs');
      await p.remove('grantLifetime');
      await p.remove('grantCode');
    }
    _changed();
  }

  /// The mirror copy written into `.reeltunes-library.json`, so a reinstall
  /// keeps Pro time the user already earned. Only the grant travels — the
  /// code registry itself is device data and is rebuilt from the server later.
  Map<String, dynamic>? get codeGrantMirror => codeGrantActive
      ? {
          'untilMs': _grantUntil?.millisecondsSinceEpoch,
          'lifetime': _grantLifetime,
          'code': _grantCode,
        }
      : null;

  /// Adopts a mirror grant only when it ends later than the local one, so a
  /// stale file can never shorten paid time.
  Future<void> adoptCodeGrant({
    int? untilMs,
    bool lifetime = false,
    String? code,
  }) async {
    if (lifetime) {
      if (_grantLifetime) return;
      await setCodeGrant(lifetime: true, code: code ?? 'MIRROR');
      return;
    }
    if (untilMs == null || untilMs <= 0) return;
    final incoming = DateTime.fromMillisecondsSinceEpoch(untilMs);
    if (!incoming.isAfter(DateTime.now())) return;
    final current = codeGrantActive && !_grantLifetime ? _grantUntil : null;
    if (current != null && !incoming.isAfter(current)) return;
    await setCodeGrant(until: incoming, code: code ?? 'MIRROR');
  }

  /// Debug-only shortcut (and the pre-store fallback in the paywall).
  Future<void> setPurchased(bool v) async {
    await setStoreEntitlement(active: v);
  }

  /// Debug only: flip tiers by hand so both states are testable on device.
  Future<void> setDebugPro(bool v) async {
    if (!kDebugMode) return;
    _debugPro = v;
    if (v) _debugFree = false;
    await _prefs?.setBool('debugPro', v);
    await _prefs?.setBool('debugFree', _debugFree);
    _changed();
  }

  /// Debug only: force Free even over a purchase, code grant or live trial.
  Future<void> setDebugFree(bool v) async {
    if (!kDebugMode) return;
    _debugFree = v;
    if (v) _debugPro = false;
    await _prefs?.setBool('debugFree', v);
    await _prefs?.setBool('debugPro', _debugPro);
    _changed();
  }

  /// Debug only: jump the trial straight to its last day.
  Future<void> fastForwardTrialToLastDay() async {
    if (!kDebugMode) return;
    _trialStartedAt = DateTime.now().subtract(const Duration(days: 6));
    await _prefs?.setInt(
        'trialStartMs', _trialStartedAt!.millisecondsSinceEpoch);
    await _prefs?.remove('reminderShown3');
    await _prefs?.remove('reminderShown1');
    _changed();
  }

  /// Debug only: pretend the trial ended an hour ago.
  Future<void> endTrialNow() async {
    if (!kDebugMode) return;
    _trialStartedAt = DateTime.now().subtract(const Duration(days: 8));
    await _prefs?.setInt(
        'trialStartMs', _trialStartedAt!.millisecondsSinceEpoch);
    _changed();
  }

  /// Debug only: clear the trial so it can start over.
  Future<void> resetTrial() async {
    if (!kDebugMode) return;
    _trialStartedAt = null;
    await _prefs?.remove('trialStartMs');
    await _prefs?.remove('reminderShown3');
    await _prefs?.remove('reminderShown1');
    _changed();
  }

  /// Shown in Settings and on the paywall.
  String get statusLabel {
    if (_debugFree) return 'Free (debug)';
    if (purchased) {
      if (billingTrial) {
        final end = _subscriptionEndsAt;
        return end == null
            ? 'Free trial via Play'
            : 'Free trial · ends ${_shortDate(end)}';
      }
      final end = _subscriptionEndsAt;
      if (end == null || _willRenew) return 'Pro';
      return 'Pro · ends ${_shortDate(end)}';
    }
    if (_debugPro) return 'Pro (debug)';
    if (codeGrantActive) {
      if (_grantLifetime) return 'Pro · lifetime code';
      final end = _grantUntil!;
      return 'Pro · code until ${_shortDate(end)}';
    }
    if (_trialStartedAt == null) return 'Trial not started';
    if (!trialActive) return 'Free';
    final d = trialDaysLeft;
    return d <= 1 ? 'Trial · last day' : 'Trial · $d days left';
  }

  static String _shortDate(DateTime d) =>
      '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}';
}
