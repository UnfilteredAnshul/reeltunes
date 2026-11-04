// AdMob identifiers live here so switching from test ads to live ads is a
// two-line edit (plus the application id in AndroidManifest.xml).
//
// Debug builds ALWAYS request Google's sample banner. Live units only ever
// serve from a release build — clicking your own live ad can get the AdMob
// account suspended, and a debug build is exactly where you'd tap it.
//
// AdMob console → Apps → <app> → App settings → "App ID"        → appId
// AdMob console → Apps → <app> → Ad units → Banner → unit id     → bannerUnit

import 'package:flutter/foundation.dart';

class AdConfig {
  AdConfig._();

  /// Google's official sample ids. Safe to tap.
  static const String testAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const String testBannerUnit =
      'ca-app-pub-3940256099942544/6300978111';

  /// Real app id. Also must be set in `AndroidManifest.xml` — the SDK reads it
  /// from there and crashes on startup if it is missing.
  /// TODO(live ads): paste the AdMob app id.
  static const String appId = String.fromEnvironment(
    'ADMOB_APP_ID',
    defaultValue: testAppId,
  );

  /// Real banner unit.
  /// TODO(live ads): paste the AdMob banner unit id.
  static const String bannerUnit = String.fromEnvironment(
    'ADMOB_BANNER_UNIT',
    defaultValue: testBannerUnit,
  );

  /// Debug = sample ads, release = whatever is configured above.
  static bool get useTestAds => kDebugMode;

  static String get bannerUnitId => useTestAds ? testBannerUnit : bannerUnit;

  /// True only when a release build actually has a live unit configured.
  static bool get bannerIsLive => !useTestAds && bannerUnit != testBannerUnit;

  /// Human-readable state, surfaced in the debug tier section.
  static String get modeLabel => useTestAds
      ? 'Test ads (debug build)'
      : bannerIsLive
          ? 'Live ads · $bannerUnit'
          : 'Sample unit — no live id configured yet';

  /// True when the Dart side and the manifest disagree (a common cause of
  /// "no ads fill"): the manifest still points at the sample app id.
  static bool get appIdMismatch =>
      !useTestAds && bannerIsLive && appId == testAppId;
}
