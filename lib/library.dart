// Library home screen: folder selector (list/grid) + track listing (list/grid).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
            title: const Text('ReelTune'),
            actions: [
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () => showFolderCreate(context),
              ),
              IconButton(
                tooltip: 'Add via file',
                icon: const Icon(Icons.playlist_add),
                onPressed: _importFile,
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => SettingsScreen())),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
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

  Future<void> _importFile() async {
    final out = await importAudioFile(context);
    if (out != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved to ${out.title}'), behavior: SnackBarBehavior.floating));
    }
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
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            if (i == store.folders.length) {
              final scheme = Theme.of(context).colorScheme;
              return Card(
                color: scheme.surfaceContainerHighest.withAlpha(120),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: InkWell(
                  onTap: () => showFolderCreate(context),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('➕', style: TextStyle(fontSize: 30)),
                      SizedBox(height: 6),
                      Text('New folder'),
                    ],
                  ),
                ),
              );
            }
            final f = store.folders[i];
            final selected = store.selectedFolderId == f.id;
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
          },
          childCount: store.folders.length + 1,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 150,
            mainAxisExtent: 110,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8),
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
        sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate(
            (c, i) => _TrackCard(track: list[i], onTap: () => _play(list[i], c)),
            childCount: list.length,
          ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              mainAxisExtent: 150,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8),
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
  try {
    File(t.path).deleteSync();
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
    return ListenableBuilder(
      listenable: RtPlayer.I,
      builder: (context, _) => SafeArea(
        child: Card(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: ListTile(
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
            trailing: IconButton(
              onPressed: () => RtPlayer.I.toggle(),
              icon: Icon(
                  RtPlayer.I.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Import pipeline (real for local files; URL extraction comes later)
// ---------------------------------------------------------------------------

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
