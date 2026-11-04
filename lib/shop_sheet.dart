// Coin shop: the Free-tier reward loop. Watch a rewarded ad → earn coins →
// spend them on timed perks. Shown only while the plan is Free
// (`Entitlements.shopAvailable`); a coin purchase never changes the plan, so
// the shop and the earn button stay available even while a 24 h ad-free window
// is running.
//
// All amounts are local constants for now; production moves verification to
// AdMob SSV + a server ledger (docs/free-vs-pro.md §3).

import 'package:flutter/material.dart';

import 'ads.dart';
import 'coins.dart';
import 'entitlements.dart';
import 'top_toast.dart';

const Color coinGold = Color(0xFFD9A400);
const Color coinGoldLight = Color(0xFFFFD24A);
const Color coinInk = Color(0xFF3A2A00);

/// Gold balance pill shown in the library app bar. Tapping opens the shop.
class CoinBalanceChip extends StatelessWidget {
  final VoidCallback? onTap;
  const CoinBalanceChip({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CoinWallet.I,
      builder: (context, _) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE9A8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE3B23C)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.monetization_on_rounded,
                  size: 18, color: Color(0xFFB07D00)),
              const SizedBox(width: 4),
              Text(
                '${CoinWallet.I.balance}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF6B4B00),
                    fontSize: 13),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

Future<void> showShopSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _ShopSheet(),
  );
}

class _ShopSheet extends StatefulWidget {
  const _ShopSheet();

  @override
  State<_ShopSheet> createState() => _ShopSheetState();
}

class _ShopSheetState extends State<_ShopSheet> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Warm the rewarded unit the moment the shop opens: by the time the user
    // taps "watch", it is usually ready.
    Ads.I.preloadRewarded();
  }

  Future<void> _watchAd() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final earned = await Ads.I.showRewarded();
      if (!mounted) return;
      if (earned) {
        await CoinWallet.I.addFromAd();
        if (mounted) {
          showTopToast(context, '+${CoinWallet.coinsPerAd} coins');
        }
      } else {
        showTopToast(context, 'No ad available right now — try again.',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buyAdFree() async {
    if (_busy) return;
    final coins = CoinWallet.I;
    if (!coins.canAffordAdFree) {
      showTopToast(context,
          'Need ${CoinWallet.adFreeCost} coins — watch an ad to earn more',
          error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await coins.buyAdFree();
    if (!mounted) return;
    setState(() => _busy = false);
    showTopToast(context,
        ok ? 'No ads for 24 hours · shop stays open' : 'Not enough coins',
        error: !ok);
  }

  Future<void> _buyExtraTracks() async {
    if (_busy) return;
    final coins = CoinWallet.I;
    if (!coins.canAffordExtraTracks) {
      showTopToast(context,
          'Need ${CoinWallet.extraTracksCost} coins — watch an ad to earn more',
          error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await coins.buyExtraTracks();
    if (!mounted) return;
    setState(() => _busy = false);
    showTopToast(
        context,
        ok
            ? '+${CoinWallet.extraTracks} audio slots for 30 days'
            : 'Not enough coins',
        error: !ok);
  }

  static String _when(DateTime? d) {
    if (d == null) return '';
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day}/${d.month} · $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final coins = CoinWallet.I;

    return ListenableBuilder(
      listenable: coins,
      builder: (context, _) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.monetization_on_rounded,
                    color: coinGold, size: 28),
                const SizedBox(width: 10),
                Text('Coin shop',
                    style:
                        text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                CoinBalanceChip(),
              ]),
              const SizedBox(height: 6),
              Text(
                'Watch a short video, earn ${CoinWallet.coinsPerAd} coins, and '
                'spend them on perks. Coins do not change your plan.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              // The gold earn button. Same expand/collapse idea as the import
              // FAB, but always labelled here so the action is obvious.
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: coinGoldLight,
                  foregroundColor: coinInk,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _busy ? null : _watchAd,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: coinInk))
                    : const Icon(Icons.smart_display_rounded),
                label: Text(
                  _busy
                      ? 'Loading ad…'
                      : 'Watch ad · +${CoinWallet.coinsPerAd} coins',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (coins.adFree) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.check_circle,
                      size: 18, color: coinGold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No ads until ${_when(coins.adFreeUntil)} — you can '
                      'still earn and spend coins.',
                      style: text.bodySmall,
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: 18),
              Text('Perks',
                  style: text.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              _ShopTile(
                icon: Icons.block_outlined,
                title: 'No ads · 24 hours',
                subtitle: coins.adFree
                    ? 'Active until ${_when(coins.adFreeUntil)}'
                    : 'Hide every banner and the playlist ads for a day',
                cost: CoinWallet.adFreeCost,
                active: coins.adFree,
                enabled: !_busy && coins.canAffordAdFree,
                onBuy: _buyAdFree,
              ),
              const SizedBox(height: 8),
              _ShopTile(
                icon: Icons.library_add_outlined,
                title: '+${CoinWallet.extraTracks} audio slots · 30 days',
                subtitle: coins.extraTracksActive
                    ? 'Active until ${_when(coins.extraTracksUntil)} · '
                        '${Entitlements.I.maxTracks} audios available'
                    : 'Grow the Free 25 up to '
                        '${Entitlements.freeMaxTracks + CoinWallet.extraTracks}',
                cost: CoinWallet.extraTracksCost,
                active: coins.extraTracksActive,
                enabled: !_busy && coins.canAffordExtraTracks,
                onBuy: _buyExtraTracks,
              ),
              const SizedBox(height: 14),
              Text(
                'Prefer no ads permanently? Pro also removes the limits.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShopTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final int cost;
  final bool active;
  final bool enabled;
  final VoidCallback onBuy;

  const _ShopTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.cost,
    required this.active,
    required this.enabled,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Icon(icon, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                    child: Text(title,
                        style:
                            text.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
                if (active) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.check_circle, size: 16, color: coinGold),
                ],
              ]),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: enabled ? onBuy : null,
          style: TextButton.styleFrom(
            foregroundColor: coinInk,
            backgroundColor: enabled ? coinGoldLight : scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.monetization_on_rounded, size: 16),
            const SizedBox(width: 4),
            Text('$cost',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}
