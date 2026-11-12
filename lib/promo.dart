// Codes, running on the phone.
//
// There is no backend yet, so this file is the whole promo system: one
// registry, one redemption log, and the only place a code turns into Pro time.
// It is deliberately shaped like the Cloudflare Worker in docs/promo-codes.md
// (§3 data model, §4 flow) so that later only the transport changes:
//
//   today  : redeem() checks the local registry, applies the grant locally
//   later  : redeem() posts to /redeem, server returns a signed grant, and the
//            local registry becomes an admin-only offline cache
//
// Rules that must not drift:
//   • A code grants *time*, never a price. Play owns prices.
//   • One redemption per code per device.
//   • A revoked/expired/exhausted code fails before anything is granted.
//   • Redeeming never deletes or hides library content.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'entitlements.dart';
import 'library_sync.dart';
import 'promo_api.dart';

class PromoResult {
  final bool ok;
  final String message;
  const PromoResult._(this.ok, this.message);
  factory PromoResult.ok(String message) => PromoResult._(true, message);
  factory PromoResult.fail(String message) => PromoResult._(false, message);
}

/// One row of the registry. Mirrors the `codes` table in docs/promo-codes.md.
class PromoCode {
  PromoCode({
    required this.code,
    required this.type,
    this.days = 0,
    this.maxUses = 0,
    this.uses = 0,
    this.expiresAtMs,
    this.campaign = '',
    this.notes = '',
    this.revoked = false,
    required this.createdAtMs,
    this.builtIn = false,
  });

  final String code;

  /// pro_grant | pro_long | master | reset
  final String type;
  final int days;

  /// 0 = unlimited.
  final int maxUses;
  int uses;
  final int? expiresAtMs;
  final String campaign;
  final String notes;
  bool revoked;
  final int createdAtMs;
  final bool builtIn;

  DateTime? get expiresAt => expiresAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAtMs!);

  bool get expired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
  bool get exhausted => maxUses > 0 && uses >= maxUses;
  bool get usable => !revoked && !expired && !exhausted;

  String get typeLabel => switch (type) {
    'master' => 'Lifetime Pro',
    'reset' => 'Reset to Free',
    'pro_long' => 'Long Pro grant',
    _ => 'Pro grant',
  };

  String get grantLabel {
    if (type == 'master') return 'Pro forever';
    if (type == 'reset') return 'Back to Free';
    if (days == 1) return '1 day Pro';
    return '$days days Pro';
  }

  String get usesLabel => maxUses == 0 ? '$uses used' : '$uses / $maxUses';

  Map<String, dynamic> toMap() => {
    'code': code,
    'type': type,
    'days': days,
    'maxUses': maxUses,
    'uses': uses,
    'expiresAtMs': expiresAtMs,
    'campaign': campaign,
    'notes': notes,
    'revoked': revoked,
    'createdAtMs': createdAtMs,
  };

  static PromoCode? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final code = raw['code']?.toString() ?? '';
    if (code.isEmpty) return null;
    return PromoCode(
      code: code,
      type: raw['type']?.toString() ?? 'pro_grant',
      days: (raw['days'] as num?)?.toInt() ?? 0,
      maxUses: (raw['maxUses'] as num?)?.toInt() ?? 0,
      uses: (raw['uses'] as num?)?.toInt() ?? 0,
      expiresAtMs: (raw['expiresAtMs'] as num?)?.toInt(),
      campaign: raw['campaign']?.toString() ?? '',
      notes: raw['notes']?.toString() ?? '',
      revoked: raw['revoked'] == true,
      createdAtMs: (raw['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class PromoEngine extends ChangeNotifier {
  PromoEngine._();
  static final PromoEngine I = PromoEngine._();

  /// Master code: Pro forever on this build. It stays out of release APKs —
  /// both checks below are `kDebugMode`, which the compiler strips, and the
  /// release path will validate the same code server-side against an SSAID
  /// allowlist (docs/promo-codes.md §5).
  static const String masterCode = 'ANSHUL2012';

  /// Test-only escape hatch back to the Free tier.
  static const String resetCode = 'FREEVERSION';

  static const int _logLimit = 500;
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  SharedPreferences? _prefs;
  final List<PromoCode> _codes = [];
  final List<Map<String, dynamic>> _log = [];
  String _deviceId = '';
  String _installId = '';
  bool _adminUnlocked = false;
  bool _ready = false;

  // Server-backed dashboard state. _codes/_log stay the local/offline
  // registry; when a token is connected the screen reads these instead.
  String _serverToken = '';
  bool _serverOnline = false;
  bool _serverLoaded = false;
  final List<PromoCode> _serverCodes = [];
  final List<Map<String, dynamic>> _serverRedemptions = [];
  Map<String, dynamic>? _serverStats;

  bool get ready => _ready;
  bool get adminUnlocked => _adminUnlocked;
  String get deviceId => _deviceId;
  String get installId => _installId;

  bool get serverConnected => _serverToken.isNotEmpty;
  bool get serverOnline => _serverOnline;
  bool get serverLoaded => _serverLoaded;
  String get serverHost => Uri.parse(PromoApi.baseUrl).host;
  Map<String, dynamic>? get serverStats => _serverStats;

  /// Short, non-identifying device tag for the log. The real server uses SSAID;
  /// this is only here so two test phones are distinguishable.
  String get deviceShort =>
      _deviceId.length >= 6 ? _deviceId.substring(0, 6) : _deviceId;

  /// Built-ins are not rows: they cannot be edited, revoked or counted.
  List<PromoCode> get builtIns => [
    PromoCode(
      code: masterCode,
      type: 'master',
      createdAtMs: 0,
      builtIn: true,
      notes: kDebugMode
          ? 'Unlocks lifetime Pro on this device.'
          : 'Unavailable in release builds.',
    ),
    PromoCode(
      code: resetCode,
      type: 'reset',
      createdAtMs: 0,
      builtIn: true,
      notes: 'Drops this device back to Free for testing.',
    ),
  ];

  List<PromoCode> get codes => _serverLoaded
      ? List.unmodifiable(_serverCodes)
      : List.unmodifiable(_codes);

  List<Map<String, dynamic>> get redemptions => _serverLoaded
      ? List.unmodifiable(_serverRedemptions)
      : List.unmodifiable(_log);

  int get codeCount => codes.length;
  int get liveCodeCount => codes.where((c) => c.usable).length;
  int get redemptionCount => redemptions.length;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    _deviceId = prefs.getString('promoDeviceId') ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = _newDeviceId();
      await prefs.setString('promoDeviceId', _deviceId);
    }
    _installId = prefs.getString('promoInstallId') ?? '';
    if (_installId.isEmpty) {
      _installId = _newDeviceId();
      await prefs.setString('promoInstallId', _installId);
    }
    _serverToken = prefs.getString('promoCodesToken') ?? '';
    _adminUnlocked = prefs.getBool('adminUnlocked') ?? false;

    _codes
      ..clear()
      ..addAll(
        _read<PromoCode>(prefs.getString('promoCodes'), PromoCode.fromMap),
      );
    _log
      ..clear()
      ..addAll(
        _read<Map<String, dynamic>>(
          prefs.getString('promoLog'),
          (m) => m is Map ? Map<String, dynamic>.from(m) : null,
        ),
      );

    // A master grant from an earlier install unlocks the dashboard too.
    if (Entitlements.I.codeGrantLifetime) _adminUnlocked = true;

    _ready = true;
    notifyListeners();
  }

  // ---- redeeming ---------------------------------------------------------

  /// The one call the UI makes. Returns a user-facing sentence either way.
  Future<PromoResult> redeem(String raw) async {
    final result = await _redeem(raw);
    // Any change to the grant is written into the audios folder so a reinstall
    // keeps it (see `Entitlements.codeGrantMirror`).
    if (result.ok) await LibrarySync.mirror();
    return result;
  }

  Future<PromoResult> _redeem(String raw) async {
    final code = normalize(raw);
    if (code.isEmpty) return PromoResult.fail('Enter a code');
    if (code.length < 4 || code.length > 24) {
      return PromoResult.fail("That code isn't valid");
    }

    if (code == resetCode && kDebugMode) {
      await Entitlements.I.setPurchased(false);
      await Entitlements.I.setDebugPro(false);
      await Entitlements.I.setDebugFree(false);
      await Entitlements.I.clearCodeGrant();
      // Also retire the trial, otherwise "Free" would still behave as Pro for
      // the rest of the week and the caps/ads could not be tested at all.
      await Entitlements.I.endTrialNow();
      await _logRedemption(code, lifetime: false);
      return PromoResult.ok('Free tier restored');
    }

    if (code == masterCode && kDebugMode) {
      if (Entitlements.I.codeGrantLifetime) {
        return PromoResult.ok('This device is already Pro');
      }
      await Entitlements.I.setCodeGrant(lifetime: true, code: code);
      await unlockAdmin(true);
      await _logRedemption(code, lifetime: true);
      return PromoResult.ok('Pro unlocked on this device');
    }

    // The shared registry is the authority. This is what makes a code created
    // in the dashboard work on every install within seconds.
    try {
      final remote = await PromoApi.I.redeem(
        code: code,
        deviceId: _deviceId,
        installId: _installId,
      );
      _serverOnline = true;
      if (!remote.ok) {
        return PromoResult.fail(
          remote.message.isEmpty ? "That code isn't valid" : remote.message,
        );
      }
      return await _applyRemote(remote);
    } on PromoApiException catch (e) {
      _serverOnline = false;
      notifyListeners();
      // Offline: codes created on this device still work. Server codes are
      // never cached as code strings, so a revoked code cannot be replayed.
      final local = await _redeemLocal(code);
      if (local != null) return local;
      return PromoResult.fail(e.message);
    }
  }

  Future<PromoResult> _applyRemote(PromoApiResult remote) async {
    final code = remote.code.isEmpty ? normalize(remote.data['code'] ?? '') : remote.code;
    if (remote.lifetime) {
      await Entitlements.I.setCodeGrant(lifetime: true, code: code);
      if (remote.type == 'master') await unlockAdmin(true);
    } else {
      if (remote.days <= 0) return PromoResult.fail("That code isn't valid");
      final until = Entitlements.I.codeGrantBase.add(Duration(days: remote.days));
      await Entitlements.I.setCodeGrant(until: until, code: code);
    }
    await _logRedemption(
      code,
      lifetime: remote.lifetime,
      until: Entitlements.I.codeGrantUntil,
    );
    if (remote.lifetime) return PromoResult.ok('Pro unlocked on this device');
    final end = Entitlements.I.codeGrantUntil;
    return PromoResult.ok(end == null ? 'Pro unlocked' : 'Pro until ${_fmt(end)}');
  }

  /// Local registry only. Returns null when this code is not in the local
  /// registry, so the caller can surface the network error instead.
  Future<PromoResult?> _redeemLocal(String code) async {
    final row = _find(code);
    if (row == null) return null;
    if (row.revoked) return PromoResult.fail('That code was switched off');
    if (row.expired) return PromoResult.fail('That code has expired');
    if (row.exhausted) return PromoResult.fail('That code is fully used');

    final already = _log.any(
      (r) => r['code'] == code && r['device'] == _deviceId,
    );
    if (already) return PromoResult.fail('Already used on this device');

    if (row.type == 'master') {
      if (Entitlements.I.codeGrantLifetime) {
        return PromoResult.ok('This device is already Pro');
      }
      await Entitlements.I.setCodeGrant(lifetime: true, code: code);
      await unlockAdmin(true);
    } else {
      if (row.days <= 0) return PromoResult.fail("That code isn't valid");
      // Extend an active grant, otherwise start from now. Never shorten.
      final until = Entitlements.I.codeGrantBase.add(Duration(days: row.days));
      await Entitlements.I.setCodeGrant(until: until, code: code);
    }

    row.uses += 1;
    await _logRedemption(
      code,
      lifetime: row.type == 'master',
      until: Entitlements.I.codeGrantUntil,
    );
    await _persist();
    return PromoResult.ok(_successMessage(row));
  }

  String _successMessage(PromoCode row) {
    if (row.type == 'master') return 'Pro unlocked on this device';
    final end = Entitlements.I.codeGrantUntil;
    if (end == null) return 'Pro unlocked';
    return 'Pro until ${_fmt(end)}';
  }

  // ---- backend dashboard -------------------------------------------------

  Future<PromoResult> connectServer(String token) async {
    final clean = token.trim();
    if (clean.isEmpty) return PromoResult.fail('Paste the admin token');
    final bool ok;
    try {
      ok = await PromoApi.I.checkToken(clean);
    } on PromoApiException catch (e) {
      return PromoResult.fail(e.message);
    }
    if (!ok) return PromoResult.fail('Token rejected');
    _serverToken = clean;
    _serverOnline = true;
    await _prefs?.setString('promoCodesToken', clean);
    final refreshed = await refreshServer();
    if (!refreshed.ok) return refreshed;
    notifyListeners();
    return PromoResult.ok('Connected to $serverHost');
  }

  Future<void> disconnectServer() async {
    _serverToken = '';
    _serverOnline = false;
    _serverLoaded = false;
    _serverCodes.clear();
    _serverRedemptions.clear();
    _serverStats = null;
    await _prefs?.remove('promoCodesToken');
    notifyListeners();
  }

  /// Pulls the shared registry, recent redemptions and counters.
  Future<PromoResult> refreshServer() async {
    if (!serverConnected) return PromoResult.fail('Not connected');
    try {
      final codes = await PromoApi.I.fetchDashboard(_serverToken);
      if (!codes.ok) return PromoResult.fail(codes.message);
      final redemptions = await PromoApi.I.fetchRedemptions(_serverToken);
      final stats = await PromoApi.I.fetchStats(_serverToken);

      _serverCodes
        ..clear()
        ..addAll([
          for (final raw in (codes.data['codes'] as List? ?? const []))
            if (PromoCode.fromMap(raw) case final PromoCode row) row,
        ]);
      _serverRedemptions
        ..clear()
        ..addAll([
          for (final raw in (redemptions.data['redemptions'] as List? ?? const []))
            if (raw is Map)
              {
                'code': raw['code']?.toString() ?? '',
                'device':
                    raw['deviceId']?.toString() ??
                    raw['deviceShort']?.toString() ??
                    '',
                'atMs': (raw['redeemedAtMs'] as num?)?.toInt() ?? 0,
                'lifetime': raw['lifetime'] == true,
                'untilMs': (raw['untilMs'] as num?)?.toInt(),
              },
        ]);
      final rawStats = stats.data['stats'];
      _serverStats = rawStats is Map
          ? Map<String, dynamic>.from(rawStats)
          : null;
      _serverOnline = true;
      _serverLoaded = true;
      notifyListeners();
      return PromoResult.ok('Dashboard updated');
    } on PromoApiException catch (e) {
      _serverOnline = false;
      notifyListeners();
      return PromoResult.fail(e.message);
    }
  }

  // ---- admin (the in-app dashboard) --------------------------------------

  /// Applies the owner's "Remove effects" switch to this install.
  ///
  /// Only a code grant can be removed; a Play purchase and a live trial are
  /// untouched. Called on launch/resume, never polled: offline keeps the grant
  /// until the next check.
  Future<void> syncGrantEffects() async {
    final code = Entitlements.I.codeGrantCode;
    if (code == null || code.isEmpty) return;
    if (code == masterCode || code == resetCode) return;
    try {
      final removed = await PromoApi.I.grantEffectsRemoved(code);
      if (!removed) return;
      // Re-read after the await: the user may have redeemed a different code
      // in the meantime.
      if (Entitlements.I.codeGrantCode != code) return;
      await Entitlements.I.clearCodeGrant();
      await LibrarySync.mirror();
      notifyListeners();
    } on PromoApiException {
      // Offline: keep Pro. The next launch/resume checks again.
    }
  }

  Future<void> unlockAdmin(bool value) async {
    _adminUnlocked = value;
    await _prefs?.setBool('adminUnlocked', value);
    notifyListeners();
  }

  /// Creates a code. With no [custom] string one is generated (`RT` + 8).
  /// The returned message is the code itself on success.
  Future<PromoResult> createCode({
    required String type,
    int days = 30,
    int maxUses = 0,
    int? validForDays,
    String campaign = '',
    String notes = '',
    String? custom,
  }) async {
    if (serverConnected) {
      try {
        final res = await PromoApi.I.createCode(
          _serverToken,
          type: type,
          days: days,
          maxUses: maxUses,
          validForDays: validForDays ?? 0,
          campaign: campaign,
          notes: notes,
          code: custom,
        );
        if (!res.ok) {
          return PromoResult.fail(
            res.message.isEmpty ? 'Could not create the code' : res.message,
          );
        }
        await refreshServer();
        return PromoResult.ok(res.code);
      } on PromoApiException catch (e) {
        return PromoResult.fail(e.message);
      }
    }

    final String code;
    final trimmed = (custom ?? '').trim();
    if (trimmed.isNotEmpty) {
      code = normalize(trimmed);
      if (code.length < 4 || code.length > 24) {
        return PromoResult.fail('Code needs 4–24 characters');
      }
      if (!RegExp(r'^[A-Z0-9]+$').hasMatch(code)) {
        return PromoResult.fail('Letters and numbers only');
      }
      if (_find(code) != null || code == masterCode || code == resetCode) {
        return PromoResult.fail('That code already exists');
      }
    } else {
      code = _generateUnique();
    }

    if (type != 'master' && days <= 0) {
      return PromoResult.fail('Grant must be at least 1 day');
    }

    _codes.insert(
      0,
      PromoCode(
        code: code,
        type: type,
        days: type == 'master' ? 0 : days,
        maxUses: maxUses < 0 ? 0 : maxUses,
        expiresAtMs: validForDays == null || validForDays <= 0
            ? null
            : DateTime.now()
                  .add(Duration(days: validForDays))
                  .millisecondsSinceEpoch,
        campaign: campaign.trim(),
        notes: notes.trim(),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _persist();
    return PromoResult.ok(code);
  }

  Future<PromoResult> setRevoked(String code, bool revoked) async {
    if (serverConnected) {
      try {
        final res = await PromoApi.I.setRevoked(_serverToken, code, revoked);
        if (!res.ok) return PromoResult.fail(res.message);
        await refreshServer();
        return PromoResult.ok(revoked ? 'Code revoked' : 'Code switched on');
      } on PromoApiException catch (e) {
        return PromoResult.fail(e.message);
      }
    }
    final row = _find(code);
    if (row == null) return PromoResult.fail('Code not found');
    row.revoked = revoked;
    await _persist();
    return PromoResult.ok(revoked ? 'Code revoked' : 'Code switched on');
  }

  Future<PromoResult> deleteCode(String code) async {
    if (serverConnected) {
      try {
        final res = await PromoApi.I.deleteCode(_serverToken, code);
        if (!res.ok) return PromoResult.fail(res.message);
        await refreshServer();
        return PromoResult.ok('Code deleted');
      } on PromoApiException catch (e) {
        return PromoResult.fail(e.message);
      }
    }
    _codes.removeWhere((c) => c.code == code);
    await _persist();
    return PromoResult.ok('Code deleted');
  }

  Future<PromoResult> revokeAll() async {
    if (serverConnected) {
      try {
        final res = await PromoApi.I.revokeAll(_serverToken);
        if (!res.ok) return PromoResult.fail(res.message);
        await refreshServer();
        return PromoResult.ok('All codes revoked');
      } on PromoApiException catch (e) {
        return PromoResult.fail(e.message);
      }
    }
    for (final c in _codes) {
      c.revoked = true;
    }
    await _persist();
    return PromoResult.ok('All codes revoked');
  }

  Future<void> clearLog() async {
    _log.clear();
    await _persist();
  }

  // ---- helpers -----------------------------------------------------------

  /// Uppercase, strip spaces/dashes/underscores. No 0→O mapping: real codes
  /// here can contain digits (`ANSHUL2012`), so mapping would break them.
  static String normalize(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[\s\-_]'), '');

  PromoCode? _find(String normalized) {
    for (final c in _codes) {
      if (c.code == normalized) return c;
    }
    return null;
  }

  String _generateUnique() {
    for (var attempt = 0; attempt < 40; attempt++) {
      final code = 'RT${_randomChars(8)}';
      if (_find(code) == null && code != masterCode && code != resetCode) {
        return code;
      }
    }
    // Practically unreachable; keeps the compiler happy.
    return 'RT${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}';
  }

  String _randomChars(int length) {
    final rnd = Random.secure();
    return String.fromCharCodes(
      List.generate(
        length,
        (_) => _alphabet.codeUnitAt(rnd.nextInt(_alphabet.length)),
      ),
    );
  }

  String _newDeviceId() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  Future<void> _logRedemption(
    String code, {
    required bool lifetime,
    DateTime? until,
  }) async {
    _log.insert(0, {
      'code': code,
      'device': _deviceId,
      'atMs': DateTime.now().millisecondsSinceEpoch,
      'lifetime': lifetime,
      'untilMs': lifetime ? null : until?.millisecondsSinceEpoch,
    });
    if (_log.length > _logLimit) _log.removeRange(_logLimit, _log.length);
    await _persist();
  }

  Future<void> _persist() async {
    final p = _prefs;
    if (p != null) {
      await p.setString(
        'promoCodes',
        jsonEncode([for (final c in _codes) c.toMap()]),
      );
      await p.setString('promoLog', jsonEncode(_log));
    }
    notifyListeners();
  }

  List<T> _read<T>(String? raw, T? Function(Object?) parse) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return [
        for (final item in data)
          if (parse(item) case final T v) v,
      ];
    } catch (e) {
      debugPrint('promo: could not read registry: $e');
      return const [];
    }
  }

  static String _fmt(DateTime d) {
    const months = [
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
    return '${months[d.month - 1]} ${d.day}';
  }
}
