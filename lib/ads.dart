// AdMob: one banner slot, one consent flow.
//
// Free tier only (`Entitlements.showAds`): never during the trial, never for
// Pro. Slots and the reasoning behind them live in `docs/ads.md`.
//
// Test ids are used in every debug build (tapping them is safe and expected).
// A release build picks the real unit from
//   --dart-define=ADMOB_BANNER_UNIT=ca-app-pub-…/…
// and falls back to the sample unit, so an internal-testing AAB keeps working
// before the AdMob console values exist.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'entitlements.dart';

/// Google's official sample banner unit.
const String _testBannerUnit = 'ca-app-pub-3940256099942544/6300978111';

/// Supplied by `--dart-define=ADMOB_BANNER_UNIT=...` in release builds.
const String _releaseBannerUnit = String.fromEnvironment('ADMOB_BANNER_UNIT');

/// The unit the banner should request right now.
String get bannerUnitId =>
    kDebugMode || _releaseBannerUnit.isEmpty
        ? _testBannerUnit
        : _releaseBannerUnit;

/// True when a real, revenue-earning unit is configured.
bool get usingLiveAdUnit => !kDebugMode && _releaseBannerUnit.isNotEmpty;

class Ads {
  Ads._();
  static final Ads I = Ads._();

  Future<void>? _boot;
  bool _ready = false;

  /// The SDK finished initializing; banner requests can be made.
  bool get ready => _ready;

  /// Initializes the SDK once and collects UMP consent in the background.
  /// Deliberately failure-tolerant: no ad is ever worth blocking the app.
  Future<void> init() => _boot ??= _start();

  Future<void> _start() async {
    try {
      await MobileAds.instance.initialize();
      _ready = true;
    } catch (e) {
      debugPrint('AdMob init failed: $e');
      return;
    }
    unawaited(ensureConsent());
  }

  /// Requests consent info and shows the GDPR form when one is required.
  /// Non-personalized ads remain available as the fallback.
  Future<void> ensureConsent() async {
    final done = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () async {
        try {
          await ConsentForm.loadAndShowConsentFormIfRequired(
            (FormError? error) {
              if (error != null) {
                debugPrint('UMP form dismissed with error: ${error.message}');
              }
            },
          );
        } catch (e) {
          debugPrint('UMP form failed: $e');
        } finally {
          if (!done.isCompleted) done.complete();
        }
      },
      (FormError error) {
        debugPrint('UMP info update failed: ${error.message}');
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future.timeout(const Duration(seconds: 20),
        onTimeout: () => debugPrint('UMP consent timed out'));
  }

  /// Whether Settings should offer the "Ad privacy choices" row.
  Future<bool> privacyOptionsRequired() async {
    try {
      final status =
          await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
      return status == PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      return false;
    }
  }

  /// Re-opens the consent / privacy options form (required entry point).
  Future<void> showPrivacyOptions() async {
    try {
      await ConsentForm.showPrivacyOptionsForm((FormError? error) {
        if (error != null) {
          debugPrint('UMP privacy form error: ${error.message}');
        }
      });
    } catch (e) {
      debugPrint('UMP privacy form failed: $e');
    }
  }
}

/// Slot B from `docs/ads.md`: a sticky, anchored adaptive banner that sits
/// directly above the mini bar. Renders nothing for Pro, during the trial, or
/// when the SDK has no fill.
class AdBanner extends StatelessWidget {
  const AdBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Entitlements.I,
      builder: (context, _) {
        // Private path check: ads never load or render for Pro.
        if (!Entitlements.I.showAds) return const SizedBox.shrink();
        return const _BannerFrame();
      },
    );
  }
}

class _BannerFrame extends StatefulWidget {
  const _BannerFrame();

  @override
  State<_BannerFrame> createState() => _BannerFrameState();
}

class _BannerFrameState extends State<_BannerFrame> {
  BannerAd? _ad;
  bool _visible = false;
  bool _loading = false;
  int _attempt = 0;
  Timer? _retry;

  /// Wide gap on purpose: an accidental click on the ad is the one metric that
  /// gets an AdMob account flagged.
  static const double _gap = 8;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ad == null && !_loading && _attempt == 0) _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _ad?.dispose();
    _ad = null;
    super.dispose();
  }

  Future<void> _load() async {
    if (!Entitlements.I.showAds) return;
    if (_loading) return;
    _loading = true;
    try {
      await Ads.I.init();
      if (!mounted) return;
      final width = MediaQuery.sizeOf(context).width.truncate();
      final size = await AdSize
              .getLargeAnchoredAdaptiveBannerAdSizeWithOrientation(
                  MediaQuery.orientationOf(context), width) ??
          AdSize.banner;
      if (!mounted) return;
      final ad = BannerAd(
        adUnitId: bannerUnitId,
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) {
            if (!mounted) {
              ad.dispose();
              return;
            }
            setState(() {
              _visible = true;
              _attempt = 0;
            });
          },
          onAdFailedToLoad: (ad, error) {
            ad.dispose();
            if (identical(_ad, ad)) _ad = null;
            if (!mounted) return;
            // Back off instead of hammering the network: 30 s → 2 min → 5 min.
            _attempt++;
            final delay = switch (_attempt) {
              1 => const Duration(seconds: 30),
              2 => const Duration(minutes: 2),
              _ => const Duration(minutes: 5),
            };
            _retry?.cancel();
            _retry = Timer(delay, () {
              if (mounted) _load();
            });
            debugPrint('banner load failed (${error.code}): ${error.message}');
          },
        ),
      );
      _ad = ad;
      await ad.load();
    } catch (e) {
      debugPrint('banner setup failed: $e');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_visible || ad == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: _gap),
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
