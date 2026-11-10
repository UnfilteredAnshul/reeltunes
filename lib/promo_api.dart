// The network half of the promo system.
//
// `PromoEngine` keeps the rules and the local cache. This file only moves
// bytes: POST /api/redeem for users, /api/admin/* for the dashboard.
//
// Release builds talk to the deployed Worker. Point it somewhere else with
//   flutter build ... --dart-define=PROMO_API=https://host
//
// Nothing here stores a secret. The admin token is typed into the dashboard by
// the owner and lives in SharedPreferences on that phone only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class PromoApiException implements Exception {
  final String message;
  const PromoApiException(this.message);
  @override
  String toString() => message;
}

/// One server answer. `ok == false` is authoritative: the server said no.
class PromoApiResult {
  final bool ok;
  final String message;
  final String code;
  final String type;
  final int days;
  final bool lifetime;
  final int? untilMs;
  final Map<String, dynamic> data;

  const PromoApiResult({
    required this.ok,
    required this.message,
    this.code = '',
    this.type = 'pro_grant',
    this.days = 0,
    this.lifetime = false,
    this.untilMs,
    this.data = const {},
  });
}

class PromoApi {
  PromoApi._();
  static final PromoApi I = PromoApi._();

  static const String baseUrl = String.fromEnvironment(
    'PROMO_API',
    defaultValue: 'https://reeltunes-codes.buildwise.workers.dev',
  );

  static const Duration _timeout = Duration(seconds: 8);
  final http.Client _client = http.Client();

  Future<PromoApiResult> redeem({
    required String code,
    required String deviceId,
    required String installId,
  }) async {
    final json = await _post(
      '/api/redeem',
      {
        'code': code,
        'deviceId': deviceId,
        'installId': installId,
      },
    );
    return _result(json);
  }

  Future<bool> checkToken(String token) async {
    final json = await _send('GET', '/api/admin/session', token: token);
    return json['ok'] == true;
  }

  Future<PromoApiResult> fetchDashboard(String token) async {
    final json = await _send('GET', '/api/admin/codes', token: token);
    return _result(json);
  }

  Future<PromoApiResult> fetchRedemptions(String token, {int limit = 200}) async {
    final json = await _send(
      'GET',
      '/api/admin/redemptions?limit=$limit',
      token: token,
    );
    return _result(json);
  }

  Future<PromoApiResult> fetchStats(String token) async {
    final json = await _send('GET', '/api/admin/stats', token: token);
    return _result(json);
  }

  Future<PromoApiResult> createCode(
    String token, {
    required String type,
    required int days,
    required int maxUses,
    required int validForDays,
    required String campaign,
    required String notes,
    String? code,
  }) async {
    final json = await _send(
      'POST',
      '/api/admin/codes',
      token: token,
      body: {
        'type': type,
        'days': days,
        'maxUses': maxUses,
        'validForDays': validForDays,
        'campaign': campaign,
        'notes': notes,
        if ((code ?? '').trim().isNotEmpty) 'code': code!.trim(),
      },
    );
    return _result(json);
  }

  Future<PromoApiResult> setRevoked(
    String token,
    String code,
    bool revoked,
  ) async {
    final json = await _send(
      'PATCH',
      '/api/admin/codes/${Uri.encodeComponent(code)}',
      token: token,
      body: {'revoked': revoked},
    );
    return _result(json);
  }

  Future<PromoApiResult> deleteCode(String token, String code) async {
    final json = await _send(
      'DELETE',
      '/api/admin/codes/${Uri.encodeComponent(code)}?force=1',
      token: token,
    );
    return _result(json);
  }

  Future<PromoApiResult> revokeAll(String token) async {
    final json = await _send('POST', '/api/admin/revoke-all', token: token);
    return _result(json);
  }

  // ---- transport ---------------------------------------------------------

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) => _send('POST', path, body: body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
      if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
    };

    http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed).timeout(_timeout);
    } on TimeoutException {
      throw const PromoApiException('Server took too long. Try again.');
    } on SocketException {
      throw const PromoApiException('No connection. Try again when online.');
    } on http.ClientException {
      throw const PromoApiException('No connection. Try again when online.');
    } catch (e) {
      throw PromoApiException('Could not reach the server. $e');
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      json = null;
    }

    if (json == null) {
      if (response.statusCode >= 500) {
        throw const PromoApiException('Server is busy. Try again.');
      }
      throw const PromoApiException('Unexpected server response.');
    }

    // 5xx means "we do not know", so callers may use the offline cache.
    if (response.statusCode >= 500) {
      throw PromoApiException(
        json['message']?.toString() ?? 'Server is busy. Try again.',
      );
    }
    return json;
  }

  PromoApiResult _result(Map<String, dynamic> json) => PromoApiResult(
    ok: json['ok'] == true,
    message: json['message']?.toString() ?? '',
    code: json['code']?.toString() ?? '',
    type: json['type']?.toString() ?? 'pro_grant',
    days: (json['days'] as num?)?.toInt() ?? 0,
    lifetime: json['lifetime'] == true,
    untilMs: (json['untilMs'] as num?)?.toInt(),
    data: json,
  );
}
