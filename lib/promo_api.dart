// The network half of the promo system.
//
// `PromoEngine` keeps the rules and the local cache. This file only moves
// bytes: POST /api/redeem for users, GET /api/grant for the owner's
// "Remove effects" switch. Admin work lives in the Cloudflare dashboard.
//
// Release builds talk to the deployed Worker. Point it somewhere else with
//   flutter build ... --dart-define=PROMO_API=https://host
//
// Nothing here stores a secret.

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

  /// True when the owner pressed "Remove effects" for [code]. A missing code
  /// or an old backend answers false, so the app fails open (keeps the grant).
  Future<bool> grantEffectsRemoved(String code) async {
    final json = await _send(
      'GET',
      '/api/grant?code=${Uri.encodeComponent(code)}',
    );
    return json['effectsRemoved'] == true;
  }

  // ---- transport ---------------------------------------------------------

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) => _send('POST', path, body: body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
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
