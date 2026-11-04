// Subscriptions, via RevenueCat over Google Play Billing.
//
// Why RevenueCat and not raw `in_app_purchase`: Play Billing never tells you
// *what the user is entitled to*, only what they bought. RevenueCat keeps that
// mapping (entitlement "pro" ← monthly/annual package), verifies receipts
// server-side, restores on a new device, and gives one CustomerInfo object that
// this file turns into `Entitlements`.
//
// Two build-time inputs, both `--dart-define` so no secret is committed:
//   RC_ANDROID_KEY   the public Android SDK key from the RevenueCat dashboard
//                    (`goog_...`; it is safe to ship, unlike a server key)
//   RC_ENTITLEMENT   entitlement identifier, default "reeltunes_pro"
//
// Without RC_ANDROID_KEY the app simply has no store: the paywall falls back to
// the debug shortcut in a debug build, and to a "not live yet" toast in release.
// Everything else in the app keeps working, so a sideloaded copy never crashes
// on a missing key.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'entitlements.dart';

enum PurchaseOutcome { success, cancelled, pending, unavailable, failed }

/// Everything the paywall needs to draw one plan row, with no RevenueCat types
/// leaking into the UI.
class PlanView {
  final String priceString;

  /// Play's own per-month equivalent for annual plans, when it provides one.
  final String? perMonthString;

  /// True when this product carries an introductory (free-trial) phase.
  final bool hasTrial;

  const PlanView({
    required this.priceString,
    this.perMonthString,
    this.hasTrial = false,
  });
}

class PurchaseReport {
  final PurchaseOutcome outcome;

  /// Only set when the user needs to be told something specific.
  final String? message;

  const PurchaseReport(this.outcome, [this.message]);

  bool get ok => outcome == PurchaseOutcome.success;
  bool get quiet => outcome == PurchaseOutcome.cancelled;
}

class Billing {
  Billing._();
  static final Billing I = Billing._();

  /// Public SDK key from the RevenueCat dashboard (`goog_...`). Not a secret:
  /// it can only read this app's own products.
  static const String androidKey =
      String.fromEnvironment('RC_ANDROID_KEY', defaultValue: '');

  /// Must match the entitlement identifier in the RevenueCat dashboard.
  static const String entitlementId =
      String.fromEnvironment('RC_ENTITLEMENT', defaultValue: 'reeltunes_pro');

  /// Play's own subscription page: the only legitimate way to cancel, and the
  /// wording Play requires apps to point at.
  static const String manageUrl =
      'https://play.google.com/store/account/subscriptions';

  bool _configured = false;

  /// True when a key was supplied *and* the SDK accepted it. Gates every store
  /// call, so the rest of the app never has to think about it.
  bool get configured => _configured;

  Offering? _offering;
  Offering? get offering => _offering;

  bool loadingOfferings = false;

  /// Last human-readable failure, surfaced on the paywall. Debug detail goes to
  /// logcat only (same rule as extraction errors).
  String? lastError;

  Future<void> init() async {
    if (androidKey.isEmpty) {
      debugPrint('billing: RC_ANDROID_KEY not set — store disabled');
      return;
    }
    try {
      await Purchases.setLogLevel(kDebugMode ? LogLevel.debug : LogLevel.warn);
      await Purchases.configure(PurchasesConfiguration(androidKey));
      Purchases.addCustomerInfoUpdateListener(_apply);
      _configured = true;
      await refresh();
      debugPrint('billing: ready (entitlement "$entitlementId")');
    } on PlatformException catch (e) {
      debugPrint('billing: configure failed ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('billing: configure failed $e');
    }
  }

  /// Pulls the current entitlement. Cheap and safe to call on every resume.
  Future<void> refresh() async {
    if (!_configured) return;
    try {
      _apply(await Purchases.getCustomerInfo());
    } catch (e) {
      debugPrint('billing: refresh failed $e');
    }
  }

  /// Monthly + yearly packages from the current offering, newest-first. Empty
  /// when the store is unreachable or the offering is not published yet.
  Future<List<Package>> loadOfferings({bool force = false}) async {
    if (!_configured) return const [];
    if (_offering != null && !force) return _offering!.availablePackages;
    loadingOfferings = true;
    lastError = null;
    try {
      final offerings = await Purchases.getOfferings();
      // `current` is the offering flagged "current" in the dashboard; if none
      // is flagged, fall back to the first published one.
      _offering = offerings.current ??
          (offerings.all.isEmpty ? null : offerings.all.values.first);
      if (_offering == null) {
        lastError = 'Prices are still being set up. Try again later.';
        return const [];
      }
      return _offering!.availablePackages;
    } on PlatformException catch (e) {
      debugPrint('billing: offerings failed ${e.code} ${e.message}');
      lastError = 'Could not reach the store. Check your connection.';
      return const [];
    } catch (e) {
      debugPrint('billing: offerings failed $e');
      lastError = 'Could not reach the store. Check your connection.';
      return const [];
    } finally {
      loadingOfferings = false;
    }
  }

  /// The package to buy for a given plan: the dashboard's predefined slot
  /// first, then the package type, then the Play product id. Survives a package
  /// being renamed in the dashboard.
  Package? packageFor(String plan) {
    final o = _offering;
    if (o == null) return null;
    final annual = plan == 'annual';
    final direct = annual ? o.annual : o.monthly;
    if (direct != null) return direct;
    final type = annual ? PackageType.annual : PackageType.monthly;
    for (final p in o.availablePackages) {
      if (p.packageType == type) return p;
    }
    final needle = annual ? 'annual' : 'monthly';
    for (final p in o.availablePackages) {
      if (p.storeProduct.identifier.toLowerCase().contains(needle)) return p;
    }
    return null;
  }

  /// What the paywall should show for a plan, or null when the store has no
  /// package for it (not configured, offline, or not published yet).
  PlanView? planView(String plan) {
    final p = packageFor(plan);
    if (p == null) return null;
    final product = p.storeProduct;
    return PlanView(
      priceString: product.priceString,
      perMonthString: product.pricePerMonthString,
      hasTrial: product.introductoryPrice != null,
    );
  }

  /// Annual saving against 12 monthly payments. Only computed from real Play
  /// prices — never a hard-coded percentage.
  String? get annualSaving {
    final m = packageFor('monthly');
    final a = packageFor('annual');
    if (m == null || a == null) return null;
    final monthly = m.storeProduct.price;
    final annual = a.storeProduct.price;
    if (monthly <= 0 || annual <= 0) return null;
    final full = monthly * 12;
    if (annual >= full) return null;
    final pct = ((1 - annual / full) * 100).round();
    return '$pct% off 12 months';
  }

  /// Whether any plan carries a Play free trial. Drives the honest wording
  /// under the plan cards.
  bool get hasIntroTrial =>
      planView('monthly')?.hasTrial == true ||
      planView('annual')?.hasTrial == true;

  Future<PurchaseReport> purchasePlan(String plan) async {
    final pkg = packageFor(plan);
    if (pkg == null) return const PurchaseReport(PurchaseOutcome.unavailable);
    return purchase(pkg);
  }

  Future<PurchaseReport> purchase(Package package) async {
    if (!_configured) return const PurchaseReport(PurchaseOutcome.unavailable);
    try {
      final result = await Purchases.purchase(PurchaseParams.package(package));
      _apply(result.customerInfo);
      if (!Entitlements.I.purchased) {
        // Purchase succeeded but the entitlement is not active yet: RevenueCat
        // is still validating. Restore will pick it up moments later.
        return const PurchaseReport(
          PurchaseOutcome.pending,
          'Payment received. Pro unlocks in a moment — tap Restore if it does not.',
        );
      }
      return const PurchaseReport(PurchaseOutcome.success);
    } on PlatformException catch (e) {
      return _mapError(e);
    } catch (e) {
      debugPrint('billing: purchase failed $e');
      return const PurchaseReport(PurchaseOutcome.failed);
    }
  }

  Future<PurchaseReport> restore() async {
    if (!_configured) return const PurchaseReport(PurchaseOutcome.unavailable);
    try {
      _apply(await Purchases.restorePurchases());
      if (Entitlements.I.purchased) {
        return const PurchaseReport(PurchaseOutcome.success);
      }
      return const PurchaseReport(
        PurchaseOutcome.failed,
        'No active subscription on this Google account.',
      );
    } on PlatformException catch (e) {
      return _mapError(e);
    } catch (e) {
      debugPrint('billing: restore failed $e');
      return const PurchaseReport(PurchaseOutcome.failed);
    }
  }

  PurchaseReport _mapError(PlatformException e) {
    final code = PurchasesErrorHelper.getErrorCode(e);
    debugPrint('billing: $code — ${e.message}');
    switch (code) {
      case PurchasesErrorCode.purchaseCancelledError:
        return const PurchaseReport(PurchaseOutcome.cancelled);
      case PurchasesErrorCode.paymentPendingError:
        return const PurchaseReport(
          PurchaseOutcome.pending,
          'Payment is pending with Google. Pro unlocks when it clears.',
        );
      case PurchasesErrorCode.productAlreadyPurchasedError:
      case PurchasesErrorCode.receiptAlreadyInUseError:
        return const PurchaseReport(
          PurchaseOutcome.failed,
          'This Google account already has an active subscription.',
        );
      case PurchasesErrorCode.networkError:
        return const PurchaseReport(
          PurchaseOutcome.failed,
          'No connection. Try again in a moment.',
        );
      case PurchasesErrorCode.purchaseNotAllowedError:
        return const PurchaseReport(
          PurchaseOutcome.failed,
          'Purchases are blocked on this device.',
        );
      case PurchasesErrorCode.storeProblemError:
      case PurchasesErrorCode.configurationError:
        return const PurchaseReport(
          PurchaseOutcome.failed,
          'The store is not available right now. Try again later.',
        );
      default:
        return const PurchaseReport(PurchaseOutcome.failed);
    }
  }

  /// One place where a CustomerInfo becomes app state.
  void _apply(CustomerInfo info) {
    final ent = info.entitlements.active[entitlementId];
    Entitlements.I.setStoreEntitlement(
      active: ent != null,
      trial: ent?.periodType == PeriodType.trial,
      willRenew: ent?.willRenew ?? false,
      endsAt: _parseDate(ent?.expirationDate),
      productId: ent?.productIdentifier,
    );
  }

  static DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toLocal();
}
