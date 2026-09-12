import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A single count in the report's summary row: a number over a label, with a
/// thin accent rail echoing the task card's status colour.
class StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color accent;

  const StatChip({
    super.key,
    required this.label,
    required this.count,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count $label',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.canvasSoft,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 3,
              height: 28,
              margin: const EdgeInsets.only(right: AppSpacing.md),
              decoration: BoxDecoration(
                color: accent,
                borderRadius:
                    const BorderRadius.all(Radius.circular(AppRadius.xs)),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('$count', style: AppText.displayMd),
                Text(label, style: AppText.micro),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
