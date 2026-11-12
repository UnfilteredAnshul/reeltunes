// Shared bottom sheets: Add reel + player. Emoji picker is its own file.

import 'dart:math';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'billing.dart';
import 'emoji.dart';
import 'entitlements.dart';
import 'extraction_errors.dart';
import 'extractor.dart';
import 'library.dart';
import 'library_sync.dart';
import 'link_rules.dart';
import 'models.dart';
import 'player.dart';
import 'top_toast.dart';
import 'ads.dart';
import 'receipt_pdf.dart';

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
            helperText: 'YouTube Shorts, Instagram Reels, Facebook or TikTok',
            helperMaxLines: 2,
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
          onPressed: () => importAudioFile(context),
          icon: const Icon(Icons.folder_open),
          label: const Text('Or import a file instead'),
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

  /// "This link is already saved as …" → true means add a second copy.
  Future<bool> _confirmDuplicateLink(Track existing) async {
    final add = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.copy_all_outlined,
                  color: Theme.of(sheetCtx).colorScheme.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Already in your library',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'This link is already saved as "${existing.title}". Add a second '
              'copy, or skip it?',
              style: Theme.of(sheetCtx).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(children: [
              TextButton(
                onPressed: () => Navigator.pop(sheetCtx, false),
                child: const Text('Skip'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(sheetCtx, true),
                child: const Text('Add anyway'),
              ),
            ]),
          ],
        ),
      ),
    );
    return add == true;
  }

  Future<void> _extract() async {
    final url = urlCtrl.text.trim();
    if (url.isEmpty || working) return;
    // Reject anything the engine cannot handle before it spends 30 s failing.
    final problem = linkProblem(url);
    if (problem != null) {
      showTopToast(context, problem, error: true);
      return;
    }
    if (!AppStore.I.audiosLinked) {
      showTopToast(context, 'Link your audios folder first (Settings).');
      return;
    }
    // Same reel pasted twice: offer the skip/keep choice instead of silently
    // creating a second copy.
    final existing = AppStore.I.trackBySourceUrl(url);
    if (existing != null && !await _confirmDuplicateLink(existing)) return;
    if (!mounted) return;
    // Check the cap before the engine runs: never download a file the library
    // is not allowed to list.
    if (Entitlements.I.importBlockReason(AppStore.I.tracks.length) != null) {
      showPaywallSheet(context,
          reason: 'Free tier holds ${Entitlements.I.maxTracks} audios');
      return;
    }

    // Free tier: one download/import ad per audio. Replaces the loading /
    // downloading moment — the ad runs first, the download starts after.
    if (Entitlements.I.showAds) {
      final earned = await Ads.I.showDownloadAd();
      if (!mounted) return;
      if (!earned) {
        showTopToast(context,
            'Ad didn\'t load — proceeding with the download anyway.');
      }
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
      final msg = e.toString();
      if (msg.contains('Folder access lost')) {
        showTopToast(
          context,
          'Folder access was lost. Link your audios folder again to save downloads.',
          error: true,
          actionLabel: 'Link folder',
          onAction: () async {
            if (!context.mounted) return;
            final relinked = await LibrarySync.reLinkFolder();
            if (context.mounted && relinked != null) {
              showTopToast(context, 'Folder linked. Try the download again.');
            }
          },
        );
        return;
      }
      // Always the same short sentence. The exact reason (and the technical
      // text) lives in the guide, which the toast opens directly.
      showTopToast(
        context,
        "Can't download this one, check the guide for the reason.",
        error: true,
        actionLabel: 'Guide',
        onAction: () {
          if (context.mounted) showGuideSheet(context);
        },
      );
      // TODO(dev-phase-over): restore the user-facing fallback:
      // Navigator.pop(context);
      // _onExtractionFailed(failedUrl);
      debugPrint('failed link: $failedUrl');
    }
  }

  /// Shown whenever in-app extraction can't deliver: route to the web
  /// wrapper (pre-filled link) or import a file picked on-device.
  // Kept for the end of the dev phase: the generic toast is intentional now.
  // ignore: unused_element
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
                  // The Add-reel sheet is still on screen, so its context can
                  // host the duplicate warning if the file is already saved.
                  await importAudioFile(context);
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

/// Multi-select folder membership for a track. Every tick applies instantly —
/// there is no Save step.
Future<void> showFolderPick(BuildContext context, Track t) {
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
          Text('Tap a playlist to add or remove — it saves straight away.',
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
                    value: t.folderIds.contains(f.id),
                    onChanged: (v) async {
                      final add = v == true;
                      if (!add && AppStore.I.confirmRemove) {
                        final ok = await _confirmPlaylistRemoval(sheetCtx, 1);
                        if (ok != true || !sheetCtx.mounted) return;
                      }
                      final next = <String>[
                        for (final id in t.folderIds)
                          if (id != f.id) id,
                        if (add) f.id,
                      ];
                      AppStore.I.setTrackFolders(t.id, next);
                      setSheetState(() {});
                    },
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
        ]),
      ),
    ),
  );
}

/// Confirm taking a track out of one (or more) playlists. Shares the
/// "Confirm before removing" setting rather than adding a second one.
Future<bool?> _confirmPlaylistRemoval(BuildContext context, int count) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Remove from playlist?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          const SizedBox(height: 8),
          Text(
            count == 1
                ? 'This audio will leave the playlist you unticked. The audio '
                    'itself stays in your library.'
                : 'This audio will leave $count playlists you unticked. The '
                    'audio itself stays in your library.',
            style: Theme.of(sheetCtx).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(children: [
            TextButton(
              onPressed: () => Navigator.pop(sheetCtx, false),
              child: const Text('Cancel'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.pop(sheetCtx, true),
              child: const Text('Remove'),
            ),
          ]),
        ],
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

/// Plain-language tour of the app, with a search box that also explains every
/// download failure. Opened from Settings, from the home-screen bar, and from
/// an error toast. Both entry points show the same thing.
Future<void> showGuideSheet(BuildContext context, {String? query}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _GuideSheet(initialQuery: query ?? ''),
  );
}

class _GuideEntry {
  final IconData icon;
  final String title;
  final String body;
  final List<String> keywords;
  const _GuideEntry(this.icon, this.title, this.body,
      [this.keywords = const []]);
}

const List<_GuideEntry> _guideSteps = [
  _GuideEntry(
    Icons.link_rounded,
    'Add from a link',
    'Open the reel, tap Share, then pick ReelTunes. Or copy the link and paste '
        'it into Add reel.',
    ['share', 'link', 'add', 'reel'],
  ),
  _GuideEntry(
    Icons.folder_open_rounded,
    'Already have a file?',
    'Tap the folder button. Pick one file, several files, or a whole folder. '
        'Videos play as audio. Nothing gets copied.',
    ['import', 'file', 'folder', 'video', 'audio', 'multiple', 'single'],
  ),
  _GuideEntry(
    Icons.playlist_add_rounded,
    'Make a playlist',
    'Tap New playlist and give it a name. Tap its chip at the top to see only '
        'those songs. Tap All to see everything again.',
    ['playlist', 'folder', 'organise', 'organize'],
  ),
  _GuideEntry(
    Icons.search_rounded,
    'Find a song',
    'Tap the magnifier on the top bar and type part of the name.',
    ['search', 'find', 'name'],
  ),
  _GuideEntry(
    Icons.tune_rounded,
    'Sort and filter',
    'Tap the sliders button. Sort on the left, date filter on the right. You '
        'can use one or both. The newest audio is always first after an import.',
    ['sort', 'filter', 'newest', 'date'],
  ),
  _GuideEntry(
    Icons.play_circle_outline_rounded,
    'Play',
    'Tap a song to start. Tap the bar at the bottom for the full player. Press '
        'and hold a song to rename, move, remove or delete it. Playback also '
        'appears in the notification shade and on the lock screen.',
    ['play', 'player', 'notification', 'lock screen', 'rename'],
  ),
  _GuideEntry(
    Icons.folder_rounded,
    'Your files stay yours',
    'Everything you save sits in the audios folder. Drop a song in with a file '
        'manager and it shows up here. Reinstall the app, link the same folder, '
        'and your playlists come back.',
    ['files', 'storage', 'folder', 'reinstall', 'download'],
  ),
];

/// Built from the shared catalog so the guide and the error handlers can never
/// drift apart.
List<_GuideEntry> get _guideDownloadErrors => [
      for (final e in downloadErrorHelp)
        _GuideEntry(Icons.error_outline_rounded, e.title, e.body, e.keywords),
    ];

class _GuideSheet extends StatefulWidget {
  final String initialQuery;
  const _GuideSheet({required this.initialQuery});
  @override
  State<_GuideSheet> createState() => _GuideSheetState();
}

class _GuideSheetState extends State<_GuideSheet> {
  late final TextEditingController _search =
      TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(_GuideEntry e, String q) {
    if (q.isEmpty) return true;
    if (e.title.toLowerCase().contains(q)) return true;
    if (e.body.toLowerCase().contains(q)) return true;
    return e.keywords.any((k) => k.contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _search.text.trim().toLowerCase();
    final steps = _guideSteps.where((e) => _matches(e, q)).toList();
    final errors = _guideDownloadErrors.where((e) => _matches(e, q)).toList();
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('How ReelTunes works',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('No account needed. Your audios stay on this phone.'),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search: private, 403, storage, import…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
                children: [
                  if (steps.isNotEmpty) ...[
                    for (final e in steps)
                      _GuideStep(e.icon, e.title, e.body),
                  ],
                  if (errors.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      q.isEmpty ? 'If a download fails' : 'Download problems',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final e in errors)
                      _GuideStep(e.icon, e.title, e.body),
                  ],
                  if (steps.isEmpty && errors.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Nothing in the guide matches "${_search.text.trim()}". '
                        'Try "private", "403", "storage" or "folder".',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  if (q.isEmpty) ...[
                    const SizedBox(height: 4),
                    const Text('You can open this guide again from Settings.',
                        style: TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
      listenable: Listenable.merge([RtPlayer.I, AppStore.I]),
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
                      // Tapping the active mode switches looping off, so the
                      // audio plays once and the queue moves on.
                      onTap: () => player.setLoop(player.loop == RtLoop.smart
                          ? RtLoop.off
                          : RtLoop.smart),
                    ),
                    const SizedBox(width: 4),
                    _LoopChip(
                      label:
                          'Custom range (${AppStore.I.rangeMin}-${AppStore.I.rangeMax}x)'
                          '${Entitlements.I.canUseCustomRange ? '' : ' · Pro'}',
                      selected: player.loop == RtLoop.customRange,
                      onTap: () {
                        if (player.loop == RtLoop.customRange) {
                          player.setLoop(RtLoop.off);
                          return;
                        }
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
              if (player.loop == RtLoop.off)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'No loop · plays once, then the next audio',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
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
                              ? RtLoop.off
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
      // Never invent a currency amount: Play localises the price per country,
      // and a hard-coded rupee figure would be wrong everywhere else.
      'See price in Google Play';

  Future<void> _buy() async {
    if (busy) return;
    final e = Entitlements.I;

    // Already Pro: nothing to buy, just close. `paidPro` so a fresh install or
    // a live trial still reaches the purchase call below.
    if (e.paidPro) {
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
        if (context.mounted) {
          showTopToast(context, 'Welcome to Pro · no ads');
          await _promptDownloadSummary(context);
        }
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
        if (context.mounted) {
          showTopToast(context, 'Pro restored');
          await _promptDownloadSummary(context);
        }
      } else if (context.mounted) {
        showTopToast(context, report.message ?? 'Nothing to restore',
            error: report.outcome != PurchaseOutcome.unavailable);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _manage() async {
    await launchUrl(
      Uri.parse(Billing.manageUrlFor(Entitlements.I.productId)),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _downloadReceipt() async {
    if (busy) return;
    final e = Entitlements.I;
    if (!e.purchased && e.purchaseHistory.isEmpty) {
      showTopToast(context, 'No purchase to summarise yet', error: true);
      return;
    }
    setState(() => busy = true);
    try {
      final saved = await ReceiptPdf.saveToDevice();
      if (!mounted) return;
      if (saved) showTopToast(context, 'Purchase summary saved');
    } catch (err) {
      debugPrint('receipt: save failed $err');
      if (mounted) {
        showTopToast(context, 'Could not create the PDF', error: true);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// After a successful purchase, ask if the user wants to download the
  /// purchase summary PDF right now.
  Future<void> _promptDownloadSummary(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Download purchase summary?'),
        content: const Text(
          'Save a PDF summary of this purchase to your phone. '
          'Google Play remains the merchant of record; this is not a tax invoice.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    await _downloadReceipt();
  }

  /// Cancellation always happens in Google Play (the merchant of record).
  /// This sheet only explains the consequence and hands off. Test Store
  /// purchases never existed in Play, so they get a local off-switch instead.
  Future<void> _cancelSubscription() async {
    final e = Entitlements.I;
    final testStore = e.storeLabel == 'Test Store';
    final end = e.subscriptionEndsAt;
    final when = end == null ? 'the end of the paid period' : _longDate(end);
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(testStore ? 'End test Pro?' : 'Cancel ReelTunes Pro?'),
        content: Text(testStore
            ? 'This is a RevenueCat Test Store purchase, so Google Play has no '
                'subscription to cancel. Ending it here returns the app to the '
                'Free plan immediately. No money was ever charged.'
            : 'Cancelling stops the next payment. You keep Pro until $when; '
                'after that the app returns to the Free plan. Your audios, '
                'playlists and files are never deleted. Google Play handles '
                'the cancellation and any refund request — ReelTunes cannot '
                'cancel or refund a Play subscription.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Keep Pro'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(testStore ? 'End test Pro' : 'Open Google Play'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (testStore) {
      if (kDebugMode) {
        await Entitlements.I.setPurchased(false);
        if (!mounted) return;
        Navigator.pop(context);
        if (context.mounted) showTopToast(context, 'Test Pro ended');
      } else if (context.mounted) {
        showTopToast(context, 'Uninstall and reinstall to reset the test',
            error: true);
      }
      return;
    }
    await launchUrl(
      Uri.parse(Billing.manageUrlFor(e.productId)),
      mode: LaunchMode.externalApplication,
    );
  }

  static const _monthsLong = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static String _longDate(DateTime d) =>
      '${d.day} ${_monthsLong[d.month - 1]} ${d.year}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final e = Entitlements.I;
    final alreadyPro = e.paidPro;

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
                        ? 'Renews automatically through Google Play'
                            '${e.subscriptionEndsAt != null ? ' on ${_longDate(e.subscriptionEndsAt!)}' : ''}'
                            '${e.receiptPrice.isNotEmpty ? ' · ${e.receiptPrice}' : ''}.'
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
                        'Google Play — you keep Pro until the period ends.'
                    : 'Billed through Google Play. Cancel anytime in Google '
                        'Play — you keep Pro until the period ends.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                Billing.I.planView('monthly') != null
                    ? 'Prices shown by Google Play for your country.'
                    // Offline or not configured: never pretend a hard-coded
                    // number is the price Play will charge.
                    : 'Exact price is shown by Google Play at checkout.',
                textAlign: TextAlign.center,
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 14),
            if (e.purchased) ...[
              FilledButton(
                onPressed: busy ? null : _manage,
                child: const Text('Manage subscription'),
              ),
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: busy ? null : _cancelSubscription,
                child: const Text('Cancel subscription'),
              ),
            ] else if (!alreadyPro)
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
            if (e.purchased || e.purchaseHistory.isNotEmpty)
              TextButton.icon(
                onPressed: busy ? null : _downloadReceipt,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('Download purchase summary'),
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

/// One-time "trial or free?" prompt shown after the audios folder is linked.
/// Choosing free is final: the 7-day trial is forfeited on this install (and
/// travels with the folder mirror, so a reinstall does not bring it back).
Future<void> showTrialChoiceSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.auto_awesome_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Try Pro free for 7 days?',
                  style: Theme.of(sheetCtx)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Text(
              'Pro unlocks unlimited audios and playlists, custom looping, and '
              'removes ads. You can also continue on the free plan right away.',
              style: Theme.of(sheetCtx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'The trial runs for 7 days. It does not set up a payment by '
              'itself, and nothing is charged when it ends. Pro is only bought '
              'if you choose a plan later.',
              style: Theme.of(sheetCtx)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                await Entitlements.I.startTrial();
                if (!sheetCtx.mounted) return;
                Navigator.pop(sheetCtx);
                if (context.mounted) {
                  showTopToast(context, '7-day trial started');
                }
              },
              child: const Text('Start 7-day trial'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                await Entitlements.I.declineTrial();
                if (!sheetCtx.mounted) return;
                Navigator.pop(sheetCtx);
                if (context.mounted) {
                  showTopToast(context,
                      'Free plan. The trial will not be offered again.');
                }
              },
              child: const Text('Continue free'),
            ),
            const SizedBox(height: 8),
            Text(
              'Free keeps 25 audios and 2 playlists, with ads. Choosing free '
              'forfeits the trial permanently.',
              textAlign: TextAlign.center,
              style: Theme.of(sheetCtx)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    },
  );
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
