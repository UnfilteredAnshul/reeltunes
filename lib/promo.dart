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

  DateTime? get expiresAt => expiresAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAtMs!);

  bool get expired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
  bool get exhausted => maxUses > 0 && uses >= maxUses;

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

  SharedPreferences? _prefs;
  final List<PromoCode> _codes = [];
  final List<Map<String, dynamic>> _log = [];
  String _deviceId = '';
  String _installId = '';
  bool _ready = false;

  bool get ready => _ready;
  String get deviceId => _deviceId;
  String get installId => _installId;

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
      if (!remote.ok) {
        return PromoResult.fail(
          remote.message.isEmpty ? "That code isn't valid" : remote.message,
        );
      }
      return await _applyRemote(remote);
    } on PromoApiException catch (e) {
      // Offline: codes created on this device still work. Server codes are
      // never cached as code strings, so a revoked code cannot be replayed.
      final local = await _redeemLocal(code);
      if (local != null) return local;
      return PromoResult.fail(e.message);
    }
  }

  Future<PromoResult> _applyRemote(PromoApiResult remote) async {
    final code = remote.code.isEmpty
        ? normalize(remote.data['code'] ?? '')
        : remote.code;
    if (remote.lifetime) {
      await Entitlements.I.setCodeGrant(lifetime: true, code: code);
    } else {
      if (remote.days <= 0) return PromoResult.fail("That code isn't valid");
      final until = Entitlements.I.codeGrantBase.add(
        Duration(days: remote.days),
      );
      await Entitlements.I.setCodeGrant(until: until, code: code);
    }
    await _logRedemption(
      code,
      lifetime: remote.lifetime,
      until: Entitlements.I.codeGrantUntil,
    );
    if (remote.lifetime) return PromoResult.ok('Pro unlocked on this device');
    final end = Entitlements.I.codeGrantUntil;
    return PromoResult.ok(
      end == null ? 'Pro unlocked' : 'Pro until ${_fmt(end)}',
    );
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

  // ---- grant effects -----------------------------------------------------

  /// Applies the owner's "Remove effects" switch to this install, and puts the
  /// Pro back when the switch is flipped to "Restore effects".
  ///
  /// Removing only hides the grant: the code and its end time stay on disk, so
  /// restoring is a flag flip, not a second redemption. A device that already
  /// lost its grant to the old behaviour (the switch used to erase it) is
  /// recovered from the local redemption log.
  ///
  /// Only a code grant can be touched; a Play purchase and a live trial are
  /// never affected. Called on launch/resume, never polled: offline keeps
  /// whatever the device has until the next check.
  Future<void> syncGrantEffects() async {
    final raw = Entitlements.I.grantCodeRaw;
    final fromLog = raw == null ? _newestRedeemableLogEntry() : null;
    final code = raw ?? fromLog?['code']?.toString();
    if (code == null || code.isEmpty) return;
    if (code == masterCode || code == resetCode) return;
    try {
      final removed = await PromoApi.I.grantEffectsRemoved(code);
      if (removed) {
        // Keep the grant on disk; just stop paying for Pro with it.
        await Entitlements.I.setCodeGrantEffectsRemoved(true);
        await LibrarySync.mirror();
        notifyListeners();
        return;
      }
      if (raw != null) {
        if (!Entitlements.I.codeGrantEffectsRemoved) return;
        await Entitlements.I.setCodeGrantEffectsRemoved(false);
        await LibrarySync.mirror();
        notifyListeners();
        return;
      }
      // No grant at all but the log remembers one: the owner restored it.
      final lifetime = fromLog?['lifetime'] == true;
      final untilMs = (fromLog?['untilMs'] as num?)?.toInt();
      if (lifetime) {
        await Entitlements.I.setCodeGrant(lifetime: true, code: code);
      } else if (untilMs != null &&
          untilMs > DateTime.now().millisecondsSinceEpoch) {
        await Entitlements.I.setCodeGrant(
          until: DateTime.fromMillisecondsSinceEpoch(untilMs),
          code: code,
        );
      } else {
        return;
      }
      await LibrarySync.mirror();
      notifyListeners();
    } on PromoApiException {
      // Offline: keep Pro. The next launch/resume checks again.
    }
  }

  /// Newest redemption made by this device whose Pro time has not run out.
  /// Used to rebuild a grant that an earlier build erased on "Remove effects".
  Map<String, dynamic>? _newestRedeemableLogEntry() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _log) {
      if (entry['device']?.toString() != _deviceId) continue;
      if (entry['lifetime'] == true) return entry;
      final untilMs = (entry['untilMs'] as num?)?.toInt();
      if (untilMs != null && untilMs > now) return entry;
    }
    return null;
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
