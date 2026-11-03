// Top-anchored toast.
//
// SnackBars live at the bottom, where the player bar and the import pill sit,
// so an error there is easy to miss and covers controls. This shows one short
// sentence at the top of the screen, slides away on its own, and never blocks
// taps.

import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _active;
Timer? _timer;

/// Shows [message] at the top of the screen for a couple of seconds.
/// Calling it again replaces the previous toast instead of stacking.
///
/// [error] only changes the icon and tint: the sentence itself is always the
/// generic one the user should see (exact reasons go to logcat).
void showTopToast(BuildContext context, String message, {bool error = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _timer?.cancel();
  _active?.remove();
  _active = null;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TopToast(
      message: message,
      error: error,
      onDone: () {
        if (_active == entry) {
          _active = null;
        }
        entry.remove();
      },
    ),
  );
  _active = entry;
  overlay.insert(entry);
}

class _TopToast extends StatefulWidget {
  final String message;
  final bool error;
  final VoidCallback onDone;
  const _TopToast({
    required this.message,
    required this.onDone,
    this.error = false,
  });

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _timer = Timer(const Duration(milliseconds: 2600), _leave);
  }

  Future<void> _leave() async {
    if (_leaving || !mounted) return;
    _leaving = true;
    await _c.reverse();
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = widget.error ? scheme.errorContainer : scheme.inverseSurface;
    final fg = widget.error ? scheme.onErrorContainer : scheme.onInverseSurface;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.6),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
            child: FadeTransition(
              opacity: _c,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _leave,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(children: [
                      Icon(
                          widget.error
                              ? Icons.error_outline
                              : Icons.info_outline,
                          size: 18,
                          color: fg),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.message,
                          style: TextStyle(color: fg, fontSize: 14),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
