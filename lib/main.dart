import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:receive_intent/receive_intent.dart' as ri;

import 'ads.dart';
import 'billing.dart';
import 'coins.dart';
import 'consent.dart';
import 'cover_art.dart';
import 'entitlements.dart';
import 'error_report.dart';
import 'library.dart';
import 'library_sync.dart';
import 'models.dart';
import 'notification_service.dart';
import 'player.dart';
import 'promo.dart';
import 'settings_screen.dart';
import 'sheets.dart';
import 'top_toast.dart';
import 'home_screen.dart';

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
    // Rebuild on every AppStore change: themeMode lives there, and switching
    // light/dark from Settings must apply immediately (no relaunch).
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
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
          // Auto-hiding navigation bars report a smaller `padding.bottom`
          // than `viewPadding.bottom` while they are off-screen. Bottom
          // sheets and the player then render underneath the bar when it
          // slides back in. Keep the larger of the two as the safe inset.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final bottom = mq.padding.bottom > mq.viewPadding.bottom
                ? mq.padding.bottom
                : mq.viewPadding.bottom;
            if (bottom == mq.padding.bottom) return child!;
            return MediaQuery(
              data: mq.copyWith(
                padding: mq.padding.copyWith(bottom: bottom),
              ),
              child: child!,
            );
          },
          home: const RootScreen(),
        );
      },
    );
  }

  ThemeData _theme(Brightness b) {
    final base =
        ColorScheme.fromSeed(seedColor: kNeonBlue, brightness: b);
    final scheme = b == Brightness.dark
        ? base.copyWith(
            primary: kNeonBlue,
            onPrimary: Colors.white,
            secondary: const Color(0xFF22D3EE),
            onSecondary: Colors.black,
            surface: const Color(0xFF070A12),
            onSurface: const Color(0xFFE8EEFB),
            surfaceContainerHighest: const Color(0xFF161D2E),
            surfaceContainerHigh: const Color(0xFF111726),
          )
        : base.copyWith(
            primary: kNeonBlue,
            onPrimary: Colors.white,
            secondary: const Color(0xFF0891B2),
            surface: const Color(0xFFF7FAFF),
            surfaceContainerHighest: const Color(0xFFE7EEFB),
          );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen>
    with WidgetsBindingObserver {
  bool ready = false;
  int _selectedIndex = 0;
  bool _relinkPromptShown = false;

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
        CoinWallet.I.init(),
        Future.delayed(minSplash), // coin must be visible, even briefly
      ]);
      // Legal gate first: the Privacy Policy / Terms agreement is required
      // before anything imports or plays. On a reinstall the durable record in
      // Download/ReelTunes/consent.json is found and the user confirms again.
      await ConsentService.I.load();
      if (!mounted) return;
      if (ConsentService.I.needsAgreement) {
        await showConsentDialog(context);
        if (!mounted) return;
      }
      // Load the audios folder grant, restore a mirror after a reinstall and
      // pick up anything dropped in with a file manager.
      await LibrarySync.init();
      // Configure RevenueCat before ads start loading, so ad events are
      // reported to RevenueCat Charts. Ads load in the background and never
      // block the splash.
      await Billing.I.init();
      // AdMob + UMP consent warm up in the background: the free-tier banner
      // waits for `Ads.I.ready`, so the splash never blocks on the ad SDK.
      unawaited(Ads.I.init());
      // Notification service: scheduled perk / Pro expiry alerts.
      unawaited(NotificationService.I.init());
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
      // Folder is set up: ask once whether to start the 7-day trial or stay
      // free. Choosing free permanently forfeits the trial.
      await _maybeTrialChoice();
      // A folder whose grant was dropped makes every audio unplayable; ask for
      // the same folder right away instead of failing on the first tap.
      unawaited(_maybePromptRelink());
      // A code the owner switched off must stop paying for Pro, even if this
      // install redeemed it days ago.
      unawaited(PromoEngine.I.syncGrantEffects());
      // App-open ad (Free only, max once per 4 h). It waits briefly for the
      // preloaded unit and silently gives up when there is no fill.
      unawaited(Ads.I.maybeShowAppOpen());
      // 3-day / 1-day nudge, once each. Never stacked on the first-run sheet.
      if (AppStore.I.audiosLinked) _maybeTrialReminder();
    });
  }

  /// One-tap repair for a lapsed SAF grant. Android drops the persisted folder
  /// permission on reinstall, a system permission reset or an OEM clean-up;
  /// the library then shows every audio but none of them can be opened. Asking
  /// for the same folder again restores the grant and the rescan rewrites all
  /// stored paths. Shown at most once per session unless the user declines.
  Future<void> _maybePromptRelink() async {
    if (_relinkPromptShown || !mounted) return;
    if (!AppStore.I.folderAccessLost) return;
    _relinkPromptShown = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Reconnect your audios folder'),
        content: const Text(
            'Android reset access to your ReelTunes folder. Your audios are '
            'still on your phone — reconnect the same folder to play them '
            'again.\n\nYour playlists and settings are saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Reconnect'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (go != true) {
      _relinkPromptShown = false; // allow the next scan to ask again
      return;
    }
    final picked = await LibrarySync.link(preferDefault: true);
    if (!mounted) return;
    if (picked != null && picked.linked) {
      showTopToast(context, 'Folder reconnected');
    } else {
      _relinkPromptShown = false;
    }
  }

  /// Shows the trial-ending sheet when one is due and marks it as seen.
  Future<void> _maybeTrialReminder() async {
    final due = Entitlements.I.dueTrialReminder;
    if (due == null || !mounted) return;
    await Entitlements.I.markReminderShown(due);
    if (!mounted) return;
    await showTrialReminderSheet(context, due);
  }

  /// One-time "trial or free?" choice after the audios folder is set up.
  Future<void> _maybeTrialChoice() async {
    if (!mounted) return;
    if (AppStore.I.audiosLinked == false) return;
    if (!Entitlements.I.trialDecisionNeeded) return;
    await showTrialChoiceSheet(context);
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
        await _maybeTrialChoice();
        await _maybePromptRelink();
        await PromoEngine.I.syncGrantEffects();
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
    if (!ready) return const _SplashScreen();
    final scheme = Theme.of(context).colorScheme;
    void openLibrary({bool playlists = false}) {
      if (playlists) AppStore.I.setPlaylistsExpanded(true);
      setState(() => _selectedIndex = 1);
    }

    final screens = [
      HomeScreen(
        onOpenLibrary: openLibrary,
        onOpenPlaylists: () => openLibrary(playlists: true),
      ),
      const LibraryScreen(),
      SearchScreen(active: _selectedIndex == 2),
      const SettingsScreen(),
    ];
    return Scaffold(
      backgroundColor: scheme.surface,
      // The mesh background lives behind every tab; each tab's own Scaffold is
      // transparent so the art shows through instead of a dead black field.
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _AppBackground(),
          IndexedStack(index: _selectedIndex, children: screens),
        ],
      ),
      // Sticky ad slot + always-mounted mini player stay above the nav bar on
      // every tab, so the free-tier banner has a fixed anchor and playback
      // controls are one tap away from anywhere.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AdBanner(),
          const MiniBar(),
          BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: (i) => setState(() => _selectedIndex = i),
            type: BottomNavigationBarType.fixed,
            selectedItemColor: kNeonBlue,
            unselectedItemColor: scheme.onSurfaceVariant,
            backgroundColor: scheme.surface,
            elevation: 0,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.library_music_outlined),
                activeIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.search),
                activeIcon: Icon(Icons.search),
                label: 'Search',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings_outlined),
                activeIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
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
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => AddReelSheet(initialUrl: match),
    );
  }
}

/// Search across every audio and playlist, independent of the library filters.
class SearchScreen extends StatefulWidget {
  /// True while this tab is the selected one. The field takes focus (and the
  /// keyboard opens) as soon as the user taps Search in the nav bar.
  final bool active;
  const SearchScreen({super.key, this.active = false});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  String _q = '';

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      // Nav tap: open the keyboard straight away, no second tap needed.
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit(String value) {
    if (value.trim().isEmpty) return;
    AppStore.I.addRecentSearch(value);
  }

  void _use(String term) {
    _ctrl.text = term;
    _ctrl.selection = TextSelection.collapsed(offset: term.length);
    setState(() => _q = term);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final scheme = Theme.of(context).colorScheme;
    final q = _q.trim().toLowerCase();

    final folders = q.isEmpty
        ? <Folder>[]
        : store.folders
            .where((f) => f.name.toLowerCase().contains(q))
            .toList();
    final tracks = q.isEmpty
        ? <Track>[]
        : store.tracks
            .where((t) =>
                t.title.toLowerCase().contains(q) ||
                t.source.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      // Transparent so RootScreen's mesh background shows through.
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: const Text('Search',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(14),
                // Same neon hairline + glow as the "First time here?" card, so
                // the field never disappears into the mesh background.
                border: Border.all(color: kNeonBlue.withValues(alpha: 0.55)),
                boxShadow: [
                  BoxShadow(
                    color: kNeonBlue.withValues(alpha: 0.26),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _q = v),
                onSubmitted: _commit,
                decoration: InputDecoration(
                  hintText: 'Search audios and playlists',
                  hintStyle:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                  prefixIcon: Icon(Icons.search,
                      color: scheme.onSurfaceVariant, size: 20),
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.clear,
                              color: scheme.onSurfaceVariant, size: 20),
                          onPressed: () {
                            _ctrl.clear();
                            setState(() => _q = '');
                            _focus.requestFocus();
                          },
                        ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
          Expanded(
            child: q.isEmpty
                ? _emptyHint(scheme, store.tracks.isEmpty)
                : (folders.isEmpty && tracks.isEmpty)
                    ? _noResults(scheme, _q.trim())
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          if (folders.isNotEmpty) ...[
                            _sectionLabel(context, 'Playlists'),
                            for (final f in folders)
                              ListTile(
                                leading: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: scheme.surfaceContainerHighest,
                                  ),
                                  child: Icon(Icons.queue_music,
                                      color: scheme.onSurfaceVariant),
                                ),
                                title: Text(f.name),
                                subtitle: Text(
                                  '${store.tracks.where((t) => t.folderIds.contains(f.id)).length} audios',
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                                onTap: () {
                                  _commit(_q);
                                  store.selectFolder(f.id);
                                  if (!store.playlistsExpanded) {
                                    store.togglePlaylists();
                                  }
                                },
                              ),
                          ],
                          if (tracks.isNotEmpty) ...[
                            _sectionLabel(context, 'Audios'),
                            for (final t in tracks)
                              TrackTile(
                                track: t,
                                all: tracks,
                                onTap: () {
                                  _commit(_q);
                                  RtPlayer.I.play(t,
                                      context: tracks, playingFrom: 'Search');
                                },
                              ),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );

  Widget _emptyHint(ColorScheme scheme, bool noMusic) {
    if (noMusic) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                'Nothing to search yet. Add a reel first.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    final recent = AppStore.I.recentSearches;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        if (recent.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text('Recent searches',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              ),
              TextButton(
                onPressed: AppStore.I.clearRecentSearches,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('Clear', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final term in recent)
                ActionChip(
                  label: Text(term,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                  avatar: Icon(Icons.history,
                      size: 15, color: scheme.onSurfaceVariant),
                  onPressed: () => _use(term),
                ),
            ],
          ),
          const SizedBox(height: 22),
        ],
        Text('Type a name to search your audios and playlists.',
            style: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                fontSize: 13)),
      ],
    );
  }

  Widget _noResults(ColorScheme scheme, String q) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No matches for "$q".',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14)),
        ),
      );
}

/// Deep blue sound-wave art behind every tab. A scrim on top keeps text
/// readable over the brightest part of the art; light mode gets a lighter veil
/// instead.
class _AppBackground extends StatelessWidget {
  const _AppBackground();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/background.webp',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? const [
                      Color(0x73070A12), // 45% at the header
                      Color(0xA6070A12), // 65% through the lists
                      Color(0xCC070A12), // 80% at the nav bar
                    ]
                  : const [
                      Color(0xB8F7FAFF),
                      Color(0xE6F7FAFF),
                    ],
              stops: dark ? const [0.0, 0.45, 1.0] : null,
            ),
          ),
        ),
      ],
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
