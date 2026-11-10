// AdMob: banner (sticky), in-list playlist banners, rewarded video and the
// app-open ad. Free tier only (`Entitlements.showAds`): never during the trial,
// never for Pro, and paused for 24 h after a coin-shop "no ads" purchase.
//
// Identifiers live in `lib/ad_config.dart`. Live units are used by default;
// `--dart-define=ADMOB_TEST_ADS=true` (or Settings → Debug tiers) switches to
// Google's samples, which are safe to tap while testing.
//
// Ad events (loaded, displayed, opened, revenue, failed) are reported to
// RevenueCat Charts through the RevenueCat AdMob adapter. This is free:
// RevenueCat does not take a cut of ad revenue. Impression-level ad revenue
// must be on and saved in the AdMob account for revenue events to arrive.

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:purchases_admob_flutter/purchases_admob_flutter.dart';
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

  RewardedAd? _rewarded;
  bool _rewardedLoading = false;

  /// Rewarded video shown before a download/import in Free tier (one per
  /// audio). Preloaded so it's ready when the user taps "download"/"import".
  RewardedAd? _downloadAd;
  bool _downloadLoading = false;

  /// Preloaded playlist banner ads, kept warm so an impression is never missed
  /// because the user scrolled past before the ad finished loading.
  final List<BannerAd> _playlistAds = [];
  bool _playlistLoading = false;
  static const int _playlistTarget = 2;

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
      unawaited(preloadDownloadAd());
      unawaited(preloadPlaylistAds());
    }));
    // If ads are ever disabled (Pro, trial, coin-shop no-ads window), drop any
    // preloaded ads so they don't sit idle in memory.
    Entitlements.I.addListener(_onAdsGateChanged);
  }

  void _onAdsGateChanged() {
    if (!Entitlements.I.showAds) {
      _downloadAd?.dispose();
      _downloadAd = null;
      _downloadLoading = false;
      for (final a in _playlistAds) {
        a.dispose();
      }
      _playlistAds.clear();
      _playlistLoading = false;
    } else {
      unawaited(preloadDownloadAd());
      unawaited(preloadPlaylistAds());
    }
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
    _downloadAd?.dispose();
    _downloadAd = null;
    _downloadLoading = false;
    for (final a in _playlistAds) {
      a.dispose();
    }
    _playlistAds.clear();
    _playlistLoading = false;
    notifyListeners();
    if (!v) {
      unawaited(preloadRewarded());
      unawaited(preloadAppOpen());
      unawaited(preloadDownloadAd());
      unawaited(preloadPlaylistAds());
    }
  }

  /// Fills the playlist banner pool up to [_playlistTarget]. Safe to call
  /// repeatedly — it only loads while the pool isn't full and no load is in
  /// flight. Only ads that actually loaded (onAdLoaded fired) enter the pool,
  /// so takePlaylistAd() never returns an un-loaded ad.
  Future<void> preloadPlaylistAds() async {
    if (!Entitlements.I.showAds) return;
    while (_playlistAds.length < _playlistTarget && !_playlistLoading) {
      _playlistLoading = true;
      try {
        final ad = RevenueCatAdMob.createBannerAd(
          adUnitId: AdConfig.playlistUnitId,
          size: AdSize.banner,
          request: const AdRequest(),
          placement: 'playlist_banner',
          listener: BannerAdListener(
            onAdLoaded: (a) {
              final ba = a as BannerAd;
              if (!_playlistAds.contains(ba)) {
                _playlistAds.add(ba);
              }
              _playlistLoading = false;
              // Keep the pool topped up.
              if (_playlistAds.length < _playlistTarget) {
                unawaited(preloadPlaylistAds());
              }
            },
            onAdFailedToLoad: (a, error) {
              a.dispose();
              _playlistLoading = false;
              debugPrint(
                  'playlist banner preload failed: ${error.message}');
              unawaited(
                  _retryPlaylistAfter(const Duration(seconds: 30)));
            },
          ),
        );
        await ad.load();
      } catch (e) {
        _playlistLoading = false;
        debugPrint('playlist banner setup failed: $e');
        unawaited(_retryPlaylistAfter(const Duration(seconds: 30)));
      }
    }
  }

  /// Takes one preloaded playlist banner from the pool and triggers a refill.
  /// Returns null when the pool is empty (caller falls back to on-demand load
  /// or shows nothing).
  BannerAd? takePlaylistAd() {
    if (_playlistAds.isEmpty) return null;
    final ad = _playlistAds.removeAt(0);
    unawaited(preloadPlaylistAds());
    return ad;
  }

  Future<void> _retryPlaylistAfter(Duration d) async {
    await Future.delayed(d);
    if (Entitlements.I.showAds) {
      unawaited(preloadPlaylistAds());
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
      await RevenueCatAdMob.loadAndTrackRewardedAd(
        adUnitId: AdConfig.rewardedUnitId,
        request: const AdRequest(),
        placement: 'coin_shop_rewarded',
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
    try {
      await ad.showAndTrack(
        onUserEarnedReward: (_, _) => earned = true,
      );
    } catch (e) {
      ad.dispose();
      debugPrint('rewarded threw: $e');
      return false;
    }
    ad.dispose();
    unawaited(preloadRewarded());
    return earned;
  }

  // ---- download / import gate --------------------------------------------

  /// Preloads the rewarded video that gates a download or import in Free
  /// tier. One ad per audio; kept warm so it's ready when the user taps
  /// "download" or "import".
  Future<void> preloadDownloadAd() async {
    if (!Entitlements.I.showAds) return;
    if (!_ready || _downloadAd != null || _downloadLoading) return;
    _downloadLoading = true;
    try {
      await RevenueCatAdMob.loadAndTrackRewardedAd(
        adUnitId: AdConfig.downloadUnitId,
        request: const AdRequest(),
        placement: 'download_gate_rewarded',
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _downloadAd = ad;
            _downloadLoading = false;
          },
          onAdFailedToLoad: (error) {
            _downloadLoading = false;
            debugPrint(
                'download gate load failed (${error.code}): ${error.message}');
          },
        ),
      );
    } catch (e) {
      _downloadLoading = false;
      debugPrint('download gate setup failed: $e');
    }
  }

  /// Shows the download/import gate ad. Returns true only when the user
  /// watched far enough for Google to fire the reward callback, meaning the
  /// download/import may proceed. Returns false when no ad is available —
  /// the caller should still proceed gracefully so the app never blocks.
  Future<bool> showDownloadAd() async {
    await init();
    if (_downloadAd == null) {
      unawaited(preloadDownloadAd());
      final end = DateTime.now().add(const Duration(seconds: 6));
      while (_downloadAd == null && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    final ad = _downloadAd;
    if (ad == null) return false;
    _downloadAd = null;

    var earned = false;
    try {
      await ad.showAndTrack(
        onUserEarnedReward: (_, _) => earned = true,
      );
    } catch (e) {
      ad.dispose();
      debugPrint('download gate threw: $e');
      return false;
    }
    ad.dispose();
    unawaited(preloadDownloadAd());
    return earned;
  }

  // ---- app open ----------------------------------------------------------

  Future<void> preloadAppOpen() async {
    if (!_ready || _appOpen != null || _appOpenLoading) return;
    _appOpenLoading = true;
    try {
      await RevenueCatAdMob.loadAndTrackAppOpenAd(
        adUnitId: AdConfig.appOpenUnitId,
        request: const AdRequest(),
        placement: 'app_open',
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

  /// Shows the app-open ad on every cold start when an ad is available.
  /// Safe no-op for Pro / trial / an active coin-shop ad-free window.
  Future<void> maybeShowAppOpen() async {
    if (!Entitlements.I.showAds) return;
    await init();
    // Make sure the ad is warming up.
    unawaited(preloadAppOpen());
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Give the preloaded ad a generous window so a slow consent flow or ad
    // fetch doesn't cause us to miss the slot entirely.
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (_appOpen == null && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final ad = _appOpen;
    if (ad == null) return;
    _appOpen = null;
    await prefs.setInt('adAppOpenShownMs', now);

    try {
      await ad.showAndTrack();
    } catch (e) {
      ad.dispose();
      debugPrint('app-open threw: $e');
      return;
    }
    ad.dispose();
    unawaited(preloadAppOpen());
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
///
/// A playlist banner is preloaded via [`Ads.takePlaylistAd`] so it is ready the
/// instant the card scrolls into view. Without preloading, fast scrolling would
/// skip the placement before `BannerAd.load()` finishes, losing the impression.
class PlaylistAdCard extends StatefulWidget {
  const PlaylistAdCard({super.key});

  @override
  State<PlaylistAdCard> createState() => _PlaylistAdCardState();
}

class _PlaylistAdCardState extends State<PlaylistAdCard> {
  BannerAd? _preloaded;

  @override
  void initState() {
    super.initState();
    if (Entitlements.I.showAds) {
      _preloaded = Ads.I.takePlaylistAd();
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Entitlements.I, Ads.I]),
      builder: (context, _) {
        if (!Entitlements.I.showAds) {
          _preloaded?.dispose();
          _preloaded = null;
          return const SizedBox.shrink();
        }
        return _BannerFrame(
          key: widget.key,
          unitId: AdConfig.playlistUnitId,
          adaptive: false,
          inline: true,
          preloadedAd: _preloaded,
        );
      },
    );
  }
}

class _BannerFrame extends StatefulWidget {
  final String unitId;
  final bool adaptive;
  final bool inline;
  /// A preloaded banner ad to show immediately (playlist placement). When null,
  /// the frame loads on demand.
  final BannerAd? preloadedAd;
  const _BannerFrame({
    super.key,
    required this.unitId,
    this.adaptive = false,
    this.inline = false,
    this.preloadedAd,
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
  void initState() {
    super.initState();
    // Playlist placement with a preloaded ad: show it immediately, no load
    // wait. Without a preload, fall through to on-demand loading below.
    if (widget.inline && widget.preloadedAd != null) {
      _ad = widget.preloadedAd;
      _visible = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sticky banner (non-inline) loads on demand when it enters the tree.
    // Inline playlist without a preload also loads on demand as a fallback.
    if (_ad == null && !_loading && _attempt == 0 && !widget.inline) {
      _load();
    }
    if (widget.inline && _ad == null && !_loading && _attempt == 0) {
      _load();
    }
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
      final ad = RevenueCatAdMob.createBannerAd(
        adUnitId: widget.unitId,
        size: size,
        request: const AdRequest(),
        placement: widget.inline ? 'playlist_banner' : 'home_banner',
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
