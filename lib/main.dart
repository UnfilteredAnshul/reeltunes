import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_intent/receive_intent.dart' as ri;

import 'library.dart';
import 'error_report.dart';
import 'models.dart';
import 'player.dart';
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
      if (AppStore.I.saveFolder.isEmpty) {
        // compute default for the first-run prompt
        final docs = await getApplicationDocumentsDirectory();
        _defaultDocsPath = docs.path; // kept for fallback writes
      }
      if (mounted) setState(() => ready = true);
    });
  }

  String? _defaultDocsPath;

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

class _RootScreenState extends State<RootScreen> {
  bool ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sw = Stopwatch()..start();
      const minSplash = Duration(milliseconds: 1400);
      await Future.wait([
        AppStore.I.init(),
        Future.delayed(minSplash), // coin must be visible, even briefly
      ]);
      _listenShareIntents();
      if (!mounted) return;
      if (!AppStore.I.firstRunDone && AppStore.I.saveFolder.isEmpty) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const FirstRunDialog(),
        );
      }
      if (mounted) setState(() => ready = true);
    });
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

class FirstRunDialog extends StatefulWidget {
  const FirstRunDialog({super.key});
  @override
  State<FirstRunDialog> createState() => _FirstRunDialogState();
}

class _FirstRunDialogState extends State<FirstRunDialog> {
  final nameCtrl =
      TextEditingController(text: defaultSaveFolderName);
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Where should ReelTunes save your audios?'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
            'Default: Downloads/ReelTune Audios (created on first save). '
            'You can change this any time in Settings.'),
        const SizedBox(height: 12),
        TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
              labelText: 'Folder name'),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () async {
            // best-effort pre-create on the device volume; graceful if denied
            try {
              Directory(
                      '/storage/emulated/0/Download/$defaultSaveFolderName')
                  .createSync(recursive: true);
            } catch (_) {}
            AppStore.I.completeFirstRun(
                '/storage/emulated/0/Download/$defaultSaveFolderName');
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Use default'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Choose another folder'),
        ),
      ],
    );
  }
}
