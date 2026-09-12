import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A single count in the report's summary row: the number over its label.
///
/// Deliberately has no accent rail. An earlier version drew a 3px vertical bar
/// to the left of the number, which at this size reads as a pipe character
/// glued to the digits — "|0" rather than a divider. The status colour is
/// carried by the label instead, and the label already names the status, so
/// colour is never the only thing distinguishing one chip from another.
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
        // A floor rather than a fixed width: single-digit counts still make a
        // box wide enough to sit level with its neighbours, and a long
        // translated label can push past it.
        constraints: const BoxConstraints(minWidth: 88),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.canvasSoft,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text(
              // int.toString, so the digits are plain 0-9 whatever the app
              // language is. A count is data, not prose: it lines up with the
              // other chips and stays legible in either script.
              '$count',
              textAlign: TextAlign.center,
              style: AppText.displayMd.copyWith(
                // Tabular figures keep the three chips the same width as the
                // counts change, so the row does not shuffle on each reload.
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              label,
              textAlign: TextAlign.center,
              style: AppText.micro.copyWith(color: accent),
            ),
          ],
        ),
      ),
    );
  }
}
