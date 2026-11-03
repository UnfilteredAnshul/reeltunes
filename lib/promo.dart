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
  bool _adminUnlocked = false;
  bool _ready = false;

  bool get ready => _ready;
  bool get adminUnlocked => _adminUnlocked;
  String get deviceId => _deviceId;

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

  List<PromoCode> get codes => List.unmodifiable(_codes);

  List<Map<String, dynamic>> get redemptions => List.unmodifiable(_log);

  int get codeCount => _codes.length;
  int get liveCodeCount => _codes.where((c) => c.usable).length;
  int get redemptionCount => _log.length;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    _deviceId = prefs.getString('promoDeviceId') ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = _newDeviceId();
      await prefs.setString('promoDeviceId', _deviceId);
    }
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

    if (code == resetCode) {
      if (!kDebugMode) return PromoResult.fail("That code isn't valid");
      await Entitlements.I.setPurchased(false);
      await Entitlements.I.setDebugPro(false);
      await Entitlements.I.clearCodeGrant();
      // Also retire the trial, otherwise "Free" would still behave as Pro for
      // the rest of the week and the caps/ads could not be tested at all.
      await Entitlements.I.endTrialNow();
      await _logRedemption(code, lifetime: false);
      return PromoResult.ok('Free tier restored');
    }

    if (code == masterCode) {
      if (!kDebugMode) return PromoResult.fail("That code isn't valid");
      if (Entitlements.I.codeGrantLifetime) {
        return PromoResult.ok('This device is already Pro');
      }
      await Entitlements.I.setCodeGrant(lifetime: true, code: code);
      await unlockAdmin(true);
      await _logRedemption(code, lifetime: true);
      return PromoResult.ok('Pro unlocked on this device');
    }

    final row = _find(code);
    if (row == null) return PromoResult.fail("That code isn't valid");
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

  // ---- admin (the in-app dashboard) --------------------------------------

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

  Future<void> setRevoked(String code, bool revoked) async {
    final row = _find(code);
    if (row == null) return;
    row.revoked = revoked;
    await _persist();
  }

  Future<void> deleteCode(String code) async {
    _codes.removeWhere((c) => c.code == code);
    await _persist();
  }

  Future<void> revokeAll() async {
    for (final c in _codes) {
      c.revoked = true;
    }
    await _persist();
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
