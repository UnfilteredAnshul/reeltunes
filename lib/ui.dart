import 'package:flutter/material.dart';

/// Screen-relative sizing. Flutter has no CSS units, so these are the
/// equivalents used across the app:
///
///  * [pw] / [ph] — percentages of the screen (%)
///  * [rem]       — type size: 1 rem = 16 logical px, scaled by the OS
///                  font-size setting
///  * [em]        — padding/tap targets relative to a font size
///  * [u]         — 1% of the shortest screen side, for nested spacing
///
/// Borders, corner radii and shadow blur stay in raw logical pixels: they are
/// hairlines and glows, not layout.
extension UiMetrics on BuildContext {
  Size get _size => MediaQuery.sizeOf(this);

  /// Percentage of the screen width.
  double pw(num percent) => _size.width * percent / 100;

  /// Percentage of the screen height.
  double ph(num percent) => _size.height * percent / 100;

  /// 1% of the shortest side — the "root em" for nested layout.
  double get u => _size.shortestSide / 100;

  /// Type size in rem.
  double rem(num r) =>
      MediaQuery.textScalerOf(this).scale(r * 16.0);

  /// Padding relative to a font size (CSS em).
  double em(num e, {double fontSize = 14}) =>
      MediaQuery.textScalerOf(this).scale(e * fontSize);

  /// Narrow phones get tighter spacing.
  bool get compact => _size.width < 370;
}
