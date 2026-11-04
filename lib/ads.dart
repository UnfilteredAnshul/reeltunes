// AdMob: banner (sticky), in-list playlist banners, rewarded video and the
// app-open ad. Free tier only (`Entitlements.showAds`): never during the trial,
// never for Pro, and paused for 24 h after a coin-shop "no ads" purchase.
//
// Identifiers live in `lib/ad_config.dart`. Live units are used by default;
// `--dart-define=ADMOB_TEST_ADS=true` (or Settings → Debug tiers) switches to
// Google's samples, which are safe to tap while testing.

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_config.dart';
import 'entitlements.dart';

/// The unit the sticky banner should request right now.
String get bannerUnitId => AdConfig.bannerUnitId;

/// True when real, revenue-earning units are configured.
bool get usingLiveAdUnit => AdConfig.bannerIsLive;

class Ads extends ChangeNotifier {
  Ads._();
  static final Ads I = Ads._();

  Future<void>? _boot;
  bool _ready = false;

  AppOpenAd? _appOpen;
  bool _appOpenLoading = false;
  bool _appOpenShownThisLaunch = false;

  RewardedAd? _rewarded;
  bool _rewardedLoading = false;

  /// The SDK finished initializing; banner requests can be made.
  bool get ready => _ready;

  bool get useTestAds => AdConfig.useTestAds;

  /// Initializes the SDK once and collects UMP consent in the background.
  /// Deliberately failure-tolerant: no ad is ever worth blocking the app.
  Future<void> init() => _boot ??= _start();

  Future<void> _start() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (kDebugMode) {
        AdConfig.setDebugTestAds(prefs.getBool('adUseTestUnits') ?? false);
      }
      await MobileAds.instance.initialize();
      _ready = true;
    } catch (e) {
      debugPrint('AdMob init failed: $e');
      return;
    }
    notifyListeners();
    // Consent comes first; the full-screen formats are preloaded after it so
    // the first app-open / rewarded request is never a consent-form surprise.
    unawaited(ensureConsent().then((_) {
      if (!Entitlements.I.showAds) return;
      unawaited(preloadRewarded());
      unawaited(preloadAppOpen());
    }));
  }

  /// Debug-only switch used by Settings → Debug tiers. Persisted so the choice
  /// survives a restart.
  Future<void> setUseTestAds(bool v) async {
    if (!kDebugMode) return;
    AdConfig.setDebugTestAds(v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('adUseTestUnits', v);
    _rewarded?.dispose();
    _rewarded = null;
    _appOpen?.dispose();
    _appOpen = null;
    notifyListeners();
    if (!v) {
      unawaited(preloadRewarded());
      unawaited(preloadAppOpen());
    }
  }

  // ---- consent -----------------------------------------------------------

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

  // ---- rewarded (coin shop) ---------------------------------------------

  Future<void> preloadRewarded() async {
    if (!_ready || _rewarded != null || _rewardedLoading) return;
    _rewardedLoading = true;
    try {
      await RewardedAd.load(
        adUnitId: AdConfig.rewardedUnitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _rewarded = ad;
            _rewardedLoading = false;
          },
          onAdFailedToLoad: (error) {
            _rewardedLoading = false;
            debugPrint(
                'rewarded load failed (${error.code}): ${error.message}');
          },
        ),
      );
    } catch (e) {
      _rewardedLoading = false;
      debugPrint('rewarded setup failed: $e');
    }
  }

  /// Shows one rewarded video. Returns true only when the user watched far
  /// enough for Google to fire the reward callback.
  Future<bool> showRewarded() async {
    await init();
    if (_rewarded == null) {
      unawaited(preloadRewarded());
      final end = DateTime.now().add(const Duration(seconds: 6));
      while (_rewarded == null && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    final ad = _rewarded;
    if (ad == null) return false;
    _rewarded = null;

    var earned = false;
    final done = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        if (!done.isCompleted) done.complete(earned);
        unawaited(preloadRewarded());
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        a.dispose();
        debugPrint('rewarded show failed: ${error.message}');
        if (!done.isCompleted) done.complete(false);
        unawaited(preloadRewarded());
      },
    );
    try {
      await ad.show(
        onUserEarnedReward: (_, _) => earned = true,
      );
    } catch (e) {
      ad.dispose();
      debugPrint('rewarded threw: $e');
      return false;
    }
    return done.future.timeout(const Duration(minutes: 3),
        onTimeout: () => earned);
  }

  // ---- app open ----------------------------------------------------------

  Future<void> preloadAppOpen() async {
    if (!_ready || _appOpen != null || _appOpenLoading) return;
    _appOpenLoading = true;
    try {
      await AppOpenAd.load(
        adUnitId: AdConfig.appOpenUnitId,
        request: const AdRequest(),
        adLoadCallback: AppOpenAdLoadCallback(
          onAdLoaded: (ad) {
            _appOpen = ad;
            _appOpenLoading = false;
          },
          onAdFailedToLoad: (error) {
            _appOpenLoading = false;
            debugPrint(
                'app-open load failed (${error.code}): ${error.message}');
          },
        ),
      );
    } catch (e) {
      _appOpenLoading = false;
      debugPrint('app-open setup failed: $e');
    }
  }

  /// Shows the app-open ad at most once per launch and at most once every four
  /// hours. Safe no-op for Pro / trial / an active coin-shop ad-free window.
  Future<void> maybeShowAppOpen() async {
    if (!Entitlements.I.showAds) return;
    if (_appOpenShownThisLaunch) return;
    await init();
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt('adAppOpenShownMs') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < const Duration(hours: 4).inMilliseconds) return;

    // Give the preloaded ad a short window; the library must never wait longer
    // than this for an ad.
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (_appOpen == null && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final ad = _appOpen;
    if (ad == null) return;
    _appOpen = null;
    _appOpenShownThisLaunch = true;
    await prefs.setInt('adAppOpenShownMs', now);

    final done = Completer<void>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        if (!done.isCompleted) done.complete();
        unawaited(preloadAppOpen());
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        a.dispose();
        debugPrint('app-open show failed: ${error.message}');
        if (!done.isCompleted) done.complete();
        unawaited(preloadAppOpen());
      },
    );
    try {
      await ad.show();
    } catch (e) {
      ad.dispose();
      debugPrint('app-open threw: $e');
      return;
    }
    await done.future.timeout(const Duration(minutes: 2),
        onTimeout: () {});
  }
}

/// Slot B from `docs/ads.md`: a sticky, anchored adaptive banner that sits
/// directly above the mini bar. Renders nothing for Pro, during the trial, or
/// when a coin-shop "no ads" window is running.
class AdBanner extends StatelessWidget {
  const AdBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Entitlements.I, Ads.I]),
      builder: (context, _) {
        // Private path check: ads never load or render for Pro.
        if (!Entitlements.I.showAds) return const SizedBox.shrink();
        return _BannerFrame(
          key: ValueKey('sticky-${AdConfig.useTestAds}'),
          unitId: AdConfig.bannerUnitId,
          adaptive: true,
        );
      },
    );
  }
}

/// The playlist placement: an in-list ad card rendered after the 8th and 18th
/// audio. Both placements request the same unit — AdMob pays per impression,
/// so duplicating the unit is allowed (separate units only split reporting).
class PlaylistAdCard extends StatelessWidget {
  const PlaylistAdCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Entitlements.I, Ads.I]),
      builder: (context, _) {
        if (!Entitlements.I.showAds) return const SizedBox.shrink();
        return _BannerFrame(
          key: ValueKey('playlist-${AdConfig.useTestAds}'),
          unitId: AdConfig.playlistUnitId,
          adaptive: false,
          inline: true,
        );
      },
    );
  }
}

class _BannerFrame extends StatefulWidget {
  final String unitId;
  final bool adaptive;
  final bool inline;
  const _BannerFrame({
    super.key,
    required this.unitId,
    this.adaptive = false,
    this.inline = false,
  });

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
      final AdSize size;
      if (widget.adaptive) {
        size = await AdSize
                .getLargeAnchoredAdaptiveBannerAdSizeWithOrientation(
                    MediaQuery.orientationOf(context),
                    MediaQuery.sizeOf(context).width.truncate()) ??
            AdSize.banner;
      } else {
        size = AdSize.banner;
      }
      if (!mounted) return;
      final ad = BannerAd(
        adUnitId: widget.unitId,
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
    if (widget.inline) {
      final scheme = Theme.of(context).colorScheme;
      return LayoutBuilder(
        builder: (context, constraints) {
          // 24 px outer + 8 px inner padding. Never crop a banner: hide the
          // placement on screens too narrow to show the full 320 px width.
          if (constraints.maxWidth - 32 < ad.size.width) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Icon(Icons.info_outline,
                          size: 12, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text('Ad',
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant)),
                      const Spacer(),
                    ]),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: ad.size.width.toDouble(),
                      height: ad.size.height.toDouble(),
                      child: AdWidget(ad: ad),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
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
