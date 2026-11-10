// One purchase, as recorded on this device.
//
// Google Play is the merchant of record, so this is deliberately not an
// invoice. It powers the in-app "Download purchase summary" PDF and the small
// history shown next to the Pro row. Nothing here is uploaded; the list lives
// in SharedPreferences and disappears on uninstall.

class PurchaseRecord {
  const PurchaseRecord({
    required this.productId,
    required this.planLabel,
    required this.priceString,
    required this.purchasedAt,
    this.expiresAt,
    this.willRenew = false,
    this.sandbox = false,
    this.storeLabel = 'Google Play',
  });

  final String productId;
  final String planLabel;
  final String priceString;
  final DateTime purchasedAt;
  final DateTime? expiresAt;
  final bool willRenew;

  /// True for RevenueCat Test Store / Play licence-tester purchases. Printed
  /// on the PDF so a sandbox run is never mistaken for a real payment.
  final bool sandbox;
  final String storeLabel;

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'planLabel': planLabel,
        'priceString': priceString,
        'purchasedAt': purchasedAt.millisecondsSinceEpoch,
        if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
        'willRenew': willRenew,
        'sandbox': sandbox,
        'storeLabel': storeLabel,
      };

  static PurchaseRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final productId = raw['productId']?.toString();
    final ms = raw['purchasedAt'];
    if (productId == null || productId.isEmpty || ms is! int || ms <= 0) {
      return null;
    }
    final end = raw['expiresAt'];
    return PurchaseRecord(
      productId: productId,
      planLabel: raw['planLabel']?.toString() ?? _planFrom(productId),
      priceString: raw['priceString']?.toString() ?? '',
      purchasedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      expiresAt: end is int && end > 0
          ? DateTime.fromMillisecondsSinceEpoch(end)
          : null,
      willRenew: raw['willRenew'] == true,
      sandbox: raw['sandbox'] == true,
      storeLabel: raw['storeLabel']?.toString() ?? 'Google Play',
    );
  }

  static String planFromProduct(String? productId) => _planFrom(productId);

  static String _planFrom(String? productId) {
    final id = productId?.toLowerCase() ?? '';
    if (id.contains('year') || id.contains('annual')) return 'Yearly';
    if (id.contains('month')) return 'Monthly';
    return 'ReelTunes Pro';
  }
}
