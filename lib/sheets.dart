// Shared bottom sheets: Add reel + player. Emoji picker is its own file.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'emoji.dart';
import 'extractor.dart';
import 'library.dart';
import 'models.dart';
import 'player.dart';

// ---------------------------------------------------------------------------
// Add reel / extraction intake
// ---------------------------------------------------------------------------

class AddReelSheet extends StatefulWidget {
  final String? initialUrl;
  const AddReelSheet({super.key, this.initialUrl});
  @override
  State<AddReelSheet> createState() => _AddReelSheetState();
}

enum _ExtractionState { idle, running, done }

class _AddReelSheetState extends State<AddReelSheet> {
  final urlCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  String? pickedFolderId;
  _ExtractionState state = _ExtractionState.idle;
  String status = '';

  bool get working => state == _ExtractionState.running;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null) urlCtrl.text = widget.initialUrl!;
  }

  @override
  Widget build(BuildContext context) {
    // Keep the form above the keyboard + reactive to store (folder list).
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListenableBuilder(
        listenable: AppStore.I,
        builder: (context, _) => Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(context),
              _body(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(BuildContext context) {
    return Text('Add a reel',
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontWeight: FontWeight.w600));
  }

  Widget _body(BuildContext context) {
    const gap = SizedBox(height: 16);
    if (working) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 12),
          Text(status, textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
    }
    if (state == _ExtractionState.done) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
            child: Icon(Icons.check_circle_outline, size: 44,
                color: Color(0xFF0A8F5B))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        gap,
        TextField(
          controller: urlCtrl,
          enabled: !working,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://vt.tiktok.com/…',
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: nameCtrl,
          enabled: !working,
          decoration: const InputDecoration(
            hintText: 'Title (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text('Folder:'),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String?>(
              initialValue: pickedFolderId,
              hint: const Text('📁 ReelTune Audios (root)'),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('📁 ReelTune Audios (root)')),
                ...AppStore.I.folders
                    .map((f) => DropdownMenuItem(
                        value: f.id, child: Text('${f.emoji} ${f.name}'))),
                const DropdownMenuItem(
                    value: '__new__', child: Text('➕ New folder…')),
              ],
              onChanged: (v) {
                if (v == '__new__') {
                  showFolderCreate(context);
                  return;
                }
                setState(() => pickedFolderId = v);
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => showFolderCreate(context),
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ]),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: importAudioFile,
          icon: const Icon(Icons.folder_open),
          label: const Text('Or import an audio file instead'),
        ),
        const SizedBox(height: 4),
        FilledButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: const Text('Extract & save audio'),
          onPressed: _extract,
        ),
      ],
    );
  }

  Future<void> _extract() async {
    final url = urlCtrl.text.trim();
    if (url.isEmpty || working) return;
    setState(() {
      state = _ExtractionState.running;
      status = 'Preparing engine…';
    });

    final title =
        nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : null;

    try {
      final t = await Extractor.extractAndAdd(AppStore.I, url,
          title: title,
          folderIds: [if (pickedFolderId != null) pickedFolderId!],
          onStatus: (s) => setState(() => status = s));
      if (!mounted) return;
      setState(() => state = _ExtractionState.done);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.pop(context);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved "${t.title}" to library'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      debugPrint('extraction failed: $e');
      final failedUrl = url;
      if (!mounted) return;
      setState(() => state = _ExtractionState.idle);
      // DEV PHASE: surface the raw technical error instead of the polished
      // fallback so we can see what the engine actually says. The wrapper
      // handoff (_onExtractionFailed) is commented out, not deleted.
      final msg = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg.length > 300 ? '${msg.substring(0, 300)}…' : msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 12),
      ));
      // TODO(dev-phase-over): restore the user-facing fallback:
      // Navigator.pop(context);
      // _onExtractionFailed(failedUrl);
    }
  }

  /// Shown whenever in-app extraction can't deliver: route to the web
  /// wrapper (pre-filled link) or import a file picked on-device.
  Future<void> _onExtractionFailed(String url) async {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('In-app extraction failed for this link.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text(
                'Platform blocked it. Two workarounds:',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Open the downloader website'),
                onPressed: () {
                  Navigator.pop(sheetCtx);
                  launchUrl(
                    Uri.parse(
                        '$fallbackWebsiteUrl${Uri.encodeComponent(url)}'),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('Import the audio file instead'),
                onPressed: () async {
                  Navigator.pop(sheetCtx);
                  await importAudioFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    urlCtrl.dispose();
    nameCtrl.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Folder creation with emoji
// ---------------------------------------------------------------------------

/// Opens the create-folder sheet. Bottom sheet (not dialog) — dialogs were
/// showing only the scrim on the ColorOS device, sheets render reliably.
void showFolderCreate(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: const FolderCreateSheet(),
    ),
  );
}

class FolderCreateSheet extends StatefulWidget {
  const FolderCreateSheet({super.key});
  @override
  State<FolderCreateSheet> createState() => _FolderCreateSheetState();
}

class _FolderCreateSheetState extends State<FolderCreateSheet> {
  final name = TextEditingController();
  String emoji = '📁';
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New folder',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: name,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _create(),
            decoration: const InputDecoration(
                hintText: 'e.g. Motivation, Edits…', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: emojiPalette
                  .map((e) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: InkWell(
                          onTap: () => setState(() => emoji = e),
                          child: Text(e,
                              style:
                                  TextStyle(fontSize: emoji == e ? 26 : 20)),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _create() {
    final n = name.text.trim();
    if (n.isEmpty) return;
    AppStore.I.addFolder(n, emoji);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Input sheet (rename etc.) + multi-folder picker sheet
// ---------------------------------------------------------------------------

/// Text-input bottom sheet (dialogs misrender on this ColorOS device).
Future<String?> showInputSheet(
  BuildContext context, {
  required String title,
  required TextEditingController controller,
  required String confirmLabel,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment:
            CrossAxisAlignment.stretch, children: [
          Text(title,
              style: Theme.of(sheetCtx)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.pop(sheetCtx, v.trim()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(sheetCtx, controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ]),
      ),
    ),
  );
}

/// Multi-select folder membership for a track. Save applies the full set.
Future<void> showFolderPick(BuildContext context, Track t) {
  final picked = {for (final id in t.folderIds) id};
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment:
            CrossAxisAlignment.stretch, children: [
          Text('Choose folders',
              style: Theme.of(sheetCtx)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('"${t.title}" can live in several folders at once.',
              style: Theme.of(sheetCtx).textTheme.bodySmall),
          const SizedBox(height: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(shrinkWrap: true, children: [
                if (AppStore.I.folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No folders yet — create one first.'),
                  ),
                for (final f in AppStore.I.folders)
                  CheckboxListTile(
                    value: picked.contains(f.id),
                    onChanged: (v) => setSheetState(() =>
                        v == true ? picked.add(f.id) : picked.remove(f.id)),
                    title: Text('${f.emoji} ${f.name}'),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              AppStore.I.setTrackFolders(t.id, picked.toList());
              Navigator.pop(sheetCtx);
            },
            child: const Text('Save'),
          ),
        ]),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Player sheet
// ---------------------------------------------------------------------------

class PlayerSheet extends StatefulWidget {
  final Track track;
  final List<Track> contextTracks;
  const PlayerSheet(
      {super.key, required this.track, required this.contextTracks});
  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await RtPlayer.I.play(widget.track, context: widget.contextTracks);
      final t = AppStore.I.trackById(widget.track.id);
      if (t != null && t.durationMs == 0 && RtPlayer.I.duration != null) {
        AppStore.I
            .updateTrackDuration(widget.track.id, RtPlayer.I.duration!.inMilliseconds);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: RtPlayer.I,
      builder: (context, _) {
        final player = RtPlayer.I;
        final t = player.current ?? widget.track;
        final dur = player.duration?.inMilliseconds ?? t.durationMs;
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text('from ${t.source} · audio only',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (context, snap) {
                  final posD = snap.data ?? Duration.zero;
                  final frac = dur > 0 ? posD.inMilliseconds / dur : 0.0;
                  return Column(children: [
                    Slider(
                      value: frac.clamp(0.0, 1.0),
                      onChanged: (v) => player.seek(v),
                    ),
                    Row(children: [
                      Text(mmss(posD.inMilliseconds),
                          style: Theme.of(context).textTheme.labelSmall),
                      const Spacer(),
                      Text(mmss(dur),
                          style: Theme.of(context).textTheme.labelSmall),
                    ]),
                  ]);
                },
              ),
              const SizedBox(height: 8),
              Text('Advanced Looping',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _LoopChip(
                      label: 'Smart (auto)',
                      selected: player.loop == RtLoop.smart,
                      onTap: () => player.setLoop(RtLoop.smart),
                    ),
                    const SizedBox(width: 4),
                    _LoopChip(
                      label:
                          'Custom range (${AppStore.I.rangeMin}-${AppStore.I.rangeMax}x)',
                      selected: player.loop == RtLoop.customRange,
                      onTap: _openRangePicker,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                      iconSize: 32,
                      onPressed: () {},
                      icon: const Icon(Icons.shuffle_outlined)),
                  IconButton(
                      iconSize: 40,
                      onPressed: () => player.skipPrev(),
                      icon: const Icon(Icons.skip_previous_rounded)),
                  Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: scheme.primary),
                    child: IconButton(
                      color: scheme.onPrimary,
                      iconSize: 38,
                      onPressed: () => player.toggle(),
                      icon: Icon(player.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded),
                    ),
                  ),
                  IconButton(
                      iconSize: 40,
                      onPressed: () => player.skipNext(),
                      icon: const Icon(Icons.skip_next_rounded)),
                  IconButton(
                      iconSize: 32,
                      onPressed: () {},
                      icon: const Icon(Icons.repeat)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Custom-range editor: two steppers (min/max loops per track), 3-5 default,
  /// persisted via AppStore and applied to the player immediately.
  Future<void> _openRangePicker() async {
    final store = AppStore.I;
    final minCtrl = TextEditingController(text: '${store.rangeMin}');
    final maxCtrl = TextEditingController(text: '${store.rangeMax}');
    final picked = await showDialog<(int, int)?>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Custom loop range'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RangeStepper(label: 'Min loops', controller: minCtrl),
                  const SizedBox(height: 12),
                  _RangeStepper(label: 'Max loops', controller: maxCtrl),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                  onPressed: () {
                    final lo = int.tryParse(minCtrl.text) ?? 3;
                    final hi = int.tryParse(maxCtrl.text) ?? 5;
                    Navigator.pop(
                        ctx, (lo.clamp(1, 999), hi.clamp(1, 999)));
                  },
                  child: const Text('Apply'),
                ),
              ],
            ));
    if (picked != null) {
      var (lo, hi) = picked;
      if (hi < lo) hi = lo;
      store.setRangeMin(lo);
      store.setRangeMax(hi);
      RtPlayer.I.setLoop(RtLoop.customRange);
      if (mounted) setState(() {});
    }
  }
}

// ---------------------------------------------------------------------------
// Advanced-looping widgets
// ---------------------------------------------------------------------------

class _LoopChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LoopChip(
      {super.key, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) => onTap(),
        selectedColor: scheme.primaryContainer,
      ),
    );
  }
}

class _RangeStepper extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  const _RangeStepper({super.key, required this.label, required this.controller});

  void _bump(int delta) {
    final v = (int.tryParse(controller.text) ?? 3) + delta;
    controller.text = v.clamp(1, 999).toString();
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label),
        ),
      ),
      IconButton(onPressed: () => _bump(-1), icon: const Icon(Icons.remove)),
      IconButton(onPressed: () => _bump(1), icon: const Icon(Icons.add)),
    ]);
  }
}
