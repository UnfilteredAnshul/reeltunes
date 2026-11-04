// Coins — the local ledger behind the Free-tier shop.
//
// Everything here is device-local for now. The production plan (see
// docs/free-vs-pro.md §3) verifies rewarded completions with AdMob SSV on a
// server and keeps the balance in Cloudflare KV; until that worker exists the
// local wallet is what the UI reads, with the same API the server will fill.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CoinWallet extends ChangeNotifier {
  CoinWallet._();
  static final CoinWallet I = CoinWallet._();

  /// Coins per completed rewarded video.
  static const int coinsPerAd = 5;

  /// 24 hours without ads.
  static const int adFreeCost = 20;
  static const Duration adFreeFor = Duration(hours: 24);

  /// +25 audio slots for 30 days (stacks with the Free 25).
  static const int extraTracksCost = 25;
  static const int extraTracks = 25;
  static const Duration extraTracksFor = Duration(days: 30);

  SharedPreferences? _prefs;
  int _balance = 0;
  DateTime? _adFreeUntil;
  DateTime? _extraTracksUntil;
  Timer? _expiry;

  /// Loads the wallet. Safe to call once at startup; later calls are no-ops.
  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    _balance = p.getInt('coinBalance') ?? 0;
    _adFreeUntil = _dateFrom(p.getInt('coinAdFreeUntilMs'));
    _extraTracksUntil = _dateFrom(p.getInt('coinExtraTracksUntilMs'));
    _scheduleExpiry();
    notifyListeners();
  }

  static DateTime? _dateFrom(int? ms) =>
      ms != null && ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  // ---- state -------------------------------------------------------------

  int get balance => _balance;

  /// True while a coin-bought "no ads" window is running. This is checked by
  /// `Entitlements.showAds`, so banners disappear while the shop keeps earning.
  bool get adFree => _adFreeUntil?.isAfter(DateTime.now()) ?? false;

  DateTime? get adFreeUntil => adFree ? _adFreeUntil : null;

  bool get extraTracksActive =>
      _extraTracksUntil?.isAfter(DateTime.now()) ?? false;

  DateTime? get extraTracksUntil =>
      extraTracksActive ? _extraTracksUntil : null;

  /// Extra library slots granted by the shop right now (0 when expired).
  int get bonusTracks => extraTracksActive ? extraTracks : 0;

  bool get canAffordAdFree => _balance >= adFreeCost;
  bool get canAffordExtraTracks => _balance >= extraTracksCost;

  // ---- earning / spending ------------------------------------------------

  Future<void> addFromAd() => add(coinsPerAd);

  Future<void> add(int coins) async {
    if (coins <= 0) return;
    _balance += coins;
    await _prefs?.setInt('coinBalance', _balance);
    notifyListeners();
  }

  /// Returns false when the balance is short; nothing is written in that case.
  Future<bool> spend(int coins) async {
    if (coins <= 0 || _balance < coins) return false;
    _balance -= coins;
    await _prefs?.setInt('coinBalance', _balance);
    notifyListeners();
    return true;
  }

  Future<bool> buyAdFree() async {
    if (!await spend(adFreeCost)) return false;
    // Buying again while active extends the window instead of resetting it.
    final base = adFree ? _adFreeUntil! : DateTime.now();
    _adFreeUntil = base.add(adFreeFor);
    await _prefs?.setInt(
        'coinAdFreeUntilMs', _adFreeUntil!.millisecondsSinceEpoch);
    _scheduleExpiry();
    notifyListeners();
    return true;
  }

  Future<bool> buyExtraTracks() async {
    if (!await spend(extraTracksCost)) return false;
    final base = extraTracksActive ? _extraTracksUntil! : DateTime.now();
    _extraTracksUntil = base.add(extraTracksFor);
    await _prefs?.setInt(
        'coinExtraTracksUntilMs', _extraTracksUntil!.millisecondsSinceEpoch);
    _scheduleExpiry();
    notifyListeners();
    return true;
  }

  /// Debug only: give the tester enough coins to exercise every shop item.
  Future<void> debugGrant() => add(100);

  /// Debug only: wipe balance and active perks.
  Future<void> debugReset() async {
    _balance = 0;
    _adFreeUntil = null;
    _extraTracksUntil = null;
    final p = _prefs;
    if (p != null) {
      await p.remove('coinBalance');
      await p.remove('coinAdFreeUntilMs');
      await p.remove('coinExtraTracksUntilMs');
    }
    _expiry?.cancel();
    notifyListeners();
  }

  // ---- expiry ------------------------------------------------------------

  /// Wakes the UI exactly when the first perk lapses, so a 24 h window does not
  /// stay "active" on a screen that never rebuilds.
  void _scheduleExpiry() {
    _expiry?.cancel();
    final now = DateTime.now();
    DateTime? next;
    for (final at in [_adFreeUntil, _extraTracksUntil]) {
      if (at == null || !at.isAfter(now)) continue;
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next == null) return;
    _expiry = Timer(next.difference(now) + const Duration(seconds: 1), () {
      _scheduleExpiry();
      notifyListeners();
    });
  }
}
