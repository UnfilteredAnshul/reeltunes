// Library home screen: folder selector (list/grid) + track listing (list/grid).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

import 'ads.dart';
import 'coins.dart';
import 'cover_art.dart';
import 'entitlements.dart';
import 'first_time_card.dart';
import 'folder_access.dart';
import 'models.dart';
import 'player.dart';
import 'sheets.dart';
import 'shop_sheet.dart';
import 'top_toast.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  // ---- idle nudge for the import FAB ----
  // While this page is visible and nothing is playing, the import button
  // reminds the user what it does after 7 s of stillness, then keeps doing it
  // for as long as they stay idle. Any touch, scroll or search restarts the
  // clock. Leaving the page (settings, a sheet, the player) pauses it.
  Timer? _idleTicker;
  Timer? _collapseTimer;
  DateTime _nextNudge = DateTime.now().add(const Duration(seconds: 7));
  bool _importExpanded = false;

  /// Rewarded ad in flight (disables the gold FAB so a double tap cannot open
  /// two full-screen ads).
  bool _adBusy = false;

  // ---- name search ----
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The nudge shows the "Import audio" label for 1.8 s, slips back to the
    // icon, then waits another 7 s of idle before repeating.
    _idleTicker =
        Timer.periodic(const Duration(milliseconds: 500), _idleTick);
  }

  @override
  void dispose() {
    _idleTicker?.cancel();
    _collapseTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Any touch means "the user is here" — restart the idle clock and tuck the
  /// label back in immediately.
  void _noteInteraction() {
    _nextNudge = DateTime.now().add(const Duration(seconds: 7));
    _collapseImport();
  }

  void _collapseImport() {
    _collapseTimer?.cancel();
    if (_importExpanded) setState(() => _importExpanded = false);
  }

  void _idleTick(Timer _) {
    if (!mounted) return;
    // Only the library page counts. Settings, sheets and the player sit on
    // top of it, and the clock should not run while the user is over there.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      _noteInteraction();
      return;
    }
    // Never nudge while audio plays — the mini bar is the focus then.
    if (RtPlayer.I.playing) {
      _noteInteraction();
      return;
    }
    if (_importExpanded) return;
    if (DateTime.now().isBefore(_nextNudge)) return;

    setState(() => _importExpanded = true);
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      setState(() => _importExpanded = false);
      // Arm the next reminder, so it keeps ticking while the user stays idle.
      _nextNudge = DateTime.now().add(const Duration(seconds: 7));
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return Listener(
      onPointerDown: (_) => _noteInteraction(),
      child: ListenableBuilder(
        // Entitlements + coins: flipping Force Free / a purchase / a shop perk
        // changes the audio cap and the ad flag, so the list must re-filter
        // immediately.
        listenable: Listenable.merge([store, Entitlements.I, CoinWallet.I]),
        builder: (context, _) {
        final store = AppStore.I;
        final scheme = Theme.of(context).colorScheme;
        final selected = store.selectedFolderId;
        return Scaffold(
          // Transparent: RootScreen draws the mesh art behind every tab.
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text('Library',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            actions: [
              if (Entitlements.I.shopAvailable) ...[
                IconButton(
                  tooltip: 'Coin shop',
                  icon: const Icon(Icons.storefront_outlined),
                  onPressed: () => showShopSheet(context),
                ),
                CoinBalanceChip(onTap: () => showShopSheet(context)),
                const SizedBox(width: 4),
              ],
            ],
          ),
          body: CustomScrollView(
            slivers: [
              // Search bar (always visible, like screenshot 2)
              SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(14),
                        // Same neon hairline + glow as the Search tab, so the
                        // field never disappears into the background art.
                        border: Border.all(
                            color: kNeonBlue.withValues(alpha: 0.55)),
                        boxShadow: [
                          BoxShadow(
                            color: kNeonBlue.withValues(alpha: 0.26),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search your sounds…',
                          hintStyle: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 14),
                          prefixIcon: Icon(Icons.search,
                              color: scheme.onSurfaceVariant, size: 20),
                          suffixIcon: _searchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    AppStore.I.setSearchQuery('');
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                        onChanged: (v) => AppStore.I.setSearchQuery(v),
                      ),
                    ),
                  ),
                ),
              // The All / Recently Added / Playlists chip row is gone. All
              // audios is the default view, playlists have their own section
              // below, and date filtering lives in the sort sheet.
              if (store.anyArranging)
                SliverToBoxAdapter(
                    child: _RearrangeBanner(folders: store.arrangingFolders)),
              if (!store.guideBannerDismissed)
                const SliverToBoxAdapter(child: FirstTimeCard(tight: true)),
              if (store.folders.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  sliver: SliverToBoxAdapter(
                    child: Row(children: [
                      IconButton(
                        tooltip: store.playlistsExpanded
                            ? 'Hide playlists'
                            : 'Show playlists',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => store.togglePlaylists(),
                        icon: AnimatedRotation(
                          turns: store.playlistsExpanded ? 0 : -0.25,
                          duration: const Duration(milliseconds: 180),
                          child: const Icon(Icons.expand_more),
                        ),
                      ),
                      Text('Playlists (${store.visibleFolders.length})',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                      const Spacer(),
                      if (store.playlistsExpanded)
                        _ViewToggle(
                            value: store.folderView,
                            on: (s) => store.setFolderView(s.first)),
                    ]),
                  ),
                ),
              if (store.playlistsExpanded && store.folderView == ViewMode.grid)
                _FoldersGrid()
              else if (store.playlistsExpanded) ...[
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
                      tooltip: store.activeSortBy == SortBy.manual
                          ? 'Sort'
                          : 'Sort (active)',
                      onPressed: () => showSortFilterSheet(context),
                      icon: Icon(Icons.sort,
                          color: store.activeSortBy != SortBy.manual
                              ? Theme.of(context).colorScheme.primary
                              : null),
                    ),
                    _ViewToggle(
                        value: store.trackView,
                        on: (s) => store.setTrackView(s.first)),
                  ]),
                ),
              ),
              if (store.folderOverflow > 0)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: Material(
                            color: Theme.of(context).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => showPaywallSheet(context,
                                  reason:
                                      'Free tier holds ${Entitlements.I.maxTracks} audios'),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                child: Row(children: [
                                  Icon(Icons.lock_outline,
                                      size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSecondaryContainer),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${store.folderOverflow} more '
                                '${store.folderOverflow == 1 ? 'file' : 'files'}'
                                ' in your folder · Pro to add',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer),
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              if (store.hiddenByFreeCap > 0)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: Material(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => showPaywallSheet(context,
                            reason:
                                'Free shows the newest ${Entitlements.I.maxTracks} audios'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          child: Row(children: [
                            Icon(Icons.lock_outline,
                                size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onTertiaryContainer),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${store.hiddenByFreeCap} older '
                                '${store.hiddenByFreeCap == 1 ? 'audio is' : 'audios are'}'
                                ' hidden on Free · files stay on your phone',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onTertiaryContainer),
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              if (store.visibleTracks.isEmpty)
                const _EmptyLibrary()
              else
                _TracksView(store),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ),
        floatingActionButton: SizedBox(
          width: 200,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (Entitlements.I.shopAvailable) ...[
                _WatchAdFab(
                  expanded: _importExpanded,
                  busy: _adBusy,
                  onPressed: _watchAd,
                ),
                const SizedBox(height: 12),
              ],
              _ImportFab(
                expanded: _importExpanded,
                onPressed: _openImportSheet,
              ),
              const SizedBox(height: 12),
              FloatingActionButton.extended(
                heroTag: 'addReelLibrary',
                onPressed: _openAddReel,
                label: const Text('Add reel'),
                icon: const Icon(Icons.add_link),
              ),
            ],
          ),
        ),
      );
    },
      ),
    );
  }

  /// Gold FAB: one rewarded video → coins. The coin balance, the shop and this
  /// button deliberately survive a coin-shop purchase (only the ads stop).
  Future<void> _watchAd() async {
    if (_adBusy) return;
    _noteInteraction();
    setState(() => _adBusy = true);
    try {
      await watchRewardedAd(context);
    } finally {
      if (mounted) setState(() => _adBusy = false);
    }
  }

  /// Import intake: delegates to the shared [openImportSheet] flow.
  Future<void> _openImportSheet() => openImportSheet(context);

  /// "Add reel" from the FAB: paywall at the Free cap before the sheet opens.
  /// The download/import ad fires inside AddReelSheet._extract() / _openImportSheet(),
  /// so exactly one ad plays per download or import.
  Future<void> _openAddReel() async {
    if (Entitlements.I.importBlockReason(AppStore.I.tracks.length) != null) {
      showPaywallSheet(context,
          reason: 'Free tier holds ${Entitlements.I.maxTracks} audios');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const AddReelSheet(),
    );
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

/// Sticky banner for grid rearrange mode: drag freely, then hit Save.
/// List view keeps its drag handles, so it never needs this mode.
class _RearrangeBanner extends StatelessWidget {
  final bool folders;
  const _RearrangeBanner({required this.folders});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Icon(folders ? Icons.folder_outlined : Icons.graphic_eq_rounded,
            size: 20, color: scheme.onPrimaryContainer),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            folders
                ? 'Rearranging playlists. Drag the cards'
                : 'Rearranging audios. Drag the cards',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onPrimaryContainer),
          ),
        ),
        FilledButton(
          onPressed: () => AppStore.I.stopArranging(),
          child: const Text('Save'),
        ),
      ]),
    );
  }
}

class _FoldersList extends StatelessWidget {
  const _FoldersList();
  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final folders = store.visibleFolders;
    return SliverReorderableList(
      itemCount: folders.length,
      onReorder: (o, n) => store.reorderFolders(o, n),
      proxyDecorator: (child, index, animation) => ScaleTransition(
        scale: animation.drive(Tween(begin: 1.0, end: 1.05)
            .chain(CurveTween(curve: Curves.ease))),
        child: Material(
            elevation: 2, borderRadius: BorderRadius.circular(12), child: child),
      ),
      itemBuilder: (c, i) {
        final f = folders[i];
        return KeyedSubtree(
          key: ValueKey(f.id),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
            // The fill lives on a Material, not a decorated Container: ListTile
            // paints its ink on the nearest Material, and a coloured ancestor
            // would hide the splash (and trip Flutter's debug warning).
            child: Material(
              color: Theme.of(c)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.35),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: Theme.of(c)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.14))),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: PlaylistArt(
                  seed: f.id,
                  size: 40,
                ),
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
            ),
          ),
        );
      },
    );
  }
}

class _NewFolderRow extends StatelessWidget {
  const _NewFolderRow();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: ListTile(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.14))),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.add, size: 20, color: Colors.white),
          ),
          title: const Text('New playlist'),
          onTap: () => showFolderCreate(context),
        ),
      );
}

class _FoldersGrid extends StatelessWidget {
  const _FoldersGrid();
  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final folders = store.visibleFolders;
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
            // Grid dragging only inside the explicit rearrange mode (hold a
            // card > Rearrange > drag > Save). Outside it, drags fought taps.
            dragEnabled: store.arrangingFolders,
            dragStartDelay: store.arrangingFolders
                ? Duration.zero
                : const Duration(milliseconds: 260),
            onReorder: (o, n) => store.reorderFolders(o, n),
            itemCount: folders.length,
            itemBuilder: (c, i) {
              final f = folders[i];
              return KeyedSubtree(
                key: ValueKey(f.id),
                child: _folderCard(c, store, f,
                    store.selectedFolderId == f.id,
                    arranging: store.arrangingFolders),
              );
            },
          ),
          const SizedBox(height: 8),
          _newFolderCard(context),
        ]),
      ),
    );
  }

  Widget _folderCard(BuildContext context, AppStore store, Folder f,
      bool selected, {bool arranging = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? scheme.primaryContainer : null,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.14),
              width: selected ? 1.5 : 1)),
      child: InkWell(
        // In rearrange mode taps and menus are inert — dragging is all that's
        // live, so a mis-tap can never select or open a menu mid-drag.
        onTap: arranging
            ? null
            : () => store.selectFolder(selected ? null : f.id),
        onLongPress: arranging
            ? null
            : () => showFolderMenu(context, f, allowRearrange: true),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            PlaylistArt(seed: f.id, size: 44),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                  '${store.tracks.where((t) => t.folderIds.contains(f.id)).length} audios',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _newFolderCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest.withAlpha(120),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: scheme.onSurface.withValues(alpha: 0.14))),
      child: InkWell(
        onTap: () => showFolderCreate(context),
        child: SizedBox(
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: kNeonBlue.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.add, size: 24, color: kNeonBlue),
              ),
              const SizedBox(height: 6),
              const Text('New playlist'),
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

/// One sheet, two halves: sort on the left, date filter on the right. Both
/// apply immediately and the sheet stays open, so the user can set both in
/// one pass or just one of them.
Future<void> showSortFilterSheet(BuildContext context) {
  final store = AppStore.I;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetCtx) => SafeArea(
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(
                    store.selectedFolderId == null
                        ? 'Sort all audios'
                        : 'Sort this playlist',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              _SortHalf(store),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      store.setSortBy(SortBy.dateAdded);
                      store.setSortAsc(false);
                      store.setSearchQuery('');
                      Navigator.pop(sheetCtx);
                    },
                    child: const Text('Reset sort'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text('Done'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HalfTitle extends StatelessWidget {
  final String text;
  const _HalfTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
        child: Text(text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _SortHalf extends StatelessWidget {
  final AppStore store;
  const _SortHalf(this.store);

  @override
  Widget build(BuildContext context) {
    // All audios has no manual order: it always runs newest-first and never
    // offers dragging. Manual shows up only inside a playlist.
    final inPlaylist = store.selectedFolderId != null;
    final by = store.activeSortBy;
    final asc = store.activeSortAsc;
    final ascLabel = by == SortBy.name ? 'A to Z' : 'Oldest first';
    final descLabel = by == SortBy.name ? 'Z to A' : 'Newest first';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HalfTitle('SORT'),
        if (inPlaylist)
          _ChoiceRow(
              label: 'Manual',
              hint: 'your saved order',
              selected: by == SortBy.manual,
              onTap: () => store.setSortBy(SortBy.manual)),
        _ChoiceRow(
            label: 'Name',
            selected: by == SortBy.name,
            onTap: () => store.setSortBy(SortBy.name)),
        _ChoiceRow(
            label: 'Date added',
            selected: by == SortBy.dateAdded,
            onTap: () => store.setSortBy(SortBy.dateAdded)),
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 8, right: 8),
          child: Text(
            inPlaylist
                ? 'Dragging works only in Manual. Picking a date or name sort '
                    'keeps the hand order saved, so Manual brings it back.'
                : 'All audios always runs newest first and can never be '
                    'rearranged. Open a playlist for Manual order.',
            style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        if (by != SortBy.manual)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => store.setSortAsc(!asc),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: [
                  Icon(
                      asc
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(asc ? ascLabel : descLabel,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary)),
                  ),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact radio row. RadioListTile is too tall for two side-by-side columns.
class _ChoiceRow extends StatelessWidget {
  final String label;
  final String? hint;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceRow(
      {required this.label,
      this.hint,
      required this.selected,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18, color: selected ? scheme.primary : scheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400)),
                if (hint != null)
                  Text(hint!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontSize: 11)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _TracksView extends StatelessWidget {
  final AppStore store;
  const _TracksView(this.store);

  /// Free plan: two in-list ad cards, after the 8th and 18th audio, both using
  /// the playlist unit. Display indices are mapped back to track indices so
  /// dragging never counts an ad as an audio. Grid view skips them (a 320 px
  /// banner cannot be shown at grid-card size without cropping, and cropping
  /// an ad is against AdMob policy).
  List<Track?> _entries(List<Track> list) {
    if (!Entitlements.I.showAds || store.arrangingTracks) {
      return List<Track?>.of(list);
    }
    if (list.isEmpty) return [];
    final out = <Track?>[];
    // Free tier: 1 native ad when under 10 audios, 2 when over 10.
    // Always show at least one ad even when the list is short.
    final adCount = list.length > 10 ? 2 : 1;
    for (var i = 0; i < list.length; i++) {
      out.add(list[i]);
      // First ad after the 7th item (index 6).
      if (adCount == 1 && i == 6 && i != list.length - 1) out.add(null);
      // First ad after the 8th item (index 7) for long lists.
      if (adCount == 2 && i == 7 && i != list.length - 1) out.add(null);
      // Second ad after the 18th item (index 17) for long lists.
      if (adCount == 2 && i == 17 && i != list.length - 1) out.add(null);
    }
    // Short list: pin one ad at the end so it always shows.
    if (adCount == 1 && out.last != null) out.add(null);
    // Long list: make sure both ads appear even if positions were missed.
    if (adCount == 2) {
      final already = out.where((e) => e == null).length;
      if (already < adCount && out.last != null) out.add(null);
    }
    return out;
  }

  int _trackIndexAt(List<Track?> entries, int display) {
    if (display < 0 || display >= entries.length) return -1;
    if (entries[display] == null) return -1;
    var n = 0;
    for (var i = 0; i < display; i++) {
      if (entries[i] != null) n++;
    }
    return n;
  }

  void _onReorder(List<Track?> entries, int oldDisplay, int newDisplay) {
    final oldTrack = _trackIndexAt(entries, oldDisplay);
    if (oldTrack < 0) return;
    var target = 0;
    for (var i = 0; i < newDisplay && i < entries.length; i++) {
      if (i != oldDisplay && entries[i] != null) target++;
    }
    store.reorderVisibleTracks(
        oldTrack, target > oldTrack ? target + 1 : target);
  }

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
            // Grid dragging only inside a playlist that is showing its Manual
            // order, and only in the explicit rearrange mode (hold a card >
            // Rearrange > drag > Save). Outside it, drags fought taps.
            dragEnabled: store.arrangingTracks && store.canRearrangeTracks,
            dragStartDelay: store.arrangingTracks
                ? Duration.zero
                : const Duration(milliseconds: 260),
            onReorder: (o, n) => store.reorderVisibleTracks(o, n),
            itemCount: list.length,
            itemBuilder: (c, i) => KeyedSubtree(
              key: ValueKey(list[i].id),
              child: _TrackCard(
                  track: list[i],
                  rearrangeMode: store.arrangingTracks,
                  onTap: store.arrangingTracks
                      ? null
                      : () => _play(list[i], c)),
            ),
          ),
        ),
      );
    }
    // List view = drag to rearrange (writes that order back into the store).
    final entries = _entries(list);
    return SliverReorderableList(
      itemCount: entries.length,
      onReorder: (o, n) => _onReorder(entries, o, n),
      proxyDecorator: (child, index, animation) => ScaleTransition(
        scale: animation.drive(
            Tween(begin: 1.0, end: 1.05).chain(CurveTween(curve: Curves.ease))),
        child: Material(elevation: 2, borderRadius: BorderRadius.circular(12), child: child),
      ),
      itemBuilder: (c, i) {
        final t = entries[i];
        if (t == null) {
          return KeyedSubtree(
            key: ValueKey('playlist-ad-$i'),
            child: PlaylistAdCard(key: ValueKey('playlist-card-$i')),
          );
        }
        return KeyedSubtree(
            key: ValueKey(t.id),
            child: TrackTile(
                track: t,
                onTap: () => _play(t, c),
                all: list,
                // The handle only appears where dragging is legal: inside a
                // playlist that is showing its saved Manual order.
                handle: store.canRearrangeTracks
                    ? ReorderableDragStartListener(
                        index: i,
                        child: Icon(Icons.drag_handle, size: 20,
                            color: Theme.of(c).colorScheme.onSurfaceVariant))
                    : null));
      },
    );
  }

  void _play(Track t, BuildContext c) {
    openPlayerPage(
      c,
      track: t,
      contextTracks: AppStore.I.visibleTracksSorted.toList(),
    );
  }
}

class _TrackCard extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  /// Grid rearrange mode: long-press starts card drag instead of the menu.
  final bool rearrangeMode;
  const _TrackCard(
      {required this.track, required this.onTap, this.rearrangeMode = false});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: rearrangeMode
            ? null
            : () => showTrackMenu(context, track,
                allowRearrange: AppStore.I.canRearrangeTracks),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              CoverArt(seed: track.id, size: 40),
              const SizedBox(height: 6),
              Flexible(
                child: Text(track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Text(track.source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11)),
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
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final filtered = store.searchQuery.trim().isNotEmpty;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(children: [
          Icon(filtered ? Icons.search_off : Icons.library_music_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(
              filtered
                  ? 'No audios match your search or date filter.'
                  : 'No audios yet. Tap + to add a reel or import one.',
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Import FAB (icon-only, expands on idle)
// ---------------------------------------------------------------------------

/// Import button: a folder icon in a circle by default. When the app has been
/// idle it morphs into a pill, shows "Import audio" for a moment, then slips
/// back. The pill sizes itself to its label — no reserved trailing gap — while
/// the FAB slot underneath keeps the row from shifting.
class _ImportFab extends StatelessWidget {
  static const double _collapsed = 56;

  final bool expanded;
  final VoidCallback onPressed;
  const _ImportFab({required this.expanded, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: _collapsed,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(_collapsed / 2),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: expanded ? 1 : 0),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 16),
                Icon(Icons.folder_open, color: scheme.onPrimaryContainer),
                Flexible(
                  child: ClipRect(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: v,
                      child: Opacity(
                        opacity: v,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10, right: 16),
                          child: Text(
                            'Import audio',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: scheme.onPrimaryContainer),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Collapsed: 16 + icon + 16 = 56 (the circle). Expanded: the
                // label supplies its own 16 px right padding, so this spacer
                // shrinks to zero and the pill ends right after the text.
                SizedBox(width: 16 * (1 - v)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Gold counterpart to [_ImportFab]: watch one rewarded video and earn coins.
/// Same expand-on-idle behaviour, only rendered on the Free plan.
class _WatchAdFab extends StatelessWidget {
  static const double _collapsed = 56;
  final bool expanded;
  final bool busy;
  final VoidCallback onPressed;
  const _WatchAdFab({
    required this.expanded,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _collapsed,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [coinGoldLight, coinGold],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(_collapsed / 2),
        boxShadow: const [
          BoxShadow(
              color: Color(0x40A97900), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onPressed,
          customBorder: const StadiumBorder(),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: expanded ? 1 : 0),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 16),
                busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: coinInk))
                    : const Icon(Icons.smart_display_rounded, color: coinInk),
                Flexible(
                  child: ClipRect(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: v,
                      child: Opacity(
                        opacity: v,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10, right: 16),
                          child: Text(
                            'Watch ad · +${CoinWallet.coinsPerAd}',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, color: coinInk),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 16 * (1 - v)),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
      onLongPress: () => showTrackMenu(context, track),
      title: Text(track.title,
          style: TextStyle(
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400)),
      subtitle: Text(
          '${track.source} · ${track.durationMs > 0 ? mmss(track.durationMs) : '—'}',
          style: Theme.of(context).textTheme.bodySmall),
      leading: CoverArt(
        seed: track.id,
        size: 44,
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
Future<void> showTrackMenu(BuildContext context, Track t,
    {bool allowRearrange = false}) async {
  final store = AppStore.I;
  final action = await showModalBottomSheet<_MenuAction>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (allowRearrange)
          ListTile(
            leading: const Icon(Icons.swap_vert_rounded),
            title: const Text('Rearrange'),
            subtitle: const Text('Drag the cards into place, then Save',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(context, _MenuAction.rearrange),
          ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Rename'),
          onTap: () => Navigator.pop(context, _MenuAction.rename),
        ),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Manage playlists'),
          onTap: () => Navigator.pop(context, _MenuAction.move),
        ),
        ListTile(
          leading: const Icon(Icons.playlist_remove),
          title: const Text('Remove from ReelTunes'),
          subtitle: const Text('Keeps the file on your phone',
              style: TextStyle(fontSize: 12)),
          onTap: () => Navigator.pop(context, _MenuAction.remove),
        ),
        ListTile(
          leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error),
          title: Text('Delete audio and file',
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
    case _MenuAction.rearrange:
      store.startArranging(folders: false);
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
      // Back arrow in the playlist picker returns here instead of dumping the
      // user out of the menu entirely.
      if (await showFolderPick(context, t) && context.mounted) {
        await showTrackMenu(context, t, allowRearrange: allowRearrange);
      }
    case _MenuAction.remove:
      await removeTrackFromLibrary(context, t);
    case _MenuAction.delete:
      await deleteTrackWithConfirm(context, t);
    case null:
      break;
  }
}

/// Takes a track out of the library without touching the file behind it.
/// Asks first (unless "don't ask again" is set): this is the safe default, and
/// the audio stays in the audios folder, so a re-scan can bring it back.
Future<void> removeTrackFromLibrary(BuildContext context, Track t) async {
  final store = AppStore.I;
  if (store.confirmRemove) {
    final dontAsk = ValueNotifier(false);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Remove from ReelTunes?',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              '"${t.title}" will leave your library. The audio file stays on '
              'your phone, and importing the folder again brings it back.',
              style: Theme.of(sheetCtx).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<bool>(
              valueListenable: dontAsk,
              builder: (c, v, _) => CheckboxListTile(
                value: v,
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text("Don't ask again"),
                onChanged: (nv) => dontAsk.value = nv ?? false,
              ),
            ),
            Row(children: [
              TextButton(
                onPressed: () => Navigator.pop(sheetCtx, false),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  if (dontAsk.value) store.setConfirmRemove(false);
                  Navigator.pop(sheetCtx, true);
                },
                child: const Text('Remove'),
              ),
            ]),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  store.removeTrackKeepFile(t.id);
  await RtPlayer.I.removeIfCurrent(t.id);
  if (!context.mounted) return;
  showTopToast(
      context, 'Removed from ReelTunes. The file is still on your phone.');
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
          const Text('Delete audio and file?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          const SizedBox(height: 8),
          Text('"${t.title}" will be removed from your library and the audio '
              'file will be deleted from this phone. Only want it out of the '
              'app? Use "Remove from ReelTunes" instead.',
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
  // live inside the audios folder and are deleted with the track. Files the
  // user referenced from somewhere else are NEVER deleted from their original
  // location — removing from the library only unlists them.
  final root = store.audiosUri;
  try {
    if (t.path.startsWith('content://') &&
        root.isNotEmpty &&
        t.path.startsWith(root)) {
      await FolderAccess.delete(t.path);
    } else if (root.isNotEmpty && t.path.startsWith(root)) {
      File(t.path).deleteSync();
    }
  } catch (_) {}
  store.removeTrack(t.id);
  await RtPlayer.I.removeIfCurrent(t.id);
}

/// Rewarded video → coins. Shared by the Library FAB and the Home action row.
/// Returns true when the user actually earned coins.
Future<bool> watchRewardedAd(BuildContext context) async {
  final outcome = await Ads.I.showRewarded();
  if (!context.mounted) return false;
  switch (outcome) {
    case RewardedOutcome.earned:
      await CoinWallet.I.addFromAd();
      if (context.mounted) {
        showTopToast(
            context,
            '+${CoinWallet.coinsPerAd} coin'
            '${CoinWallet.coinsPerAd == 1 ? '' : 's'}');
      }
      return true;
    case RewardedOutcome.dismissedEarly:
      // The video played but was closed before the reward: say so instead of
      // claiming no ad existed.
      showTopToast(context, 'Watch the whole video to earn the coin.',
          error: true);
      return false;
    case RewardedOutcome.unavailable:
      showTopToast(context, 'No ad available right now — try again.',
          error: true);
      return false;
  }
}

/// Import intake: pick files (audio AND video) or a whole folder of videos.
/// Videos play their audio track directly — the file is never touched: not
/// copied, not deleted, zero storage waste.
///
/// Top-level so Home and Library share one flow (same paywall check, same
/// one-ad-per-import gate).
Future<void> openImportSheet(BuildContext context) async {
  if (Entitlements.I.importBlockReason(AppStore.I.tracks.length) != null) {
    showPaywallSheet(context,
        reason: 'Free tier holds ${Entitlements.I.maxTracks} audios');
    return;
  }
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.audiotrack_outlined),
          title: const Text('Import files'),
          subtitle: const Text(
              'Pick one file or many. Songs and videos both work - videos '
              'play as audio.',
              style: TextStyle(fontSize: 12)),
          onTap: () => Navigator.pop(c, 'files'),
        ),
        ListTile(
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('Import a folder'),
          subtitle: const Text(
              'Every audio and video in the folder. The newest 25 are added '
              'on the free plan.',
              style: TextStyle(fontSize: 12)),
          onTap: () => Navigator.pop(c, 'folder'),
        ),
        const SizedBox(height: 6),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;

  // Free tier: one download/import ad per audio. Replaces the loading /
  // importing moment — the ad runs first, the import starts after.
  if (Entitlements.I.showAds) {
    final earned = await Ads.I.showDownloadAd();
    if (!context.mounted) return;
    if (!earned) {
      showTopToast(
          context, 'Ad didn\'t load — proceeding with the import anyway.');
    }
  }

  try {
    final n = switch (choice) {
      'files' => await importMediaFiles(context),
      _ => await importMediaFolder(context),
    };
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'No audio or video files found there'
          : 'Imported $n ${n == 1 ? 'audio' : 'audios'}'),
      behavior: SnackBarBehavior.floating,
    ));
  } catch (e) {
    // Say WHY it failed (denied access, unreadable folder…) rather than
    // claiming nothing was found, which was a lie about the folder.
    debugPrint('import failed: $e');
    if (!context.mounted) return;
    showTopToast(context, "Couldn't open that folder. Try again.");
  }
}

enum _MenuAction { rearrange, rename, move, remove, delete }

class MiniBar extends StatelessWidget {
  /// Optional override. Normally omitted: the bar resolves the playing track,
  /// else the last track that was played (persisted across launches), else an
  /// idle row. It is always mounted because it anchors the ad strip.
  final Track? track;
  final VoidCallback? onTap;
  const MiniBar({this.track, this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = RtPlayer.I;
    return ListenableBuilder(
      // AppStore too: a rename in the library or the player must show here
      // immediately, and the player object alone does not notify on renames.
      listenable: Listenable.merge([player, AppStore.I]),
      builder: (context, _) {
        final t = track ??
            player.current ??
            AppStore.I.trackById(AppStore.I.lastTrackId);
        final idle = t == null;
        // Engine has nothing loaded (fresh launch / stopped) but this audio was
        // played before → show it as resumable instead of an empty bar.
        final resume = t != null && player.current == null;
        final durMs = idle
            ? 0
            : (resume
                ? t.durationMs
                : (player.duration?.inMilliseconds ?? t.durationMs));

        void openPlayer() {
          if (t == null) return;
          if (onTap != null) {
            onTap!();
            return;
          }
          final loaded = RtPlayer.I.current != null;
          openPlayerPage(
            context,
            track: t,
            contextTracks:
                loaded ? const [] : AppStore.I.visibleTracksSorted.toList(),
            // Opening the page is a look, never a play. The play button on the
            // page starts a remembered track (this used to auto-play on tap).
            startPlayback: false,
          );
        }

        void playPause() {
          if (t == null) return;
          if (player.current == null) {
            // Remembered track: build the queue around it, exactly like tapping
            // its row in the library.
            RtPlayer.I.play(t,
                context: AppStore.I.visibleTracksSorted.toList());
          } else {
            player.toggle();
          }
        }

        return SafeArea(
          top: false,
          child: Card(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  onTap: idle ? null : openPlayer,
                  leading: idle
                      ? Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: scheme.surfaceContainerHighest,
                          ),
                          child: Icon(Icons.music_off_outlined,
                              color: scheme.onSurfaceVariant),
                        )
                      : CoverArt(
                          seed: t.id,
                          size: 38,
                        ),
                  title: Text(idle ? 'Nothing playing' : t.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: idle ? scheme.onSurfaceVariant : null)),
                  subtitle: idle
                      ? Text('Tap a track to start',
                          style: Theme.of(context).textTheme.labelSmall)
                      : resume
                          ? Text(
                              durMs > 0
                                  ? 'Last played · ${mmss(durMs)} · tap play to resume'
                                  : 'Last played · tap play to resume',
                              style: Theme.of(context).textTheme.labelSmall,
                              overflow: TextOverflow.ellipsis,
                            )
                          : StreamBuilder<Duration>(
                              stream: player.positionStream,
                              builder: (c, pos) => Text(
                                '${mmss((pos.data ?? Duration.zero).inMilliseconds)} / '
                                '${durMs > 0 ? mmss(durMs) : '—'}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                  // Skip previous / play-pause / skip next, always reachable
                  // without opening the full player.
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Previous',
                      onPressed:
                          idle || resume ? null : () => player.skipPrev(),
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    // Engine-stream-driven so the glyph flips the instant
                    // playback state changes (never a stale ▶).
                    StreamBuilder<bool>(
                      stream: player.playingStream,
                      initialData: player.playing,
                      builder: (c, s) {
                        final isPlaying = s.data ?? false;
                        return IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: isPlaying ? 'Pause' : 'Play',
                          onPressed: idle ? null : playPause,
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (child, anim) => ScaleTransition(
                              scale: anim,
                              child:
                                  FadeTransition(opacity: anim, child: child),
                            ),
                            child: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              key: ValueKey(isPlaying),
                              color: scheme.onSurface,
                            ),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Next',
                      onPressed: idle || resume ? null : () => player.skipNext(),
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ]),
                ),
                if (!idle && !resume)
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
        );
      },
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

/// Media picking and folder scanning run natively over the Storage Access
/// Framework (see MainActivity): scoped storage denies raw File access to
/// DCIM/Movies/Download even with READ_MEDIA_* (those don't grant directory
/// listing), and SAF needs no storage permission at all. Only content:// URIs
/// come back — nothing is copied, moved or extracted.
const _mediaChannel = MethodChannel('com.buildwithanshul.reeltunes/media');

String _extensionOf(String nameOrPath) {
  final dot = nameOrPath.lastIndexOf('.');
  if (dot < 0 || dot == nameOrPath.length - 1) return '';
  return nameOrPath.substring(dot + 1).toLowerCase();
}

String _titleFromName(String name) => name
    .replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '')
    .trim();

/// Picks media over SAF and returns reference Tracks pointing at the
/// content:// URI — videos play their own audio layer, and our delete guard
/// never touches files outside the save root.
Future<List<Track>> _pickMedia({required bool folder, bool single = false}) async {
  List<dynamic> rows;
  try {
    rows = await _mediaChannel.invokeMethod<List<dynamic>>(
            folder
                ? 'pickMediaFolder'
                : single
                    ? 'pickMediaFile'
                    : 'pickMediaFiles') ??
        const <dynamic>[];
  } on MissingPluginException {
    throw Exception('Media import is unavailable on this device.');
  } on PlatformException catch (e) {
    throw Exception(e.message ?? e.code);
  }

  final picked = <Track>[];
  for (final raw in rows) {
    if (raw is! Map) continue;
    final uri = raw['uri']?.toString() ?? '';
    final name = raw['name']?.toString() ?? '';
    final ext = _extensionOf(name);
    if (uri.isEmpty || !_mediaExtensions.contains(ext)) continue;
    final modified = (raw['modified'] as num?)?.toInt() ?? 0;
    picked.add(Track(
      id: _trackId(),
      title: _titleFromName(name),
      source: _videoExtensions.contains(ext) ? 'video' : 'file',
      path: uri,
      fileName: name,
      folderIds: const [],
      // File timestamp, not import time: when a folder holds 200 clips and
      // the free plan keeps 25, "latest" must mean newest file.
      addedAtMs:
          modified > 0 ? modified : DateTime.now().millisecondsSinceEpoch,
    ));
  }
  return picked;
}

/// Adds as many tracks as the current tier allows and returns that count.
/// Callers surface the cap; nothing is ever imported past it silently.
int _addWithinCap(List<Track> picked) {
  var added = 0;
  for (final t in picked) {
    if (!Entitlements.I.canAddTracks(AppStore.I.tracks.length)) break;
    // Two files called "Video from Instagram" must stay distinguishable.
    t.title = AppStore.I.uniqueTitle(t.title);
    AppStore.I.addTrack(t);
    added++;
  }
  return added;
}

/// Free tier check before a picker/download starts. Returns true when the
/// import is blocked, and shows the paywall so the refusal is never silent.
bool paywallIfAtTrackCap(BuildContext? context, {String? reason}) {
  final max = Entitlements.I.maxTracks;
  if (Entitlements.I.importBlockReason(AppStore.I.tracks.length) == null) {
    return false;
  }
  if (context != null && context.mounted) {
    showPaywallSheet(context,
        reason: reason ?? 'Free tier holds $max audios');
  }
  return true;
}

/// Pick audio/video files (one or many). Returns how many were imported.
Future<int> importMediaFiles([BuildContext? context]) async {
  if (paywallIfAtTrackCap(context)) return 0;
  final picked = await _pickMedia(folder: false);
  if (context != null && !context.mounted) return 0;
  return _importPicked(context, picked);
}

/// Pick a folder and import every audio/video inside it, recursively —
/// DCIM-style folders keep their clips in sub-folders such as Camera/.
Future<int> importMediaFolder([BuildContext? context]) async {
  if (paywallIfAtTrackCap(context)) return 0;
  final picked = await _pickMedia(folder: true);
  if (context != null && !context.mounted) return 0;
  return _importPicked(context, picked);
}

/// Pick exactly one audio/video file and import it. Returns the Track when it
/// was added, null when the picker was dismissed or the cap blocked it.
Future<Track?> importMediaFile([BuildContext? context]) async {
  if (paywallIfAtTrackCap(context)) return null;
  final picked = await _pickMedia(folder: false, single: true);
  if (picked.isEmpty) return null;
  if (context != null && !context.mounted) return null;
  final added = await _importPicked(context, picked);
  return added == 0 ? null : picked.first;
}

Future<Track?> importAudioFile([BuildContext? context]) async {
  // Audio OR video, reference-imported over SAF (nothing copied): a video
  // here simply plays its own audio layer. Used by Add reel's
  // "Or import a file instead".
  return importMediaFile(context);
}

/// Adds [picked], asking first when some are already in the library.
///
/// Skip  → only new files are added (plus anything the user removed earlier,
///         which is no longer in the library and comes back).
/// Add anyway → duplicates become separate entries, like a file manager.
Future<int> _importPicked(BuildContext? context, List<Track> picked) async {
  if (picked.isEmpty) return 0;
  final store = AppStore.I;

  // The same file can appear twice inside one pick; keep the first only.
  final unique = <Track>[];
  final seen = <String>{};
  for (final t in picked) {
    final key = t.fileName.toLowerCase();
    if (key.isNotEmpty && !seen.add(key)) continue;
    unique.add(t);
  }
  // Newest file first. The free cap takes a prefix of this list, so "the
  // latest 25" stays true no matter what order the picker returned.
  unique.sort((a, b) => b.addedAtMs.compareTo(a.addedAtMs));

  final dupes = unique
      .where((t) => store.trackByFileName(t.fileName) != null)
      .length;
  final restores = unique
      .where((t) =>
          t.fileName.isNotEmpty &&
          store.trackByFileName(t.fileName) == null &&
          store.hiddenFileNames.contains(t.fileName))
      .length;

  var skipDupes = true;
  if (dupes > 0) {
    if (context == null || !context.mounted) return 0;
    final addAnyway = await _askDuplicateImport(context, dupes, restores);
    if (addAnyway == null) return 0; // sheet dismissed = do nothing
    skipDupes = !addAnyway;
  }

  final toAdd = skipDupes
      ? unique
          .where((t) => store.trackByFileName(t.fileName) == null)
          .toList()
      : unique;
  return _addWithinCap(toAdd);
}

/// Returns true = add anyway, false = skip duplicates, null = dismissed.
Future<bool?> _askDuplicateImport(
    BuildContext context, int dupes, int restores) {
  return showModalBottomSheet<bool>(
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
              child: Text('Some files are already added',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            '$dupes ${dupes == 1 ? 'file is' : 'files are'} already in your '
            'library.'
            '${restores > 0 ? ' $restores you removed earlier will be added '
                'back.' : ''}',
            style: Theme.of(sheetCtx).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(children: [
            TextButton(
              onPressed: () => Navigator.pop(sheetCtx, false),
              child: const Text('Skip duplicates'),
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
}

String _trackId() => 't${DateTime.now().microsecondsSinceEpoch}';

