// Home: brand header, first-run card, quick actions, recent audios and
// playlists. Everything is sized from the screen so it works on any phone.
import 'package:flutter/material.dart';

import 'ads.dart';
import 'coins.dart';
import 'cover_art.dart';
import 'entitlements.dart';
import 'first_time_card.dart';
import 'library.dart';
import 'models.dart';
import 'player.dart';
import 'sheets.dart';
import 'shop_sheet.dart';
import 'top_toast.dart';
import 'ui.dart';

class HomeScreen extends StatefulWidget {
  /// Open the Library tab (recent audios → "See all").
  final VoidCallback? onOpenLibrary;

  /// Open the Library tab with the playlists section expanded.
  final VoidCallback? onOpenPlaylists;

  const HomeScreen({super.key, this.onOpenLibrary, this.onOpenPlaylists});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _adBusy = false;

  Future<void> _watchAd() async {
    if (_adBusy) return;
    setState(() => _adBusy = true);
    try {
      await watchRewardedAd(context);
    } finally {
      if (mounted) setState(() => _adBusy = false);
    }
  }

  /// Pro home: "Add reel" opens the paste-a-link sheet directly. Free reaches
  /// the same sheet through the Library FAB, which paywalls at the cap first.
  void _openAddReel() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const AddReelSheet(),
    );
  }

  /// Shuffle across the whole library (Free tier included — it uses the same
  /// visible list the Library tab shows).
  Future<void> _shuffleAll() async {    final list = AppStore.I.visibleTracksSorted.toList();
    if (list.isEmpty) {
      showTopToast(context, 'No audios yet. Add a reel or import a file.');
      return;
    }
    list.shuffle();
    await RtPlayer.I.play(list.first, context: list, playingFrom: 'Shuffle');
    if (!mounted) return;
    openPlayerPage(
      context,
      track: list.first,
      contextTracks: const [], // queue already built; player renders only
      startPlayback: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      // Transparent: the mesh art comes from RootScreen behind every tab.
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge(
              [store, Entitlements.I, CoinWallet.I, RtPlayer.I]),
          builder: (context, _) {
            final recent =
                List<Track>.from(store.tracks.reversed).take(8).toList();
            // visibleFolders respects the Free playlist cap — the old
            // `store.folders` call leaked the hidden ones.
            final playlists = store.visibleFolders;
            final cardW = context.pw(31);
            final rowH = cardW + context.rem(3.0);

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(context.pw(5),
                        context.ph(0.6), context.pw(5), context.ph(0.4)),
                    child: _Header(scheme: scheme),
                  ),
                ),
                if (!store.guideBannerDismissed)
                  SliverToBoxAdapter(child: FirstTimeCard()),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        context.pw(5), context.ph(1.4), context.pw(5), 0),
                    child: _Actions(
                      busy: _adBusy,
                      onImport: () => openImportSheet(context),
                      onEarnCoins: _watchAd,
                      onShop: () => showShopSheet(context),
                      onAddReel: _openAddReel,
                    ),
                  ),
                ),

                // ---- Recently Played ----
                _SectionHeader(
                  title: 'Recently Played',
                  onSeeAll: recent.isEmpty ? null : widget.onOpenLibrary,
                ),
                if (recent.isEmpty)
                  const _EmptyRow(
                    icon: Icons.music_note_outlined,
                    text: 'Nothing played yet. Add a reel to start.',
                  )
                else
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: rowH,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.symmetric(horizontal: context.pw(5)),
                        itemCount: recent.length,
                        separatorBuilder: (_, __) =>
                            SizedBox(width: context.pw(3.4)),
                        itemBuilder: (_, i) => _TrackCard(
                          track: recent[i],
                          width: cardW,
                        ),
                      ),
                    ),
                  ),

                // ---- In-feed banner: free tier only, 320x50 like the sticky
                // one above the mini bar. Sits between the two sections so it
                // never splits a row.
                const SliverToBoxAdapter(child: PlaylistAdCard()),

                // ---- Your Playlists ----
                _SectionHeader(
                  title: 'Your Playlists',
                  onSeeAll: widget.onOpenPlaylists,
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: rowH,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: context.pw(5)),
                      itemCount: playlists.length + 1,
                      separatorBuilder: (_, __) =>
                          SizedBox(width: context.pw(3.4)),
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          return _ShuffleAllCard(
                            width: cardW,
                            onTap: _shuffleAll,
                          );
                        }
                        final f = playlists[i - 1];
                        return _PlaylistCard(
                          folder: f,
                          width: cardW,
                          onOpen: () {
                            AppStore.I.selectFolder(f.id);
                            widget.onOpenLibrary?.call();
                          },
                        );
                      },
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(context.pw(5),
                        context.ph(3.5), context.pw(5), context.ph(18)),
                    child: Text(
                      'Everything stays on this phone.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.rem(0.74),
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Logo mark + wordmark. The mark is scaled from the wordmark's own type size
/// so they always line up, whatever the OS font scale is.
class _Header extends StatelessWidget {
  final ColorScheme scheme;
  const _Header({required this.scheme});

  @override
  Widget build(BuildContext context) {
    // 1.75 rem == 28 px at the default OS scale, matching the Library title.
    final size = context.rem(1.75);
    return Row(
      children: [
        Image.asset(
          'assets/logo_mark.png',
          height: size * 0.86,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => Icon(Icons.graphic_eq,
              size: size * 0.95, color: kNeonBlue),
        ),
        SizedBox(width: context.rem(0.55)),
        Text(
          'ReelTunes',
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
            color: scheme.onSurface,
          ),
        ),
        const Spacer(),
        if (Entitlements.I.shopAvailable)
          CoinBalanceChip(onTap: () => showShopSheet(context)),
      ],
    );
  }
}

/// Home action row. Free gets Import / earn coins / shop; Pro gets one wide
/// Import tile plus Add reel, since the shop and the coin ad are Free-only.
class _Actions extends StatelessWidget {
  final bool busy;
  final VoidCallback onImport;
  final VoidCallback onEarnCoins;
  final VoidCallback onShop;
  final VoidCallback onAddReel;
  const _Actions({
    required this.busy,
    required this.onImport,
    required this.onEarnCoins,
    required this.onShop,
    required this.onAddReel,
  });

  @override
  Widget build(BuildContext context) {
    final gap = context.pw(2.6);
    if (Entitlements.I.isPro) {
      // Stretch makes both tiles share the taller one's height, so the import
      // tile can carry a second line without the row looking ragged.
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: _ActionTile(
                icon: Icons.folder_open_rounded,
                label: 'Import',
                sub: 'files or a folder',
                onTap: onImport,
                large: true,
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              flex: 2,
              child: _ActionTile(
                icon: Icons.smart_display_outlined,
                label: 'Add reel',
                sub: 'paste a link',
                onTap: onAddReel,
                large: true,
              ),
            ),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.folder_open_rounded,
            label: 'Import',
            onTap: onImport,
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: _ActionTile(
            icon: Icons.smart_display_outlined,
            label: busy ? 'Loading…' : 'Earn coins',
            onTap: busy ? null : onEarnCoins,
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: _ActionTile(
            icon: Icons.storefront_outlined,
            label: 'Shop',
            onTap: onShop,
          ),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Optional second line. Only the Pro tiles use it.
  final String? sub;

  /// Pro tile: bigger icon and type, fills the row height.
  final bool large;
  final VoidCallback? onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.sub,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: large
              ? EdgeInsets.symmetric(
                  horizontal: context.em(0.5), vertical: context.ph(1.6))
              : EdgeInsets.symmetric(
                  horizontal: context.em(0.4), vertical: context.ph(1.2)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kNeonBlue.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  color: kNeonBlue,
                  size: large ? context.rem(1.75) : context.rem(1.35)),
              SizedBox(height: context.ph(large ? 0.8 : 0.6)),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: context.rem(large ? 0.95 : 0.72),
                    fontWeight: FontWeight.w600),
              ),
              if (sub != null) ...[
                SizedBox(height: context.ph(0.2)),
                Text(
                  sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: context.rem(0.66),
                      color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  const _SectionHeader({required this.title, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            context.pw(5), context.ph(2.2), context.pw(2), 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: context.rem(1.0), fontWeight: FontWeight.w700),
              ),
            ),
            if (onSeeAll != null)
              TextButton(
                onPressed: onSeeAll,
                child: Text('See all',
                    style: TextStyle(fontSize: context.rem(0.78))),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  final Track track;
  final double width;
  const _TrackCard({required this.track, required this.width});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = RtPlayer.I.current?.id == track.id;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => RtPlayer.I.play(track,
            context: AppStore.I.tracks, playingFrom: 'Home'),
        onLongPress: () => showTrackMenu(context, track),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            CoverArt(seed: track.id, size: width, glow: isCurrent),
            SizedBox(height: context.rem(0.55)),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rem(0.8),
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                color: isCurrent ? kNeonBlue : scheme.onSurface,
              ),
            ),
            Text(
              track.source,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rem(0.68),
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final Folder folder;
  final double width;
  final VoidCallback onOpen;
  const _PlaylistCard({
    required this.folder,
    required this.width,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = AppStore.I.tracks
        .where((t) => t.folderIds.contains(folder.id))
        .length;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        // Hold = playlist menu (rename / shuffle this playlist / delete).
        onLongPress: () => showFolderMenu(context, folder),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            PlaylistArt(seed: folder.id, size: width),
            SizedBox(height: context.rem(0.55)),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: context.rem(0.8), fontWeight: FontWeight.w600),
            ),
            Text(
              '$count ${count == 1 ? 'audio' : 'audios'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rem(0.68),
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First card of the playlists row: shuffle everything.
class _ShuffleAllCard extends StatelessWidget {
  final double width;
  final VoidCallback onTap;
  const _ShuffleAllCard({required this.width, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = AppStore.I.visibleTracksSorted.length;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: width,
              height: width,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(width * 0.2),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    kNeonBlue.withValues(alpha: 0.95),
                    const Color(0xFF22D3EE).withValues(alpha: 0.9),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: kNeonBlue.withValues(alpha: 0.45),
                    blurRadius: 22,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(Icons.shuffle_rounded,
                  color: Colors.white, size: width * 0.36),
            ),
            SizedBox(height: context.rem(0.55)),
            Text('Shuffle all',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: context.rem(0.8), fontWeight: FontWeight.w700)),
            Text('$count audios',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: context.rem(0.68),
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8))),
          ],
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Container(
        margin: EdgeInsets.fromLTRB(context.pw(5), 0, context.pw(5), 0),
        padding: EdgeInsets.symmetric(
            horizontal: context.pw(4), vertical: context.ph(2)),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          border: Border.all(color: kNeonBlue.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(icon, color: kNeonBlue, size: context.rem(1.3)),
            SizedBox(width: context.pw(3)),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: context.rem(0.78),
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
