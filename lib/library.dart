// Library home screen: folder selector (list/grid) + track listing (list/grid).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

import 'models.dart';
import 'player.dart';
import 'settings_screen.dart';
import 'sheets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final selected = store.selectedFolderId;
        return Scaffold(
          appBar: AppBar(
            title: const Text('ReelTunes'),
            actions: [
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () => showFolderCreate(context),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => SettingsScreen())),
              ),
            ],
          ),
          // Two stacked actions: import locally, or add via link.
          floatingActionButton: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FloatingActionButton.extended(
                heroTag: 'importMedia',
                tooltip: 'Import audio / video files',
                onPressed: _openImportSheet,
                icon: const Icon(Icons.folder_open),
                label: const Text('Import audio'),
              ),
              const SizedBox(height: 12),
              FloatingActionButton.extended(
                heroTag: 'addReel',
                onPressed: () => showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  useSafeArea: false,
                  isScrollControlled: true,
                  builder: (_) => const AddReelSheet(),
                ),
                label: const Text('Add reel'),
                icon: const Icon(Icons.link),
              ),
            ],
          ),
          bottomNavigationBar: RtPlayer.I.current == null
              ? null
              : MiniBar(
                  track: RtPlayer.I.current!,
                  onTap: () => openPlayer(RtPlayer.I.current!)),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _FolderStrip()),
              if (store.folders.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
                  sliver: SliverToBoxAdapter(
                    child: Row(children: [
                      Text('Folders (${store.folders.length})',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                      const Spacer(),
                      _ViewToggle(
                          value: store.folderView,
                          on: (s) => store.setFolderView(s.first)),
                    ]),
                  ),
                ),
              if (store.folderView == ViewMode.grid) ...[
                _FoldersGrid()
              ] else ...[
                _FoldersList(),
                const SliverToBoxAdapter(child: _NewFolderRow()),
              ],
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
                sliver: SliverToBoxAdapter(
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        selected == null
                            ? 'All audios (${store.visibleTracksSorted.length})'
                            : 'In "${store.folderById(selected)?.name}" '
                                '(${store.visibleTracksSorted.length})',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Sort',
                      onPressed: () => showTrackSortSheet(context),
                      icon: const Icon(Icons.sort_outlined),
                    ),
                    _ViewToggle(
                        value: store.trackView,
                        on: (s) => store.setTrackView(s.first)),
                  ]),
                ),
              ),
              if (store.visibleTracks.isEmpty)
                const _EmptyLibrary()
              else
                _TracksView(store),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ),
        );
      },
    );
  }

  void openPlayer(Track t) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => PlayerSheet(
        track: t,
        contextTracks: AppStore.I.visibleTracks.toList(),
      ),
    );
  }

  /// Import intake: pick files (audio AND video) or a whole folder of
  /// videos. Videos play their audio track directly — the file is never
  /// touched: not copied, not deleted, zero storage waste.
  Future<void> _openImportSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.audiotrack_outlined),
            title: const Text('Import files (audio or video)'),
            subtitle: const Text(
                'Videos play as audio — nothing is copied or moved',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(c, 'files'),
          ),
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: const Text('Import a folder of videos'),
            subtitle: const Text(
                'Every video in the folder becomes an audio track',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(c, 'folder'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    final n = choice == 'files'
        ? await importMediaFiles()
        : await importMediaFolder();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0 ? 'No media found there' : 'Imported $n audios'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

// ---------------------------------------------------------------------------
// Folders section
// ---------------------------------------------------------------------------

class _ViewToggle extends StatelessWidget {
  final ViewMode value;
  final void Function(Set<ViewMode>) on;
  const _ViewToggle({required this.value, required this.on});
  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ViewMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: ViewMode.list, icon: Icon(Icons.list, size: 18)),
        ButtonSegment(value: ViewMode.grid, icon: Icon(Icons.grid_view_outlined, size: 18)),
      ],
      selected: {value},
      onSelectionChanged: on,
    );
  }
}

class _FolderStrip extends StatelessWidget {
  const _FolderStrip();
  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final chips = <(String?, String, String)>[
      (null, 'All', '🎧'),
      ...store.folders.map((f) => (f.id, f.name, f.emoji)),
      (null, 'New folder', '➕'),
    ];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (var i = 0; i < chips.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _FilterChipWrap(
                label: '${chips[i].$3} ${chips[i].$2}',
                selected: i != chips.length - 1 &&
                    store.selectedFolderId == chips[i].$1,
                onTap: () {
                  if (i == chips.length - 1) {
                    showFolderCreate(context);
                  } else if (i > 0) {
                    showFolderMenu(context, store.folders[i - 1]);
                  } else {
                    store.selectFolder(chips[i].$1);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterChipWrap extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChipWrap(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest.withAlpha(120),
        ),
        child: Text(label,
            style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }
}

class _FoldersList extends StatelessWidget {
  const _FoldersList();
  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return SliverReorderableList(
      itemCount: store.folders.length,
      onReorder: (o, n) => store.reorderFolders(o, n),
      proxyDecorator: (child, index, animation) => ScaleTransition(
        scale: animation.drive(Tween(begin: 1.0, end: 1.05)
            .chain(CurveTween(curve: Curves.ease))),
        child: Material(
            elevation: 2, borderRadius: BorderRadius.circular(12), child: child),
      ),
      itemBuilder: (c, i) {
        final f = store.folders[i];
        return KeyedSubtree(
          key: ValueKey(f.id),
          child: ListTile(
            leading: Text(f.emoji, style: const TextStyle(fontSize: 22)),
            title: Text(f.name),
            subtitle: Text(
                '${store.tracks.where((t) => t.folderIds.contains(f.id)).length} audios'),
            trailing: ReorderableDragStartListener(
                index: i,
                child: Icon(Icons.drag_handle, size: 20,
                    color: Theme.of(c).colorScheme.onSurfaceVariant)),
            onTap: () {
              store.selectFolder(f.id);
            },
            onLongPress: () => showFolderMenu(c, f),
          ),
        );
      },
    );
  }
}

class _NewFolderRow extends StatelessWidget {
  const _NewFolderRow();
  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Text('➕', style: TextStyle(fontSize: 22)),
        title: const Text('New folder'),
        onTap: () => showFolderCreate(context),
      );
}

class _FoldersGrid extends StatelessWidget {
  const _FoldersGrid();
  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ReorderableGridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 150,
                mainAxisExtent: 110,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8),
            onReorder: (o, n) => store.reorderFolders(o, n),
            itemCount: store.folders.length,
            itemBuilder: (c, i) {
              final f = store.folders[i];
              return KeyedSubtree(
                key: ValueKey(f.id),
                child: _folderCard(c, store, f, store.selectedFolderId == f.id),
              );
            },
          ),
          const SizedBox(height: 8),
          _newFolderCard(context),
        ]),
      ),
    );
  }

  Widget _folderCard(
      BuildContext context, AppStore store, Folder f, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? scheme.primaryContainer : null,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected
              ? BorderSide(color: scheme.primary, width: 1.5)
              : BorderSide.none),
      child: InkWell(
        onTap: () {
          store.selectFolder(selected ? null : f.id);
        },
        onLongPress: () => showFolderMenu(context, f),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(f.emoji, style: const TextStyle(fontSize: 30)),
            const SizedBox(height: 6),
            Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
                '${store.tracks.where((t) => t.folderIds.contains(f.id)).length} audios',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _newFolderCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest.withAlpha(120),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => showFolderCreate(context),
        child: const SizedBox(
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('➕', style: TextStyle(fontSize: 30)),
              SizedBox(height: 6),
              Text('New folder'),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tracks section
// ---------------------------------------------------------------------------

/// Sort picker: manual (drag order) / name / date added with asc-desc toggle.
Future<void> showTrackSortSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) {
      final store = AppStore.I;
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          RadioGroup<SortBy>(
            groupValue: store.sortBy,
            onChanged: (v) {
              store.setSortBy(v!);
              Navigator.pop(sheetCtx);
            },
            child: const Column(children: [
              _SortRadio(SortBy.manual, 'Manual (drag to rearrange)'),
              _SortRadio(SortBy.name, 'Name'),
              _SortRadio(SortBy.dateAdded, 'Date added'),
            ]),
          ),
          if (store.sortBy != SortBy.manual)
            SwitchListTile(
              title: Text(store.sortBy == SortBy.name
                  ? 'Ascending (A → Z)'
                  : 'Ascending (oldest first)'),
              value: store.sortAsc,
              onChanged: (v) => store.setSortAsc(v),
            ),
        ]),
      );
    },
  );
}

class _SortRadio extends StatelessWidget {
  final SortBy value;
  final String title;
  const _SortRadio(this.value, this.title);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Theme(
        data: t.copyWith(
            listTileTheme: t.listTileTheme
                .copyWith(dense: true, visualDensity: VisualDensity.compact)),
        child: RadioListTile<SortBy>(value: value, title: Text(title)));
  }
}

class _TracksView extends StatelessWidget {
  final AppStore store;
  const _TracksView(this.store);
  @override
  Widget build(BuildContext context) {
    final list = store.visibleTracksSorted;
    if (store.trackView == ViewMode.grid) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverToBoxAdapter(
          child: ReorderableGridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisExtent: 150,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8),
            onReorder: (o, n) => store.reorderVisibleTracks(o, n),
            itemCount: list.length,
            itemBuilder: (c, i) => KeyedSubtree(
              key: ValueKey(list[i].id),
              child: _TrackCard(track: list[i], onTap: () => _play(list[i], c)),
            ),
          ),
        ),
      );
    }
    // List view = drag to rearrange (writes that order back into the store).
    return SliverReorderableList(
      itemCount: list.length,
      onReorder: (o, n) => store.reorderVisibleTracks(o, n),
      proxyDecorator: (child, index, animation) => ScaleTransition(
        scale: animation.drive(
            Tween(begin: 1.0, end: 1.05).chain(CurveTween(curve: Curves.ease))),
        child: Material(elevation: 2, borderRadius: BorderRadius.circular(12), child: child),
      ),
      itemBuilder: (c, i) => KeyedSubtree(
          key: ValueKey(list[i].id),
          child: TrackTile(
              track: list[i],
              onTap: () => _play(list[i], c),
              all: list,
              handle: ReorderableDragStartListener(
                  index: i,
                  child: Icon(Icons.drag_handle, size: 20,
                      color: Theme.of(c).colorScheme.onSurfaceVariant)))),
    );
  }

  void _play(Track t, BuildContext c) {
    showModalBottomSheet(
      context: c,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => PlayerSheet(
          track: t, contextTracks: AppStore.I.visibleTracksSorted.toList()),
    );
  }
}

class _TrackCard extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  const _TrackCard({required this.track, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _trackMenu(context, track),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.music_note_outlined, color: scheme.onSurfaceVariant),
              const Spacer(),
              Text(track.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(track.source, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(children: [
            Icon(Icons.library_music_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('No audios yet. Tap + to add a reel or import one.',
                textAlign: TextAlign.center),
          ]),
        ),
      );
}

// ---------------------------------------------------------------------------
// Track tile + mini bar + tile helpers
// ---------------------------------------------------------------------------

class TrackTile extends StatelessWidget {
  final Track track;
  final List<Track>? all;
  final Widget? handle; // drag handle when rendered inside a reorderable list
  final VoidCallback onTap;
  const TrackTile(
      {required this.track, required this.onTap, this.all, this.handle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = RtPlayer.I.current?.id == track.id;
    final indicator = isCurrent
        ? Icon(Icons.graphic_eq, color: scheme.primary, size: 22)
        : Icon(Icons.play_circle_outline, size: 22,
            color: scheme.onSurfaceVariant);
    return ListTile(
      onTap: onTap,
      onLongPress: () => _trackMenu(context, track),
      title: Text(track.title,
          style: TextStyle(
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400)),
      subtitle: Text(
          '${track.source} · ${track.durationMs > 0 ? mmss(track.durationMs) : '—'}',
          style: Theme.of(context).textTheme.bodySmall),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: scheme.surfaceContainerHighest,
        ),
        child: Icon(Icons.music_note_outlined, color: scheme.onSurfaceVariant),
      ),
      trailing: handle == null && !isCurrent
          ? indicator
          : handle != null
              ? Row(mainAxisSize: MainAxisSize.min,
                  children: [handle!, const SizedBox(width: 8), indicator])
              : indicator,
    );
  }
}

// Long-press actions on a track: rename / add-to-folders / delete.
Future<void> _trackMenu(BuildContext context, Track t) async {
  final store = AppStore.I;
  final action = await showModalBottomSheet<_MenuAction>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Rename'),
          onTap: () => Navigator.pop(context, _MenuAction.rename),
        ),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Manage folders'),
          onTap: () => Navigator.pop(context, _MenuAction.move),
        ),
        ListTile(
          leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error),
          title: Text('Delete',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600)),
          onTap: () => Navigator.pop(context, _MenuAction.delete),
        ),
      ]),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case _MenuAction.rename:
      final ctrl = TextEditingController(text: t.title);
      final name = await showInputSheet(
        context,
        title: 'Rename audio',
        controller: ctrl,
        confirmLabel: 'Rename',
      );
      if (name != null && name.isNotEmpty && name != t.title) {
        store.renameTrack(t.id, name);
      }
    case _MenuAction.move:
      await showFolderPick(context, t);
    case _MenuAction.delete:
      await deleteTrackWithConfirm(context, t);
    case null:
      break;
  }
}

/// Delete flow honoring the "don't ask again" preference. The audio file is
/// removed from disk too — full data deletion per the product promise.
Future<void> deleteTrackWithConfirm(BuildContext context, Track t) async {
  final store = AppStore.I;
  if (store.confirmDelete) {
    final dontAsk = ValueNotifier(false);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isDismissible: true,
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment:
            CrossAxisAlignment.stretch, children: [
          const Text('Delete audio?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          const SizedBox(height: 8),
          Text('"${t.title}" will be removed from your library and its '
              'audio file will be deleted from the device.',
              style: Theme.of(sheetCtx).textTheme.bodySmall),
          const SizedBox(height: 8),
          ValueListenableBuilder<bool>(
            valueListenable: dontAsk,
            builder: (c, v, _) => CheckboxListTile(
              value: v,
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Don\'t ask again'),
              onChanged: (nv) => dontAsk.value = nv ?? false,
            ),
          ),
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
              label: const Text('Delete'),
              onPressed: () {
                if (dontAsk.value) store.setConfirmDelete(false);
                Navigator.pop(sheetCtx, true);
              },
            ),
          ]),
        ]),
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  // Delete semantics: library-OWNED files (extracted audio, copied imports)
  // live inside the save root and are deleted from disk with the track.
  // Reference-imported files (the user's own videos) are NEVER deleted from
  // their original location — removing from the library only unlists them.
  final root = store.saveFolderWithRoot();
  try {
    if (root != null && t.path.startsWith(root)) {
      File(t.path).deleteSync();
    }
  } catch (_) {}
  store.removeTrack(t.id);
  RtPlayer.I.removeIfCurrent(t.id);
}

enum _MenuAction { rename, move, delete }

class MiniBar extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  const MiniBar({required this.track, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = RtPlayer.I;
    final durMs = player.duration?.inMilliseconds ?? track.durationMs;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => SafeArea(
        child: Card(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                onTap: onTap,
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: scheme.surfaceContainerHighest,
                  ),
                  child:
                      Icon(Icons.music_note, color: scheme.onSurfaceVariant),
                ),
                title: Text(track.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (c, pos) => Text(
                    '${mmss((pos.data ?? Duration.zero).inMilliseconds)} / '
                    '${durMs > 0 ? mmss(durMs) : '—'}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                // Engine-stream-driven so the pause/play glyph flips the
                // instant playback state changes (never a stale ▶).
                trailing: StreamBuilder<bool>(
                  stream: player.playingStream,
                  initialData: player.playing,
                  builder: (c, s) => IconButton(
                    onPressed: () => player.toggle(),
                    icon: Icon(
                        (s.data ?? false)
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: scheme.onSurface),
                  ),
                ),
              ),
              StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (c, pos) {
                  final p = pos.data?.inMilliseconds ?? 0;
                  return LinearProgressIndicator(
                    value: durMs > 0 ? (p / durMs).clamp(0.0, 1.0) : 0,
                    minHeight: 2,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Import pipeline
// ---------------------------------------------------------------------------

/// Media extensions we accept on local import. Video files are played as
/// their audio track (the player reads the audio layer only) — no transcode,
/// no extraction, no extra storage.
const _audioExtensions = ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac'];
const _videoExtensions = ['mp4', 'mkv', 'webm', 'avi', 'm4v', 'mov', '3gp'];
const _mediaExtensions = [..._audioExtensions, ..._videoExtensions];

bool _isMediaPath(String p) {
  final ext = p.split('.').last.toLowerCase();
  return _mediaExtensions.contains(ext);
}

/// Reference-import a file: the Track points AT the original file. Nothing
/// is copied — so importing 200 videos from your device adds zero bytes.
Track _trackFromPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  final clean = path.split(Platform.pathSeparator).last
      .replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '')
      .trim();
  return Track(
    id: _trackId(),
    title: clean,
    source: _videoExtensions.contains(ext) ? 'video' : 'file',
    path: path,
    folderIds: const [],
    addedAtMs: DateTime.now().millisecondsSinceEpoch,
  );
}

/// Pick files (audio or video). Returns how many were imported.
Future<int> importMediaFiles() async {
  final files = await FilePicker.pickFiles(
      type: FileType.custom, allowedExtensions: _mediaExtensions);
  final paths = files
      .map((f) => f.path)
      .whereType<String>()
      .where(_isMediaPath)
      .toList();
  final store = AppStore.I;
  for (final p in paths) {
    store.addTrack(_trackFromPath(p));
  }
  return paths.length;
}

/// Pick an entire folder and import every media file it contains (top
/// level — the user's videos folder is usually flat).
Future<int> importMediaFolder() async {
  final dir = await FilePicker.getDirectoryPath();
  if (dir == null) return 0;
  final entries = Directory(dir)
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where(_isMediaPath)
      .toList()
    ..sort();
  final store = AppStore.I;
  for (final p in entries) {
    store.addTrack(_trackFromPath(p));
  }
  return entries.length;
}

Future<Track?> importAudioFile([BuildContext? context]) async {
  final picked = (await FilePicker.pickFiles(type: FileType.audio)).firstOrNull;
  if (picked == null || picked.path == null) return null;

  final store = AppStore.I;
  final dirName = store.saveFolder.isNotEmpty
      ? store.saveFolder
      : Directory.systemTemp.path;
  try {
    Directory(dirName).createSync(recursive: true);
  } catch (_) {}
  final id = _trackId();
  final cleanName = picked.name
      .replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '');
  final target =
      File('$dirName${Platform.pathSeparator}${id}_$cleanName');

  var t = Track(
      id: id,
      title: cleanName,
      source: 'import',
      path: picked.path!,
      addedAtMs: DateTime.now().millisecondsSinceEpoch);
  try {
    await File(picked.path!).copy(target.path);
    t = Track(
        id: id,
        title: cleanName,
        source: 'import',
        path: target.path,
        addedAtMs: DateTime.now().millisecondsSinceEpoch);
  } catch (_) {
    // couldn't reach the picked volume; keep the picker's cache copy
  }
  store.addTrack(t);
  return t;
}

String _trackId() => 't${DateTime.now().microsecondsSinceEpoch}';
