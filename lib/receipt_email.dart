// Receipt email — sends a purchase confirmation to the user via a backend
// endpoint that forwards to Resend.
//
// The Resend API key never ships in the APK: it lives only on the backend.
// The app POSTs JSON to a configurable endpoint (e.g. a Cloudflare Worker),
// which calls Resend's API and delivers the email.
//
// Example worker (Cloudflare):
//   export default {
//     async fetch(request, env) {
//       if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
//       const body = await request.json();
//       await fetch('https://api.resend.com/emails', {
//         method: 'POST',
//         headers: { 'Authorization': `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
//         body: JSON.stringify({
//           from: 'ReelTunes <receipts@yourdomain.com>',
//           to: [body.customerEmail],
//           subject: 'ReelTunes Pro receipt',
//           html: `<p>Thank you for subscribing to ReelTunes Pro!</p>
//                  <p>Plan: ${body.productId}</p>
//                  <p>Amount: ${body.priceString}</p>
//                  <p>Purchased: ${body.purchasedAt}</p>
//                  ${body.expirationDate ? `<p>Expires: ${body.expirationDate}</p>` : ''}`,
//         }),
//       });
//       return new Response('OK');
//     },
//   };

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'entitlements.dart';

/// Receipt data emailed to the user after a successful Pro purchase.
class PurchaseReceipt {
  const PurchaseReceipt({
    required this.productId,
    required this.priceString,
    required this.purchasedAt,
    required this.customerEmail,
    this.expirationDate,
  });

  final String productId;        // reeltunes_pro_monthly / reeltunes_pro_annual
  final String priceString;      // e.g. "₹399 / month"
  final DateTime purchasedAt;
  final String customerEmail;
  final DateTime? expirationDate;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'productId': productId,
      'priceString': priceString,
      'purchasedAt': purchasedAt.toIso8601String(),
      'customerEmail': customerEmail,
    };
    if (expirationDate != null) {
      json['expirationDate'] = expirationDate!.toIso8601String();
    }
    return json;
  }
}

/// Posts a purchase receipt to a backend endpoint that emails it via Resend.
/// Failures are logged only — the purchase is already complete, so a failed
/// email must never block or revert the entitlement.
class ReceiptEmail {
  ReceiptEmail._();
  static final ReceiptEmail I = ReceiptEmail._();

  /// Endpoint URL that accepts POST JSON and forwards to Resend.
  /// Set via --dart-define RECEIPT_EMAIL_ENDPOINT= or Settings → Debug tiers.
  static const String endpoint = String.fromEnvironment(
    'RECEIPT_EMAIL_ENDPOINT',
    defaultValue: '',
  );

  String? _email;

  /// The user's email address. Set once from Settings; persisted locally.
  String? get email => _email;
  void setEmail(String email) => _email = email;

  /// Returns true when an endpoint and email are configured.
  bool get configured => endpoint.isNotEmpty && _email != null && _email!.isNotEmpty;

  /// Send the receipt. Fire-and-forget: errors are logged, never surfaced.
  Future<void> send(PurchaseReceipt receipt) async {
    if (!configured) {
      if (kDebugMode) {
        debugPrint('receipt email: endpoint or email not configured — skipping');
      }
      return;
    }
    try {
      final uri = Uri.parse(endpoint);
      final client = HttpClient();
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.add('Accept', 'application/json');
      request.add(utf8.encode(jsonEncode(receipt.toJson())));
      final response = await request.close();
      await response.transform(utf8.decoder).join();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint('receipt email: sent OK to ${receipt.customerEmail}');
      } else {
        debugPrint('receipt email: HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('receipt email: failed $e');
    }
  }
}
