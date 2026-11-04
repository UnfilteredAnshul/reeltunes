// AdMob identifiers live here so switching between test ads and live ads is a
// single switch. Every unit below was created in the ReelTunes AdMob account.
//
// AdMob console → Apps → ReelTunes → App settings → "App ID"       → appId
// AdMob console → Apps → ReelTunes → Ad units → <format> → unit id → *Unit
//
// Live ads are the default in debug too, because the whole point of the
// current build is to prove that real fill arrives. Tapping your own live ad
// can get an AdMob account suspended, so the debug build also offers
// Settings → Debug tiers → "Use test ad units" (Google's samples, safe to tap)
// and honours `--dart-define=ADMOB_TEST_ADS=true`.

import 'package:flutter/foundation.dart';

class AdConfig {
  AdConfig._();

  // ---- live units (ReelTunes) ------------------------------------------
  static const String liveAppId = 'ca-app-pub-5837741403938321~1070877733';

  /// Sticky banner above the mini bar (home screen).
  static const String liveBannerUnit =
      'ca-app-pub-5837741403938321/1283639888';

  /// Rewarded video: watch → earn coins (coin shop / earn button).
  static const String liveRewardedUnit =
      'ca-app-pub-5837741403938321/4971428445';

  /// App-open ad: shown instead of a blank moment at cold start.
  static const String liveAppOpenUnit =
      'ca-app-pub-5837741403938321/1962121722';

  /// In-list banner for the playlist (used for both placements).
  static const String livePlaylistUnit =
      'ca-app-pub-5837741403938321/2022006489';

  // ---- Google's official samples (safe to tap) -------------------------
  static const String testAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const String testBannerUnit =
      'ca-app-pub-3940256099942544/6300978111';
  static const String testRewardedUnit =
      'ca-app-pub-3940256099942544/5224354917';
  static const String testAppOpenUnit =
      'ca-app-pub-3940256099942544/9257395921';

  /// The in-list placement uses a normal banner request, so Google's sample
  /// banner is the safe stand-in.
  static const String testPlaylistUnit = testBannerUnit;

  /// Forced from the build command: `flutter build … --dart-define=ADMOB_TEST_ADS=true`.
  static const bool _forcedTest = bool.fromEnvironment('ADMOB_TEST_ADS');

  /// Runtime debug switch (Settings → Debug tiers), persisted by `Ads`.
  static bool _debugTest = false;

  static void setDebugTestAds(bool v) => _debugTest = v;

  /// True = Google's samples. Never true in a release build unless forced.
  static bool get useTestAds => _forcedTest || (kDebugMode && _debugTest);

  /// Real app id. Must also be set in `AndroidManifest.xml`: the SDK reads it
  /// from there and crashes on startup if it is missing. Kept as a build
  /// override so a different AdMob account can be used without code edits.
  static const String appId = String.fromEnvironment(
    'ADMOB_APP_ID',
    defaultValue: liveAppId,
  );

  static String get bannerUnitId =>
      useTestAds ? testBannerUnit : liveBannerUnit;
  static String get rewardedUnitId =>
      useTestAds ? testRewardedUnit : liveRewardedUnit;
  static String get appOpenUnitId =>
      useTestAds ? testAppOpenUnit : liveAppOpenUnit;

  /// Both in-list placements request this same unit. AdMob counts impressions
  /// per request, so duplicating a unit is allowed and pays the same; separate
  /// units would only give separate reporting rows.
  static String get playlistUnitId =>
      useTestAds ? testPlaylistUnit : livePlaylistUnit;

  /// True only when a real, revenue-earning unit is configured.
  static bool get bannerIsLive => !useTestAds;

  /// Human-readable state, surfaced in the debug tier section.
  static String get modeLabel {
    if (useTestAds) {
      return 'Test ads · Google samples (safe to tap)';
    }
    return 'Live ads · banner, rewarded, app-open, playlist';
  }

  /// True when the Dart app id and the manifest app id could disagree.
  static bool get appIdMismatch => !useTestAds && appId != liveAppId;
}
