// Home screen: featured banner, recently played, your playlists.
// Mirrors the reference design: dark, no gradients, big album art chips.
import 'dart:async';

import 'package:flutter/material.dart';

import 'ads.dart';
import 'coins.dart';
import 'entitlements.dart';
import 'library.dart';
import 'library_sync.dart';
import 'models.dart';
import 'player.dart';
import 'settings_screen.dart';
import 'shop_sheet.dart';
import 'sheets.dart';
import 'top_toast.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _idleTicker;
  DateTime _nextNudge = DateTime.now().add(const Duration(seconds: 7));
  bool _importExpanded = false;
  bool _adBusy = false;

  @override
  void initState() {
    super.initState();
    _idleTicker =
        Timer.periodic(const Duration(milliseconds: 500), _idleTick);
  }

  @override
  void dispose() {
    _idleTicker?.cancel();
    super.dispose();
  }

  void _noteInteraction() {
    _nextNudge = DateTime.now().add(const Duration(seconds: 7));
    if (_importExpanded) setState(() => _importExpanded = false);
  }

  void _idleTick(Timer _) {
    if (!mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      _noteInteraction();
      return;
    }
    if (RtPlayer.I.playing) {
      _noteInteraction();
      return;
    }
    if (_importExpanded) return;
    if (DateTime.now().isBefore(_nextNudge)) return;

    setState(() => _importExpanded = true);
  }

  void _openAddReel() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const AddReelSheet(),
    );
  }

  void _watchAd() {}

  void _openImportSheet() {}

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final scheme = Theme.of(context).colorScheme;
    final e = Entitlements.I;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Listener(
        onPointerDown: (_) => _noteInteraction(),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                child: Row(children: [
                  const Text('ReelTunes',
                      style: TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w700,
                          letterSpacing: -0.5)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => SettingsScreen())),
                  ),
                  if (e.shopAvailable) ...[
                    IconButton(
                      tooltip: 'Coin shop',
                      icon: const Icon(Icons.storefront_outlined),
                      onPressed: () => showShopSheet(context),
                    ),
                    CoinBalanceChip(onTap: () => showShopSheet(context)),
                  ],
                ]),
              ),
            ),
            // Featured banner
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Material(
                  borderRadius: BorderRadius.circular(24),
                  color: scheme.primaryContainer.withOpacity(0.15),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _openAddReel,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Your Sound',
                                  style: TextStyle(
                                      fontSize: 22, fontWeight: FontWeight.w700,
                                      height: 1.1)),
                              const SizedBox(height: 4),
                              const Text('Your Vibe',
                                  style: TextStyle(
                                      fontSize: 22, fontWeight: FontWeight.w700,
                                      height: 1.1)),
                              const SizedBox(height: 8),
                              Text('Collect. Play. Loop.',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _openAddReel,
                                style: FilledButton.styleFrom(
                                  backgroundColor: scheme.primary,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Add reel'),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 120, height: 120,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: scheme.primaryContainer.withOpacity(0.3),
                          ),
                          child: const Icon(Icons.music_note,
                              size: 40, color: Colors.white),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            // Recently Played
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(children: [
                  const Text('Recently Played',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {},
                    child: const Text('See all'),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              sliver: SliverToBoxAdapter(
                child: SizedBox(
                  height: 130,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final t in store.recentlyPlayed.take(5)) ...[
                        _RecentChip(t),
                        const SizedBox(width: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            // Your Playlists
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(children: [
                  const Text('Your Playlists',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {},
                    child: const Text('See all'),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              sliver: SliverToBoxAdapter(
                child: SizedBox(
                  height: 150,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      if (store.folders.isEmpty)
                        _EmptyPlaylistChip()
                      else
                        for (final f in store.folders.take(4)) ...[
                          _PlaylistChip(f),
                          const SizedBox(width: 10),
                        ],
                      const _CreatePlaylistChip(),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 100),
                child: Text(
                  store.tracks.isEmpty
                      ? 'No audios yet. Paste a link or import a file to get started.'
                      : 'Pull to refresh',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: SizedBox(
        width: 200,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const SizedBox(height: 12),
            FloatingActionButton.extended(
              heroTag: 'addReelHome',
              onPressed: _openAddReel,
              label: const Text('Add reel'),
              icon: const Icon(Icons.link),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [AdBanner(), MiniBar()],
      ),
    );
  }
}

class _RecentChip extends StatelessWidget {
  final Track t;
  const _RecentChip(this.t);
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => RtPlayer.I.play(t),
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                height: 80,
                color: scheme.primaryContainer.withOpacity(0.15),
                child: const Icon(Icons.music_note,
                    size: 32, color: Colors.white54),
              ),
            ),
            const SizedBox(height: 8),
            Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(t.source, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _PlaylistChip extends StatelessWidget {
  final Folder f;
  const _PlaylistChip(this.f);
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                height: 80,
                color: scheme.primaryContainer.withOpacity(0.15),
                child: const Icon(Icons.queue_music,
                    size: 32, color: Colors.white54),
              ),
            ),
            const SizedBox(height: 8),
            Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Playlist',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _CreatePlaylistChip extends StatelessWidget {
  const _CreatePlaylistChip();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: scheme.primaryContainer.withOpacity(0.1),
          border: Border.all(color: scheme.primary.withOpacity(0.3)),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 32, color: Colors.white),
            SizedBox(height: 8),
            Text('Create', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Text('Playlist', style: TextStyle(fontSize: 11, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _EmptyPlaylistChip extends StatelessWidget {
  const _EmptyPlaylistChip();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 100,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.surfaceContainerHighest.withOpacity(0.3),
      ),
      child: const Center(
        child: Icon(Icons.queue_music, size: 32, color: Colors.white38),
      ),
    );
  }
}

extension _RecentTracks on AppStore {
  List<Track> get recentlyPlayed => List<Track>.from(tracks).reversed.toList();
}
