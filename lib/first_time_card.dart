// The "First time here?" nudge. One widget so Home and Library always match.

import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'models.dart';
import 'sheets.dart';
import 'ui.dart';

class FirstTimeCard extends StatelessWidget {
  /// Library sits tighter than Home (12 dp vs 5% gutters).
  final bool tight;
  const FirstTimeCard({super.key, this.tight = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final side = tight ? 12.0 : context.pw(5);
    return Padding(
      padding: EdgeInsets.fromLTRB(side, context.ph(1.0), side, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showGuideSheet(context),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: context.pw(3.6), vertical: context.ph(1.2)),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kNeonBlue.withValues(alpha: 0.45)),
            boxShadow: [
              BoxShadow(
                color: kNeonBlue.withValues(alpha: 0.22),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, color: kNeonBlue, size: context.rem(1.2)),
              SizedBox(width: context.pw(3)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('First time here?',
                        style: TextStyle(
                            fontSize: context.rem(0.86),
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: context.ph(0.3)),
                    Text(
                      'Tap here to check the guide.',
                      style: TextStyle(
                          fontSize: context.rem(0.72),
                          color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => AppStore.I.dismissGuideBanner(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
