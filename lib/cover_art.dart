// Cover art: 48 bundled dark mesh-gradient images. Every audio and playlist
// gets one deterministically from its id, so the same track always looks the
// same and two neighbours never repeat.
import 'package:flutter/material.dart';

/// Neon accent used for glow, selection and primary CTAs.
const Color kNeonBlue = Color(0xFF2C8BFF);

const int coverCount = 48;

/// Shadow tints, one per image index, used for the neon bloom.
const List<Color> _accents = [
  Color(0xFF2C8BFF), Color(0xFF22D3EE), Color(0xFF818CF8), Color(0xFFA855F7),
  Color(0xFFEC4899), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFF3B82F6),
  Color(0xFF38BDF8), Color(0xFF6366F1), Color(0xFFF472B6), Color(0xFF2DD4BF),
];

int coverIndexFor(String seed) {
  if (seed.isEmpty) return 0;
  var h = 0;
  for (final unit in seed.codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return h % coverCount;
}

String coverAssetFor(String seed) =>
    'assets/covers/cover_${coverIndexFor(seed).toString().padLeft(2, '0')}.webp';

Color coverAccent(String seed) =>
    _accents[coverIndexFor(seed) % _accents.length];

/// Square album art.
///
/// [size] is a logical pixel edge; leave it null and the widget fills the
/// space its parent gives it (used by the full-page player).
class CoverArt extends StatelessWidget {
  final String seed;
  final double? size;
  final bool glow;
  final BorderRadius? radius;

  const CoverArt({
    super.key,
    required this.seed,
    this.size,
    this.glow = false,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final art = _art(context);
    if (size == null) return art;
    return SizedBox(width: size, height: size, child: art);
  }

  Widget _art(BuildContext context) {
    final accent = coverAccent(seed);
    return LayoutBuilder(
      builder: (context, constraints) {
        final edge = size ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width);
        final r = radius ?? BorderRadius.circular(edge * 0.2);
        return Container(
          decoration: BoxDecoration(
            borderRadius: r,
            color: const Color(0xFF101827),
            boxShadow: glow
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.5),
                      blurRadius: 26,
                      spreadRadius: 1,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: r,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  coverAssetFor(seed),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      ColoredBox(color: accent.withValues(alpha: 0.35)),
                ),
                // Keeps white icons readable on the brightest images.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.05),
                        Colors.black.withValues(alpha: lo(edge)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Bigger art needs less darkening.
  double lo(double edge) => edge > 160 ? 0.18 : 0.22;
}

/// Simple two-stop gradient tile for playlists. Playlists never borrow the
/// abstract artwork the audios use; each one gets its own calm gradient from
/// its id, so a playlist is always recognisable at a glance.
class PlaylistArt extends StatelessWidget {
  final String seed;
  final double? size;
  final bool glow;
  final BorderRadius? radius;

  const PlaylistArt({
    super.key,
    required this.seed,
    this.size,
    this.glow = false,
    this.radius,
  });

  static const List<List<Color>> _pairs = [
    [Color(0xFF1D4ED8), Color(0xFF0B1A33)],
    [Color(0xFF0E7490), Color(0xFF081C26)],
    [Color(0xFF4F46E5), Color(0xFF12102B)],
    [Color(0xFF0F766E), Color(0xFF06201C)],
    [Color(0xFF7C3AED), Color(0xFF180F2E)],
    [Color(0xFFB91C1C), Color(0xFF210B0F)],
    [Color(0xFF9A3412), Color(0xFF1E0F08)],
    [Color(0xFFBE185D), Color(0xFF240A18)],
    [Color(0xFF155E75), Color(0xFF071A22)],
    [Color(0xFF334155), Color(0xFF0B111B)],
  ];

  int get _index => coverIndexFor(seed) % _pairs.length;

  @override
  Widget build(BuildContext context) {
    final colors = _pairs[_index];
    final accent = colors.first;
    final art = LayoutBuilder(
      builder: (context, constraints) {
        final edge = size ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width);
        final r = radius ?? BorderRadius.circular(edge * 0.2);
        return Container(
          decoration: BoxDecoration(
            borderRadius: r,
            boxShadow: glow
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.45),
                      blurRadius: 26,
                      spreadRadius: 1,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: r,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: _index.isEven
                      ? Alignment.topLeft
                      : Alignment.topRight,
                  end: Alignment.bottomCenter,
                  colors: colors,
                ),
              ),
              child: DecoratedBox(
                // Soft light from the top so the flat fill still has depth.
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.6, -0.8),
                    radius: 1.4,
                    colors: [
                      Colors.white.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (size == null) return art;
    return SizedBox(width: size, height: size, child: art);
  }
}
