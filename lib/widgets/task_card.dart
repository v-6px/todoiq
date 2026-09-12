import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';
import '../models/task_model.dart';
import '../theme/app_theme.dart';
import 'add_task_sheet.dart';

/// One task in the day's list.
///
/// Presentation only — it reports the status the user tapped and lets the
/// caller persist it and cancel the alarm. Keeping the side effects out of the
/// widget is what lets the home screen guarantee that *every* status change
/// cancels the notification, in exactly one place.
class TaskCard extends StatelessWidget {
  /// Keys so tests and callers can address the three actions directly.
  static const Key completeKey = Key('task_action_complete');
  static const Key partialKey = Key('task_action_partial');
  static const Key skipKey = Key('task_action_skip');

  final Task task;

  /// The day being shown. A recurring task's status and note belong to a
  /// specific day, so the card needs to know which one it is rendering.
  final DateTime? day;

  /// Fired with one of [TaskStatus.completed], [TaskStatus.partial] or
  /// [TaskStatus.skipped].
  final ValueChanged<String> onStatusChanged;

  final VoidCallback? onDelete;

  const TaskCard({
    super.key,
    required this.task,
    required this.onStatusChanged,
    this.day,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);
    final DateTime day = this.day ?? task.scheduledTime;
    final String status = task.statusOn(day);
    final String? note = task.noteOn(day);
    final bool isResolved = status != TaskStatus.pending;
    final Color accent = statusColor(status);

    return Semantics(
      label: '${task.title}, ${statusLabel(status, strings)}',
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          // Resolved tasks recede onto the soft canvas so the pending ones
          // carry the eye.
          color: isResolved ? AppColors.canvasSoft : AppColors.canvas,
          borderRadius:
              const BorderRadius.all(Radius.circular(AppRadius.lg)),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // A 3px accent rail is the only status colour on the card; the
            // icons carry the meaning, so colour is never the sole channel.
            Container(
              width: 3,
              height: (note != null || task.isRecurring) ? 72 : 56,
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                color: isResolved ? accent : AppColors.hairline,
                borderRadius:
                    const BorderRadius.all(Radius.circular(AppRadius.xs)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      task.title,
                      style: AppText.bodyMd.copyWith(
                        color: isResolved ? AppColors.inkMute : AppColors.ink,
                        decoration: status == TaskStatus.completed
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: AppColors.inkFaint,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Row(
                      children: <Widget>[
                        Text(
                          formatTime(
                            task.scheduledTime,
                            strings.languageCode,
                          ),
                          style: AppText.micro,
                        ),
                        if (isResolved) ...<Widget>[
                          const Text(
                            ' · ',
                            style: AppText.micro,
                          ),
                          Text(
                            statusLabel(status, strings),
                            style: AppText.micro.copyWith(color: accent),
                          ),
                        ],
                        if (task.isRecurring) ...<Widget>[
                          const SizedBox(width: AppSpacing.sm),
                          const Icon(
                            Icons.repeat_rounded,
                            size: 12,
                            color: AppColors.inkFaint,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Flexible(
                            child: Text(
                              recurrenceLabel(task, strings),
                              style: AppText.micro
                                  .copyWith(color: AppColors.inkFaint),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    // The reason the user gave, kept quiet but visible so the
                    // card stays an honest record of the day.
                    if (note != null && note.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        note.trim(),
                        style: AppText.micro.copyWith(
                          color: AppColors.inkFaint,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _ActionButton(
                    buttonKey: completeKey,
                    icon: Icons.check_rounded,
                    tooltip: strings.actionComplete,
                    activeColor: statusColor(TaskStatus.completed),
                    isActive: status == TaskStatus.completed,
                    onPressed: () => onStatusChanged(TaskStatus.completed),
                  ),
                  _ActionButton(
                    buttonKey: partialKey,
                    icon: Icons.remove_rounded,
                    tooltip: strings.actionPartial,
                    activeColor: statusColor(TaskStatus.partial),
                    isActive: status == TaskStatus.partial,
                    onPressed: () => onStatusChanged(TaskStatus.partial),
                  ),
                  _ActionButton(
                    buttonKey: skipKey,
                    icon: Icons.close_rounded,
                    tooltip: strings.actionSkip,
                    activeColor: statusColor(TaskStatus.skipped),
                    isActive: status == TaskStatus.skipped,
                    onPressed: () => onStatusChanged(TaskStatus.skipped),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `09:30`, in 24-hour form so the list reads as a timeline. Arabic uses
  /// its own digit shapes, which intl handles from the locale.
  static String formatTime(DateTime time, [String? languageCode]) =>
      DateFormat.Hm(languageCode).format(time);

  /// The in-palette colour for [status]. Only indigo, teal and the warm greys
  /// are used — the source system forbids extra accents.
  static Color statusColor(String status) {
    switch (status) {
      case TaskStatus.completed:
        return AppColors.tealDeep;
      case TaskStatus.partial:
        return AppColors.primary;
      case TaskStatus.skipped:
        return AppColors.inkFaint;
      default:
        return AppColors.hairline;
    }
  }

  /// "Repeats daily" or "Repeats Mon, Wed", in the active language.
  static String recurrenceLabel(Task task, AppStrings strings) {
    if (task.isDaily) return strings.repeatsDaily;

    final List<int> days = task.repeatDays ?? const <int>[];
    if (days.isEmpty) return '';

    final List<String> labels =
        AddTaskSheet.weekdayLabels(strings.languageCode);
    return strings.repeatsOn(
      days.map((int weekday) => labels[weekday - 1]).join(', '),
    );
  }

  static String statusLabel(String status, AppStrings strings) {
    switch (status) {
      case TaskStatus.completed:
        return strings.statusDone;
      case TaskStatus.partial:
        return strings.statusPartial;
      case TaskStatus.skipped:
        return strings.statusSkipped;
      default:
        return strings.statusPending;
    }
  }
}

/// A 44x44 tactile square. Filled when it is the task's current status,
/// hairline-outlined otherwise.
class _ActionButton extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final Color activeColor;
  final bool isActive;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.activeColor,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: isActive,
          label: tooltip,
          child: Material(
            color: isActive ? activeColor : AppColors.canvas,
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.md)),
            child: InkWell(
              key: buttonKey,
              onTap: onPressed,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.md)),
              child: Container(
                // WCAG AAA touch target.
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadius.md)),
                  border: Border.all(
                    color: isActive ? activeColor : AppColors.hairline,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: isActive ? AppColors.onPrimary : AppColors.inkMute,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
