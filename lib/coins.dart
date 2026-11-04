// Coins — the local ledger behind the Free-tier shop.
//
// Everything here is device-local for now. The production plan (see
// docs/free-vs-pro.md §3) verifies rewarded completions with AdMob SSV on a
// server and keeps the balance in Cloudflare KV; until that worker exists the
// local wallet is what the UI reads, with the same API the server will fill.
//
// Perks are data-driven: add an entry to [perks] and it shows up in the shop
// automatically, with its own cost, duration, and effect.
//
// Stacking: buying the same perk again adds its benefit on top and extends the
// window from the previous expiry (additive slots, additive days).
//   • +25 slots ×2  → 50 bonus slots for 60 days  (cap 75)
//   • +50 slots ×2  → 100 bonus slots for 60 days (cap 125)
//   • +1 playlist ×2 → 2 bonus playlists for 60 days (total 4)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One timed perk that coins can buy.
class CoinPerk {
  const CoinPerk({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.cost,
    required this.duration,
    required this.icon,
    this.bonusTracks = 0,
    this.bonusPlaylists = 0,
    this.noAds = false,
    this.customRange = false,
  });

  final String id;
  final String title;            // e.g. 'No ads · 24 h'
  final String subtitle;         // shown when not active
  final int cost;                // in coins
  final Duration duration;       // how long the perk lasts
  final IconData icon;
  final int bonusTracks;         // extra audio slots, 0 if none
  final int bonusPlaylists;      // extra playlist slots, 0 if none
  final bool noAds;              // hides banners + playlist cards while active
  final bool customRange;        // unlocks the Custom loop option while active
}

class CoinWallet extends ChangeNotifier {
  CoinWallet._();
  static final CoinWallet I = CoinWallet._();

  /// Coins per completed rewarded video.
  static const int coinsPerAd = 1;

  SharedPreferences? _prefs;
  int _balance = 0;
  /// perk id -> latest expiry ms since epoch
  final Map<String, int> _perkExpiry = {};
  /// perk id -> number of times purchased (while active)
  final Map<String, int> _perkCount = {};
  Timer? _expiry;

  /// All purchasable perks, in shop order.
  static const List<CoinPerk> perks = const [
    // ---- no ads -----------------------------------------------------------
    CoinPerk(
      id: 'no-ads-12h',
      title: 'No ads · 12 h',
      subtitle: 'Hide every banner and playlist ad for half a day',
      cost: 10,
      duration: Duration(hours: 12),
      icon: Icons.block_outlined,
      noAds: true,
    ),
    CoinPerk(
      id: 'no-ads-24h',
      title: 'No ads · 24 h',
      subtitle: 'Hide every banner and playlist ad for a day',
      cost: 15,
      duration: Duration(hours: 24),
      icon: Icons.block_outlined,
      noAds: true,
    ),
    CoinPerk(
      id: 'no-ads-7d',
      title: 'No ads · 7 days',
      subtitle: 'Hide every banner and playlist ad for a week',
      cost: 20,
      duration: Duration(days: 7),
      icon: Icons.block_outlined,
      noAds: true,
    ),
    CoinPerk(
      id: 'no-ads-30d',
      title: 'No ads · 30 days',
      subtitle: 'Hide every banner and playlist ad for a month',
      cost: 69,
      duration: Duration(days: 30),
      icon: Icons.block_outlined,
      noAds: true,
    ),
    // ---- audio slots ------------------------------------------------------
    CoinPerk(
      id: 'slots-25-30d',
      title: '+25 audio slots · 30 days',
      subtitle: 'Grow the Free 25 up to 50 audios',
      cost: 10,
      duration: Duration(days: 30),
      icon: Icons.library_add_outlined,
      bonusTracks: 25,
    ),
    CoinPerk(
      id: 'slots-50-30d',
      title: '+50 audio slots · 30 days',
      subtitle: 'Grow the Free 25 up to 75 audios',
      cost: 18,
      duration: Duration(days: 30),
      icon: Icons.library_add_outlined,
      bonusTracks: 50,
    ),
    // ---- playlists --------------------------------------------------------
    CoinPerk(
      id: 'playlist-30d',
      title: 'Extra playlist slot · 30 days',
      subtitle: 'Free tier gets 2 playlists — this adds one more',
      cost: 8,
      duration: Duration(days: 30),
      icon: Icons.queue_music,
      bonusPlaylists: 1,
    ),
    // ---- loop range -------------------------------------------------------
    CoinPerk(
      id: 'custom-range-7d',
      title: 'Custom loop range · 7 days',
      subtitle: 'Unlock the Custom loop option for a week',
      cost: 4,
      duration: Duration(days: 7),
      icon: Icons.loop,
      customRange: true,
    ),
    CoinPerk(
      id: 'custom-range-30d',
      title: 'Custom loop range · 30 days',
      subtitle: 'Unlock the Custom loop option for a month',
      cost: 12,
      duration: Duration(days: 30),
      icon: Icons.loop,
      customRange: true,
    ),
  ];

  /// Lookup a perk by id.
  CoinPerk? perk(String id) => perks.where((p) => p.id == id).firstOrNull;

  /// True while [id]'s perk is active.
  bool isPerkActive(String id) {
    final ms = _perkExpiry[id];
    return ms != null &&
        DateTime.fromMillisecondsSinceEpoch(ms).isAfter(DateTime.now());
  }

  /// Expiry of [id]'s perk, or null when inactive.
  DateTime? perkUntil(String id) {
    final ms = _perkExpiry[id];
    return ms != null && ms > 0
        ? DateTime.fromMillisecondsSinceEpoch(ms)
        : null;
  }

  /// Number of times [id] has been bought (counts toward stacked bonus).
  int perkCount(String id) => _perkCount[id] ?? 0;

  // ---- state -------------------------------------------------------------

  int get balance => _balance;

  /// True while any "no ads" perk is running. Checked by `Entitlements.showAds`,
  /// so banners disappear while the shop keeps earning.
  bool get adFree =>
      perks.where((p) => p.noAds).any((p) => isPerkActive(p.id));

  DateTime? get adFreeUntil {
    DateTime? latest;
    for (final p in perks.where((p) => p.noAds)) {
      final u = perkUntil(p.id);
      if (u != null && (latest == null || u.isAfter(latest))) latest = u;
    }
    return latest;
  }

  /// Extra library slots from all active slot perks (additive across purchases).
  int get bonusTracks {
    int total = 0;
    for (final p in perks.where((p) => p.bonusTracks > 0)) {
      if (isPerkActive(p.id)) total += perkCount(p.id) * p.bonusTracks;
    }
    return total;
  }

  bool get extraTracksActive => bonusTracks > 0;

  DateTime? get extraTracksUntil {
    DateTime? latest;
    for (final p
        in perks.where((p) => p.bonusTracks > 0 && isPerkActive(p.id))) {
      final u = perkUntil(p.id);
      if (u != null && (latest == null || u.isAfter(latest))) latest = u;
    }
    return latest;
  }

  /// Extra playlist slots from all active playlist perks (additive).
  int get bonusPlaylists {
    int total = 0;
    for (final p in perks.where((p) => p.bonusPlaylists > 0)) {
      if (isPerkActive(p.id)) total += perkCount(p.id) * p.bonusPlaylists;
    }
    return total;
  }

  bool get customRangeActive =>
      perks.where((p) => p.customRange).any((p) => isPerkActive(p.id));

  bool canAfford(CoinPerk p) => _balance >= p.cost;

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

  /// Buy [p]. Stacks additively: bonus tracks/playlists accumulate, and the
  /// expiry window extends from the previous expiry (additive days).
  Future<bool> buyPerk(CoinPerk p) async {
    if (!await spend(p.cost)) return false;
    final now = DateTime.now();
    final base = isPerkActive(p.id)
        ? DateTime.fromMillisecondsSinceEpoch(_perkExpiry[p.id]!)
        : now;
    // Extend from the previous expiry, never from now — so days stack.
    final expiry = base.add(p.duration);
    _perkExpiry[p.id] = expiry.millisecondsSinceEpoch;
    _perkCount[p.id] = (perkCount(p.id) + 1);
    await _savePerk(p.id);
    _scheduleExpiry();
    notifyListeners();
    return true;
  }

  /// Debug only: give the tester enough coins to exercise every shop item.
  Future<void> debugGrant() => add(100);

  /// Debug only: wipe balance and all active perks.
  Future<void> debugReset() async {
    _balance = 0;
    _perkExpiry.clear();
    _perkCount.clear();
    final p = _prefs;
    if (p != null) {
      await p.remove('coinBalance');
      for (final perk in perks) {
        await p.remove('coinPerk_${perk.id}');
        await p.remove('coinPerkCount_${perk.id}');
      }
    }
    _expiry?.cancel();
    notifyListeners();
  }

  /// Debug only: set the balance to an exact value.
  Future<void> setBalance(int value) async {
    if (value < 0) return;
    _balance = value;
    await _prefs?.setInt('coinBalance', _balance);
    notifyListeners();
  }

  /// Debug only: remove a single perk by id.
  Future<void> removePerk(String id) async {
    _perkExpiry.remove(id);
    _perkCount.remove(id);
    await _prefs?.remove('coinPerk_$id');
    await _prefs?.remove('coinPerkCount_$id');
    _scheduleExpiry();
    notifyListeners();
  }

  /// Loads the wallet. Safe to call once at startup; later calls are no-ops.
  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    _balance = p.getInt('coinBalance') ?? 0;
    for (final perk in perks) {
      final ms = p.getInt('coinPerk_${perk.id}');
      if (ms != null && ms > 0) {
        _perkExpiry[perk.id] = ms;
      }
      final count = p.getInt('coinPerkCount_${perk.id}');
      if (count != null && count > 0) {
        _perkCount[perk.id] = count;
      }
    }
    // Drop perks that expired while the app was closed.
    _perkExpiry.removeWhere((_, ms) {
      final at = DateTime.fromMillisecondsSinceEpoch(ms);
      return !at.isAfter(DateTime.now());
    });
    _perkCount.removeWhere((id, _) => !isPerkActive(id));
    _scheduleExpiry();
    notifyListeners();
  }

  static DateTime? _dateFrom(int? ms) =>
      ms != null && ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  Future<void> _savePerk(String id) async {
    final ms = _perkExpiry[id];
    if (ms == null) return;
    await _prefs?.setInt('coinPerk_$id', ms);
    await _prefs?.setInt('coinPerkCount_$id', _perkCount[id] ?? 1);
  }

  // ---- expiry ------------------------------------------------------------

  /// Wakes the UI exactly when the first perk lapses, so a window does not stay
  /// "active" on a screen that never rebuilds.
  void _scheduleExpiry() {
    _expiry?.cancel();
    final now = DateTime.now();
    DateTime? next;
    for (final ms in _perkExpiry.values) {
      final at = DateTime.fromMillisecondsSinceEpoch(ms);
      if (!at.isAfter(now)) continue;
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next == null) return;
    _expiry = Timer(next.difference(now) + const Duration(seconds: 1), () {
      _scheduleExpiry();
      notifyListeners();
    });
  }
}
