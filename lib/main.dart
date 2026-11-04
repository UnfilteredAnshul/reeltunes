import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:receive_intent/receive_intent.dart' as ri;

import 'ads.dart';
import 'billing.dart';
import 'entitlements.dart';
import 'error_report.dart';
import 'library.dart';
import 'library_sync.dart';
import 'models.dart';
import 'player.dart';
import 'promo.dart';
import 'sheets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorReporting(); // failures land in logcat AND as on-screen toasts
  // App opens INSTANTLY — nothing blocking before runApp().
  runApp(const ReelTuneApp());
  // Media-session service warms up in the background; RtPlayer guarantees it
  // has completed before the first play() (see RtPlayer.ensureBackgroundService).
  RtPlayer.I.ensureBackgroundService();
}

class ReelTuneApp extends StatefulWidget {
  const ReelTuneApp({super.key});
  @override
  State<ReelTuneApp> createState() => _ReelTuneAppState();
}

class _ReelTuneAppState extends State<ReelTuneApp> {
  bool ready = false;

  @override
  void initState() {
    super.initState();
    AppStore.I.init().then((_) async {
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return MaterialApp(
      title: 'ReelTunes',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootMessengerKey,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: switch (store.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      home: const RootScreen(),
    );
  }

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0A5CD6), brightness: b),
      );
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen>
    with WidgetsBindingObserver {
  bool ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      const minSplash = Duration(milliseconds: 1400);
      await Future.wait([
        AppStore.I.init(),
        // Promo codes read the plan, so they load after entitlements without
        // holding up the other two.
        Entitlements.I.init().then((_) => PromoEngine.I.init()),
        Future.delayed(minSplash), // coin must be visible, even briefly
      ]);
      // Load the audios folder grant, restore a mirror after a reinstall and
      // pick up anything dropped in with a file manager.
      await LibrarySync.init();
      // AdMob + UMP consent warm up in the background: the free-tier banner
      // waits for `Ads.I.ready`, so the splash never blocks on the ad SDK.
      unawaited(Ads.I.init());
      _listenShareIntents();
      if (!mounted) return;
      if (!AppStore.I.audiosLinked) {
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          isDismissible: false,
          enableDrag: false,
          builder: (_) => const FirstRunSheet(),
        );
      }
      if (mounted) setState(() => ready = true);
      // The store check runs after the library is on screen: a slow Play
      // connection must never hold up the splash. It corrects the plan (and
      // therefore the caps and ads) as soon as it answers.
      _syncStore();
      // 3-day / 1-day nudge, once each. Never stacked on the first-run sheet.
      if (AppStore.I.audiosLinked) _maybeTrialReminder();
    });
  }

  /// Configures RevenueCat once, then refreshes the entitlement. Safe no-op
  /// when the build has no store key. Everything gated reads `Entitlements`,
  /// which is a `ChangeNotifier`, so the UI corrects itself.
  Future<void> _syncStore() => Billing.I.init();

  /// Shows the trial-ending sheet when one is due and marks it as seen.
  Future<void> _maybeTrialReminder() async {
    final due = Entitlements.I.dueTrialReminder;
    if (due == null || !mounted) return;
    await Entitlements.I.markReminderShown(due);
    if (!mounted) return;
    await showTrialReminderSheet(context, due);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the file manager / another app: files may have been
    // added to the audios folder, so re-scan before the user looks.
    if (state == AppLifecycleState.resumed && ready) {
      // Coming back from Play: the purchase may have completed off-app, or a
      // subscription may have lapsed since the last launch.
      Billing.I.refresh();
      LibrarySync.refreshState().then((_) async {
        await LibrarySync.sync();
        await _maybeTrialReminder();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ready ? const LibraryScreen() : const _SplashScreen();
  }

  /// After a share from YouTube / Instagram / TikTok: pick up the shared
  /// link, cold-start or live, and drop the user straight into Add reel.
  Future<void> _listenShareIntents() async {
    try {
      final initial = await ri.ReceiveIntent.getInitialIntent();
      if (initial != null) _handleShareIntent(initial);
      ri.ReceiveIntent.receivedIntentStream.listen(_handleShareIntent);
    } catch (e) {
      debugPrint('share intent unavailable: $e');
    }
  }

  void _handleShareIntent(ri.Intent? intent) {
    final i = intent;
    if (i == null) return;
    final text = i.extra?['android.intent.extra.TEXT']?.toString() ?? i.data ?? '';
    final match = RegExp(r'https?://\S+').firstMatch(text)?.group(0);
    if (match == null) return;
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: false,
      isScrollControlled: true,
      builder: (_) => AddReelSheet(initialUrl: match),
    );
  }
}

/// Splash shown while the store loads — just the coin loader, nothing else.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const CoinLoader(),
          const SizedBox(height: 20),
          Text('warming up your library…',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// Coin-style loader: a circle that flips on its edge over and over.
class CoinLoader extends StatefulWidget {
  const CoinLoader({super.key});
  @override
  State<CoinLoader> createState() => _CoinLoaderState();
}

class _CoinLoaderState extends State<CoinLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  late final Animation<double> _flip =
      CurvedAnimation(parent: _c, curve: Curves.easeInOutSine);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
        final phase = _flip.value;
        final scaleX = cos(phase * 2 * pi).abs(); // coin-edge illusion
        final hop = sin(phase * pi).abs() * 8.0; // little bounce per flip
        return Transform.translate(
          offset: Offset(0, -hop),
          child: Transform(
            transform: Matrix4.diagonal3Values(scaleX, 1.0, 1.0),
            alignment: Alignment.center,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [scheme.primaryContainer, scheme.primary],
                  center: const Alignment(-0.4, -0.4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withAlpha(90),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Opacity(
                opacity: scaleX < 0.25 ? 0.4 : 1.0,
                child: Icon(Icons.music_note_rounded, color: scheme.onPrimary, size: 38),
              ),
            ),
          ),
        );
      },
    );
  }
}

class FirstRunSheet extends StatefulWidget {
  const FirstRunSheet({super.key});
  @override
  State<FirstRunSheet> createState() => _FirstRunSheetState();
}

class _FirstRunSheetState extends State<FirstRunSheet> {
  bool busy = false;

  Future<void> _choose({bool preferDefault = false}) async {
    setState(() => busy = true);
    final picked = await LibrarySync.link(preferDefault: preferDefault);
    if (!mounted) return;
    setState(() => busy = false);
    if (picked == null) return;
    AppStore.I.completeFirstRun(picked.name ?? defaultSaveFolderName);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Where should your audios live?',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(
              'Pick the folder once. Everything you save goes there, and any '
              'audio you drop in with a file manager shows up here too. Your '
              'files and playlists stay on the phone even if you uninstall.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'The folder is fixed once you pick it — change it later in '
                    'Settings.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ]),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: busy ? null : () => _choose(preferDefault: true),
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.folder_special_outlined),
              label: Text(busy ? 'Opening…' : 'Use default folder'),
            ),
            const SizedBox(height: 4),
            Text(
              'Downloads/$defaultSaveFolderName',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : () => _choose(),
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose another folder'),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Later'),
            ),
          ],
        ),
      ),
    );
  }
}
