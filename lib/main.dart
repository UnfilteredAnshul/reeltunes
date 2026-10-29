import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_intent/receive_intent.dart' as ri;

import 'library.dart';
import 'models.dart';
import 'sheets.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Media-session service: lock screen / notification / system media widgets.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.reeltune.app.reel_tune.playback',
    androidNotificationChannelName: 'ReelTune playback',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
  );
  // lazy starter: app opens instantly, store init notifies when ready
  runApp(const ReelTuneApp());
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
      title: 'ReelTune',
      debugShowCheckedModeBanner: false,
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // FIRST-RUN ONLY — fires once after install, never every day.
      await AppStore.I.init();
      _listenShareIntents();
      if (AppStore.I.firstRunDone || AppStore.I.saveFolder.isNotEmpty) {
        return;
      }
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const FirstRunDialog(),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const LibraryScreen();

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
      title: const Text('Where should ReelTune save your audios?'),
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
