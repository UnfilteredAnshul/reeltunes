// Smart Loop settings screen.
// Lets the user choose how many times each audio repeats before moving on.
import 'package:flutter/material.dart';

import 'entitlements.dart';
import 'library.dart';
import 'models.dart';
import 'player.dart';

class SmartLoopScreen extends StatefulWidget {
  const SmartLoopScreen({super.key});
  @override
  State<SmartLoopScreen> createState() => _SmartLoopScreenState();
}

class _SmartLoopScreenState extends State<SmartLoopScreen> {
  bool _enabled = true;
  int _min = 3;
  int _max = 6;

  @override
  void initState() {
    super.initState();
    _enabled = RtPlayer.I.loop == RtLoop.smart ||
        RtPlayer.I.loop == RtLoop.customRange;
    _min = AppStore.I.rangeMin;
    _max = AppStore.I.rangeMax;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('Smart Loop'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Smart Loop',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text('Let ReelTunes decide how many times to repeat!',
                    style: TextStyle(
                        fontSize: 15, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 24),
                // Enable toggle
                Row(children: [
                  const Text('Enable Smart Loop',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Switch(
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                    activeColor: scheme.primary,
                  ),
                ]),
                const SizedBox(height: 28),
                // Repeat range
                const Text('Repeat Range',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('Choose how many times to repeat each audio',
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _RangePicker(
                      label: 'Min',
                      value: _min,
                      onChanged: (v) => setState(() => _min = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('–', style: TextStyle(
                      fontSize: 18, color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _RangePicker(
                      label: 'Max',
                      value: _max,
                      onChanged: (v) => setState(() => _max = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('×', style: TextStyle(
                      fontSize: 20, color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 20),
                // Adaptive selection
                Row(children: [
                  const Icon(Icons.flash_on, size: 20, color: Colors.amber),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Adaptive selection',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        Text('Learns from your listening',
                            style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Switch(
                    value: true,
                    onChanged: null,
                    activeColor: scheme.primary,
                  ),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  const Icon(Icons.star, size: 20, color: Colors.amber),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Next audio plays automatically',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        Text('Continues playback without interruption',
                            style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Switch(
                    value: true,
                    onChanged: null,
                    activeColor: scheme.primary,
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 30),
          // Done button (full width at bottom)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  // Save settings
                  AppStore.I.setRange(_min, _max);
                  // Apply loop mode
                  if (_enabled) {
                    RtPlayer.I.loop = RtLoop.smart;
                  } else {
                    RtPlayer.I.loop = RtLoop.off;
                  }
                  Navigator.pop(context);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('Done',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RangePicker extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  const _RangePicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(
            fontSize: 12, color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withOpacity(0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant.withOpacity(0.3)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: value,
              dropdownColor: scheme.surfaceContainerHighest,
              style: TextStyle(fontSize: 16, color: scheme.onSurface),
              items: List.generate(10, (i) => i + 1).map((n) {
                return DropdownMenuItem(
                  value: n,
                  child: Text('$n', style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
                );
              }).toList(),
              onChanged: (v) => onChanged(v ?? value),
            ),
          ),
        ),
      ],
    );
  }
}
