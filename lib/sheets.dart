// Shared bottom sheets: Add reel + player. Emoji picker is its own file.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'billing.dart';
import 'emoji.dart';
import 'entitlements.dart';
import 'extraction_errors.dart';
import 'extractor.dart';
import 'library.dart';
import 'models.dart';
import 'player.dart';
import 'top_toast.dart';

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
  /// Multi-select folder membership; empty set = track lives in "All".
  /// Choosing a category here is optional by design.
  final pickedFolders = <String>{};
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
        Text('Add to playlists (optional. None = shows in All)',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 176),
          child: ListView(shrinkWrap: true, children: [
            if (AppStore.I.folders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No playlists yet. Create one below.'),
              ),
            for (final f in AppStore.I.folders)
              CheckboxListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                value: pickedFolders.contains(f.id),
                onChanged: (v) => setState(() => v == true
                    ? pickedFolders.add(f.id)
                    : pickedFolders.remove(f.id)),
                title: Text('${f.emoji} ${f.name}'),
              ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New playlist'),
              onTap: () => showFolderCreate(context),
            ),
          ]),
        ),
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
    if (!AppStore.I.audiosLinked) {
      showTopToast(context, 'Link your audios folder first (Settings).');
      return;
    }
    // Check the cap before the engine runs: never download a file the library
    // is not allowed to list.
    if (Entitlements.I.importBlockReason(AppStore.I.tracks.length) != null) {
      showPaywallSheet(context, reason: 'Free tier holds 25 audios');
      return;
    }
    setState(() {
      state = _ExtractionState.running;
      status = 'Preparing engine…';
    });

    final title =
        nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : null;

    try {
      final t = await Extractor.extractAndAdd(AppStore.I, url,
          title: title,
          folderIds: pickedFolders.toList(),
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
      // Log keeps both the raw engine text and the readable guess so the
      // failure can be diagnosed without showing it to the user.
      debugPrint('extraction failed: $e');
      debugPrint('extraction reason: ${friendlyExtractionError(e)}');
      final failedUrl = url;
      if (!mounted) return;
      setState(() => state = _ExtractionState.idle);
      showTopToast(context, "Can't download this one. Try another link.");
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
/// Returns the completion future so a stacked sheet can await it.
Future<void> showFolderCreate(BuildContext context) {
  // Free tier tops out at 2 playlists; the 3rd opens the paywall instead of a
  // dead "create" sheet. Restoring a lapsed account never deletes playlists.
  if (!Entitlements.I.canAddPlaylist(AppStore.I.folders.length)) {
    showPaywallSheet(context, reason: 'Free holds 2 playlists');
    return Future.value();
  }
  return showModalBottomSheet(
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
  /// Random default: when the user doesn't pick an emoji the app drops one
  /// on them — the "every folder has an emoji" rule is satisfied from the
  /// moment the sheet opens (they can still tap a different one).
  String emoji = emojiPalette[Random().nextInt(emojiPalette.length)];
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New playlist',
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
          Text('Choose playlists',
              style: Theme.of(sheetCtx)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('"${t.title}" can live in several playlists at once.',
              style: Theme.of(sheetCtx).textTheme.bodySmall),
          const SizedBox(height: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(shrinkWrap: true, children: [
                if (AppStore.I.folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No playlists yet. Create one first.'),
                  ),
                for (final f in AppStore.I.folders)
                  CheckboxListTile(
                    value: picked.contains(f.id),
                    onChanged: (v) => setSheetState(() =>
                        v == true ? picked.add(f.id) : picked.remove(f.id)),
                    title: Text('${f.emoji} ${f.name}'),
                  ),
                // Manage-folders doubles as a creation point: open the
                // create-folder sheet ON TOP of this one, refresh when done.
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('New playlist'),
                  onTap: () async {
                    await showFolderCreate(sheetCtx);
                    setSheetState(() {});
                  },
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
// Folder menu + emoji editor
// ---------------------------------------------------------------------------

enum _FolderMenuAction { rearrange, shuffle, rename, editEmoji, delete }

/// Long-press menu on a category: shuffle / rename / edit emoji / delete.
/// [allowRearrange] is grid-only — grid drags are gated behind that explicit
/// mode so dragging and tapping stop fighting each other.
Future<void> showFolderMenu(BuildContext context, Folder f,
    {bool allowRearrange = false}) async {
  final action = await showModalBottomSheet<_FolderMenuAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (allowRearrange)
          ListTile(
            leading: const Icon(Icons.swap_vert_rounded),
            title: const Text('Rearrange'),
            subtitle: const Text('Drag the cards into place, then Save',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(sheetCtx, _FolderMenuAction.rearrange),
          ),
        ListTile(
          leading: const Icon(Icons.shuffle_outlined),
          title: const Text('Shuffle'),
          onTap: () => Navigator.pop(sheetCtx, _FolderMenuAction.shuffle),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Rename'),
          onTap: () => Navigator.pop(sheetCtx, _FolderMenuAction.rename),
        ),
        ListTile(
          leading: const Icon(Icons.emoji_emotions_outlined),
          title: const Text('Edit emoji'),
          onTap: () => Navigator.pop(sheetCtx, _FolderMenuAction.editEmoji),
        ),
        ListTile(
          leading: Icon(Icons.delete_outline,
              color: Theme.of(sheetCtx).colorScheme.error),
          title: Text('Delete',
              style: TextStyle(
                  color: Theme.of(sheetCtx).colorScheme.error,
                  fontWeight: FontWeight.w600)),
          onTap: () => Navigator.pop(sheetCtx, _FolderMenuAction.delete),
        ),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;
  final store = AppStore.I;
  switch (action) {
    case _FolderMenuAction.rearrange:
      store.startArranging(folders: true);
    case _FolderMenuAction.shuffle:
      final list =
          store.tracks.where((t) => t.folderIds.contains(f.id)).toList();
      if (list.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"${f.name}" has no audios yet'),
          behavior: SnackBarBehavior.floating,
        ));
      } else {
        list.shuffle(); // random entry point, then the player shuffles too
        await RtPlayer.I.play(list.first,
            context: list, playingFrom: f.name);
        if (!context.mounted) return;
        // Bring the player up so the user sees what's playing.
        await showModalBottomSheet(
          context: context,
          showDragHandle: true,
          useSafeArea: true,
          builder: (_) => PlayerSheet(
            track: list.first,
            contextTracks: const [], // queue already built; sheet renders only
            startPlayback: false,
          ),
        );
      }
    case _FolderMenuAction.rename:
      final ctrl = TextEditingController(text: f.name);
      if (!context.mounted) return;
      final name = await showInputSheet(
        context,
        title: 'Rename playlist',
        controller: ctrl,
        confirmLabel: 'Rename',
      );
      if (name != null && name.isNotEmpty) store.renameFolder(f.id, name);
    case _FolderMenuAction.editEmoji:
      if (!context.mounted) return;
      final emoji = await showEmojiPickerSheet(context);
      if (emoji != null) store.setFolderEmoji(f.id, emoji);
    case _FolderMenuAction.delete:
      final ok = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (sheetCtx) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment:
              CrossAxisAlignment.stretch, children: [
            Text('Delete "${f.name}"?',
                style: const TextStyle(fontWeight: FontWeight.w600,
                    fontSize: 18)),
            const SizedBox(height: 8),
            Text('Your audios stay in the library. Only the playlist goes '
                'away.',
                style: Theme.of(sheetCtx).textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(children: [
              TextButton(
                  onPressed: () => Navigator.pop(sheetCtx, false),
                  child: const Text('Cancel')),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(sheetCtx).colorScheme.error,
                    foregroundColor: Theme.of(sheetCtx).colorScheme.onError),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete playlist'),
                onPressed: () => Navigator.pop(sheetCtx, true),
              ),
            ]),
          ]),
        ),
      );
      if (ok == true) store.deleteFolder(f.id);
  }
}

// ---------------------------------------------------------------------------
// Guide
// ---------------------------------------------------------------------------

/// Plain-language tour of the app. Opened from Settings and from the bar on
/// the home screen, so both entry points show the same thing.
Future<void> showGuideSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.82),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: const [
          Text('How ReelTunes works',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          SizedBox(height: 4),
          Text('No account needed. Your audios stay on this phone.'),
          SizedBox(height: 20),
          _GuideStep(
            Icons.link_rounded,
            'Add from a link',
            'Open the reel, tap Share, then pick ReelTunes. Or copy the link '
                'and paste it into Add reel.',
          ),
          _GuideStep(
            Icons.folder_open_rounded,
            'Already have a file?',
            'Tap the folder button. Pick a song or a video, or a whole folder. '
                'Videos play as audio. Nothing gets copied.',
          ),
          _GuideStep(
            Icons.playlist_add_rounded,
            'Make a playlist',
            'Tap New playlist and give it a name. Tap its chip at the top to '
                'see only those songs. Tap All to see everything again.',
          ),
          _GuideStep(
            Icons.search_rounded,
            'Find a song',
            'Tap the magnifier on the top bar and type part of the name.',
          ),
          _GuideStep(
            Icons.tune_rounded,
            'Sort and filter',
            'Tap the sliders button. Sort on the left, date filter on the '
                'right. You can use one or both.',
          ),
          _GuideStep(
            Icons.play_circle_outline_rounded,
            'Play',
            'Tap a song to start. Tap the bar at the bottom for the full '
                'player. Press and hold a song to rename, move, remove or '
                'delete it.',
          ),
          _GuideStep(
            Icons.folder_rounded,
            'Your files stay yours',
            'Everything you save sits in the audios folder. Drop a song in '
                'with a file manager and it shows up here. Reinstall the app, '
                'link the same folder, and your playlists come back.',
          ),
          SizedBox(height: 4),
          Text('You can open this guide again from Settings.',
              style: TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}

class _GuideStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _GuideStep(this.icon, this.title, this.body);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(body,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.4)),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Emoji picker sheet for folder icons.
Future<String?> showEmojiPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment:
          CrossAxisAlignment.start, children: [
        Text('Pick an emoji',
            style: Theme.of(sheetCtx)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in emojiPalette)
              InkWell(
                onTap: () => Navigator.pop(sheetCtx, e),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Theme.of(sheetCtx)
                        .colorScheme
                        .surfaceContainerHighest
                        .withAlpha(120),
                  ),
                  child: Text(e, style: const TextStyle(fontSize: 24)),
                ),
              ),
          ],
        ),
      ]),
    ),
  );
}

// ---------------------------------------------------------------------------
// Player sheet
// ---------------------------------------------------------------------------

class PlayerSheet extends StatefulWidget {
  final Track track;
  final List<Track> contextTracks;
  /// False when playback (and queue building) is already running — e.g.
  /// shuffle-played straight from the folder menu. initState then only
  /// renders, it never re-issues play().
  final bool startPlayback;
  const PlayerSheet(
      {super.key,
      required this.track,
      required this.contextTracks,
      this.startPlayback = true});
  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  /// Same long-press menu as the library list, from the player's 3-dot button.
  /// If the action removes or deletes the track, the sheet has nothing left to
  /// show, so it closes.
  Future<void> _openTrackMenu(Track t) async {
    await showTrackMenu(context, t);
    if (!mounted) return;
    if (AppStore.I.trackById(t.id) == null) Navigator.pop(context);
  }

  @override
  void initState() {
    super.initState();
    if (!widget.startPlayback) return;
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
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                // Balances the 3-dot button so the caption stays centred.
                const SizedBox(width: 40),
                Expanded(
                  child: Text('playing from ${player.playingFrom}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ),
                IconButton(
                  tooltip: 'Track options',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _openTrackMenu(t),
                ),
              ]),
              const SizedBox(height: 4),
              Text(t.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text('from ${t.source}',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              // Duration MUST come from the engine stream: right after the
              // first play the total is briefly unknown, and reading
              // player.duration once left the sheet at 0:00 for the whole
              // track (it only corrected itself after a loop).
              StreamBuilder<Duration?>(
                stream: player.durationStream,
                initialData: player.duration,
                builder: (context, durSnap) {
                  final dur = durSnap.data?.inMilliseconds ?? t.durationMs;
                  return StreamBuilder<Duration>(
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
                  );
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
                      label: '✨ Smart (auto)',
                      selected: player.loop == RtLoop.smart,
                      onTap: () => player.setLoop(RtLoop.smart),
                    ),
                    const SizedBox(width: 4),
                    _LoopChip(
                      label:
                          'Custom range (${AppStore.I.rangeMin}-${AppStore.I.rangeMax}x)'
                          '${Entitlements.I.canUseCustomRange ? '' : ' · Pro'}',
                      selected: player.loop == RtLoop.customRange,
                      onTap: () {
                        if (!Entitlements.I.canUseCustomRange) {
                          showPaywallSheet(context,
                              reason: 'Custom loop range is Pro');
                          return;
                        }
                        _openRangePicker();
                      },
                    ),

                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Spotify-style state indication: active when ON (accent
                  // color). Shuffle is on by design; ∞ pairs with the chip.
                  IconButton(
                      iconSize: 32,
                      color: player.shuffleOn ? scheme.primary : null,
                      onPressed: () => player.toggleShuffle(),
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
                      // Engine-driven state + a real transition, so the
                      // glyph can never stay stuck on ▶ while audio plays.
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, anim) => ScaleTransition(
                          scale: anim,
                          child: FadeTransition(opacity: anim, child: child),
                        ),
                        child: Icon(
                          player.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(player.playing),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                      iconSize: 40,
                      onPressed: () => player.skipNext(),
                      icon: const Icon(Icons.skip_next_rounded)),
                  IconButton(
                      iconSize: 32,
                      color: player.loop == RtLoop.infinite
                          ? scheme.primary
                          : null,
                      onPressed: () => player.setLoop(
                          player.loop == RtLoop.infinite
                              ? RtLoop.smart
                              : RtLoop.infinite),
                      icon: Icon(player.loop == RtLoop.infinite
                          ? Icons.repeat_on
                          : Icons.repeat_outlined)),
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
    // Bottom sheet, never showDialog: this ColorOS device renders dialogs as
    // a bare scrim you can't interact with.
    final picked = await showModalBottomSheet<(int, int)?>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Custom loop range',
                  style: Theme.of(sheetCtx)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                'Each audio repeats a random number of times between Min and '
                'Max. Set both to the same number to repeat exactly that many '
                'times (3 – 3 = exactly 3 plays).',
                style: Theme.of(sheetCtx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              _RangeStepper(label: 'Min loops', controller: minCtrl),
              const SizedBox(height: 12),
              _RangeStepper(label: 'Max loops', controller: maxCtrl),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final lo = int.tryParse(minCtrl.text) ?? store.rangeMin;
                  final hi = int.tryParse(maxCtrl.text) ?? store.rangeMax;
                  Navigator.pop(
                      sheetCtx, (lo.clamp(1, 999), hi.clamp(1, 999)));
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (picked != null) {
      var (lo, hi) = picked;
      if (hi < lo) hi = lo;
      store.setRange(lo, hi);
      RtPlayer.I.setLoop(RtLoop.customRange);
      setState(() {});
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

// ---------------------------------------------------------------------------
// Free vs Pro: paywall + trial-ending reminders
// ---------------------------------------------------------------------------

/// The one paywall in the app. [reason] explains what the user just hit, so the
/// sheet never appears as an unprovoked ad.
Future<void> showPaywallSheet(BuildContext context, {String? reason}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetCtx) => _PaywallSheet(reason: reason),
  );
}

class _PaywallSheet extends StatefulWidget {
  final String? reason;
  const _PaywallSheet({this.reason});

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  /// `annual` by default: it is the better deal for the user and the better
  /// revenue for us, and both prices are on screen either way.
  String plan = 'annual';
  bool loading = true;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!Billing.I.configured) {
      // No store key in this build (sideload / dev). The sheet still works so
      // the whole flow is testable; release builds with a key never get here.
      if (mounted) setState(() => loading = false);
      return;
    }
    await Billing.I.loadOfferings();
    if (!mounted) return;
    setState(() => loading = false);
  }

  String _priceFor(String which) =>
      Billing.I.planView(which)?.priceString ??
      (which == 'annual' ? '₹3000 / year' : '₹399 / month');

  Future<void> _buy() async {
    if (busy) return;
    final e = Entitlements.I;

    // Already Pro: nothing to buy, just close.
    if (e.isPro) {
      Navigator.pop(context);
      return;
    }

    setState(() => busy = true);
    try {
      final available = Billing.I.planView(plan) != null;
      if (!Billing.I.configured || !available) {
        if (kDebugMode) {
          await Entitlements.I.setPurchased(true);
          if (!mounted) return;
          Navigator.pop(context);
          if (context.mounted) {
            showTopToast(context, 'Pro unlocked (debug build)');
          }
        } else if (context.mounted) {
          showTopToast(context, 'Pro isn\'t live yet — coming soon.', error: true);
        }
        return;
      }

      final report = await Billing.I.purchasePlan(plan);
      if (!mounted) return;
      if (report.ok) {
        Navigator.pop(context);
        if (context.mounted) showTopToast(context, 'Welcome to Pro · no ads');
      } else if (report.outcome == PurchaseOutcome.pending) {
        Navigator.pop(context);
        if (context.mounted) showTopToast(context, report.message ?? 'Pending');
      } else if (!report.quiet) {
        if (context.mounted) {
          showTopToast(context, report.message ?? 'Purchase failed', error: true);
        }
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final report = await Billing.I.restore();
      if (!mounted) return;
      if (report.ok) {
        Navigator.pop(context);
        if (context.mounted) showTopToast(context, 'Pro restored');
      } else if (context.mounted) {
        showTopToast(context, report.message ?? 'Nothing to restore',
            error: report.outcome != PurchaseOutcome.unavailable);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _manage() async {
    await launchUrl(Uri.parse(Billing.manageUrl),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final e = Entitlements.I;
    final alreadyPro = e.isPro;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(alreadyPro ? 'ReelTunes Pro' : 'Go Pro',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            if (widget.reason != null) ...[
              const SizedBox(height: 4),
              Text(widget.reason!,
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 14),
            for (final line in const [
              'Unlimited audios and playlists',
              'No ads, ever',
              'Custom loop range',
              'Smart looping that learns your counts',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(Icons.check_circle, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(line)),
                ]),
              ),
            const SizedBox(height: 14),
            if (alreadyPro)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(children: [
                  Text(e.statusLabel,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    e.willRenew
                        ? 'Renews automatically through Google Play.'
                        : 'No renewal scheduled. Pro stays until the date above.',
                    textAlign: TextAlign.center,
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ]),
              )
            else ...[
              _PlanCard(
                title: 'Yearly',
                price: _priceFor('annual'),
                // Play's own per-month number, so the comparison is honest.
                subtitle: Billing.I.annualSaving ??
                    Billing.I.planView('annual')?.perMonthString,
                badge: 'Best value',
                selected: plan == 'annual',
                onTap: () => setState(() => plan = 'annual'),
              ),
              const SizedBox(height: 8),
              _PlanCard(
                title: 'Monthly',
                price: _priceFor('monthly'),
                subtitle: 'Cancel anytime',
                selected: plan == 'monthly',
                onTap: () => setState(() => plan = 'monthly'),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (Billing.I.configured &&
                  !loading &&
                  Billing.I.planView('monthly') == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    Billing.I.lastError ??
                        'Prices are still being set up. Try again shortly.',
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                Billing.I.hasIntroTrial
                    ? '7 days free, then the price above. Cancel anytime in '
                        'Google Play — you keep Pro until the period ends.\n'
                        'Prices shown by Google Play for your country.'
                    : 'Billed through Google Play. Cancel anytime in Google '
                        'Play — you keep Pro until the period ends.\n'
                        'Prices shown by Google Play for your country.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 14),
            if (alreadyPro)
              FilledButton(
                onPressed: _manage,
                child: const Text('Manage subscription'),
              )
            else
              FilledButton(
                onPressed: busy ? null : _buy,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continue'),
              ),
            if (!alreadyPro && Billing.I.configured)
              TextButton(
                onPressed: busy ? null : _restore,
                child: const Text('Restore purchases'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(alreadyPro ? 'Done' : 'Not now'),
            ),
            Text(
              'Current: ${e.statusLabel}',
              textAlign: TextAlign.center,
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One selectable price row. Prices come from Play, never from a constant, so
/// the sheet always matches what the purchase dialog will charge.
class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final String? subtitle;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  const _PlanCard({
    required this.title,
    required this.price,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(title,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(badge!,
                            style: text.labelSmall?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ]),
                  if (subtitle != null)
                    Text(subtitle!,
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(price,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// Shown on launch/resume when the trial has 3 days and 1 day left. Each fires
/// once — [Entitlements.dueTrialReminder] owns that bookkeeping.
Future<void> showTrialReminderSheet(BuildContext context, int daysLeft) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      final ending = daysLeft <= 1;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.hourglass_bottom, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    ending
                        ? 'Your trial ends tomorrow'
                        : 'Your trial ends in $daysLeft days',
                    style: Theme.of(sheetCtx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              ending
                  ? 'After today the free version keeps 25 audios and 2 '
                      'playlists, and ads start. Everything you already saved '
                      'stays playable — nothing is deleted.'
                  : 'When it ends, the free version keeps 25 audios and 2 '
                      'playlists, and ads start. Your current library stays '
                      'playable — nothing is deleted.',
              style: Theme.of(sheetCtx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                Navigator.pop(sheetCtx);
                showPaywallSheet(context, reason: 'Keep everything, no ads');
              },
              child: const Text('Get Pro · no ads'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(sheetCtx);
                Entitlements.I.markReminderShown(daysLeft);
              },
              child: const Text('Maybe later'),
            ),
          ],
        ),
      );
    },
  );
}
