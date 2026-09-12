import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';
import '../models/task_model.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// Bottom sheet for creating a task.
///
/// Handles the whole shape of a task: what, when, and how often. On save it
/// writes the row to SQLite and arms whatever alarms the recurrence needs,
/// then pops with the inserted [Task] so the caller can refresh.
class AddTaskSheet extends StatefulWidget {
  static const Key titleFieldKey = Key('add_task_title_field');
  static const Key timeButtonKey = Key('add_task_time_button');
  static const Key dateButtonKey = Key('add_task_date_button');
  static const Key todayChipKey = Key('add_task_date_today');
  static const Key tomorrowChipKey = Key('add_task_date_tomorrow');
  static const Key saveButtonKey = Key('add_task_save_button');
  static const Key errorKey = Key('add_task_error');
  static const Key errorDetailKey = Key('add_task_error_detail');

  static Key recurrenceKey(String type) => Key('add_task_recurrence_$type');

  static Key weekdayKey(int weekday) => Key('add_task_weekday_$weekday');

  /// The day the sheet opens on. Defaults to today.
  final DateTime? day;

  const AddTaskSheet({super.key, this.day});

  /// Opens the sheet and resolves to the created task, or null if dismissed.
  static Future<Task?> show(BuildContext context, {DateTime? day}) {
    return showModalBottomSheet<Task>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      builder: (BuildContext context) => AddTaskSheet(day: day),
    );
  }

  /// Localised short weekday names, Monday first, matching `DateTime.weekday`.
  ///
  /// Derived from intl rather than hand-written, so Arabic names come from the
  /// same data the rest of the app formats dates with.
  static List<String> weekdayLabels(String languageCode) {
    // 5 Jan 2026 is a Monday; seven days from it covers the week in order.
    final DateTime monday = DateTime(2026, 1, 5);
    return List<String>.generate(7, (int index) {
      return DateFormat.E(languageCode)
          .format(monday.add(Duration(days: index)));
    });
  }

  @override
  State<AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<AddTaskSheet> {
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _titleFocus = FocusNode();

  late DateTime _date;
  late TimeOfDay _time;

  String _recurrence = RecurrenceType.none;
  final Set<int> _repeatDays = <int>{};

  String? _error;

  /// The exception text behind [_error], shown under it.
  ///
  /// A save failure is invisible from the outside — this is what turns a bug
  /// report from "it says it could not save" into something diagnosable.
  String? _errorDetail;

  bool _saving = false;

  /// Today at midnight, captured once so the quick chips stay stable.
  late final DateTime _today = Task.dayStart(widget.day ?? DateTime.now());

  @override
  void initState() {
    super.initState();
    _date = _today;

    // Default to the next round half hour — the most common intent is
    // "soon", and it saves a trip through the picker.
    final DateTime now = DateTime.now();
    final DateTime rounded = now.minute < 30
        ? DateTime(now.year, now.month, now.day, now.hour, 30)
        : DateTime(now.year, now.month, now.day, now.hour + 1);
    _time = TimeOfDay(hour: rounded.hour % 24, minute: rounded.minute);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  DateTime get _scheduledDateTime => DateTime(
        _date.year,
        _date.month,
        _date.day,
        _time.hour,
        _time.minute,
      );

  bool get _isPast =>
      _recurrence == RecurrenceType.none &&
      _scheduledDateTime.isBefore(DateTime.now());

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null && mounted) {
      setState(() => _time = picked);
    }
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      // A year back covers logging something missed; two years forward is
      // more than enough runway for a planned task.
      firstDate: _today.subtract(const Duration(days: 365)),
      lastDate: _today.add(const Duration(days: 730)),
    );
    if (picked != null && mounted) {
      setState(() => _date = Task.dayStart(picked));
    }
  }

  void _selectRecurrence(String type) {
    setState(() {
      _recurrence = type;
      if (type == RecurrenceType.weeklyDays && _repeatDays.isEmpty) {
        // Seed with the chosen date's weekday so the choice is never empty.
        _repeatDays.add(_date.weekday);
      }
      _error = null;
    });
  }

  void _toggleWeekday(int weekday) {
    setState(() {
      if (!_repeatDays.remove(weekday)) _repeatDays.add(weekday);
      _error = null;
    });
  }

  Future<void> _save() async {
    final AppStrings strings = AppStrings.of(context);
    final String title = _titleController.text.trim();

    if (title.isEmpty) {
      setState(() => _error = strings.addTaskEmptyError);
      _titleFocus.requestFocus();
      return;
    }
    if (_recurrence == RecurrenceType.weeklyDays && _repeatDays.isEmpty) {
      setState(() => _error = strings.pickAtLeastOneDay);
      return;
    }

    setState(() {
      _error = null;
      _errorDetail = null;
      _saving = true;
    });

    final Task task = Task(
      title: title,
      scheduledTime: _scheduledDateTime,
      recurrenceType: _recurrence,
      repeatDays: _recurrence == RecurrenceType.weeklyDays
          ? (_repeatDays.toList()..sort())
          : null,
    );

    final Task saved;
    try {
      final int id = await DatabaseService.instance.insertTask(task);
      saved = task.copyWith(id: id);
    } catch (error, stack) {
      // Only a genuine write failure lands here. The exact exception is
      // logged and shown, because "could not save" on its own leaves nobody —
      // user or developer — anything to act on.
      debugPrint('AddTaskSheet: insert failed for "${task.title}" '
          '(${task.toMap()}) with ${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'AddTaskSheet._save');

      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = strings.addTaskSaveError;
        _errorDetail = '$error';
      });
      return;
    }

    // The row is committed from here on, so nothing below may report the save
    // as failed. Permissions were asked for at launch; if the OS is still
    // refusing, that is what the home screen banner is for.
    //
    // trySchedule arms one alarm, a daily repeat, or one per weekday — and
    // declines a one-off whose time has already passed. Null means the OS
    // refused; the task itself is still saved.
    final int? armed = await NotificationService.instance.trySchedule(saved);

    if (!mounted) return;
    if (armed == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(strings.taskSavedReminderFailed),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
    }

    Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);

    return Padding(
      // Lift the sheet above the keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.md,
              AppSpacing.xl,
              AppSpacing.xl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: const BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius:
                          BorderRadius.all(Radius.circular(AppRadius.xs)),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(strings.addTaskTitle, style: AppText.displayMd),
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  key: AddTaskSheet.titleFieldKey,
                  controller: _titleController,
                  focusNode: _titleFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  style: AppText.bodyMd,
                  decoration: InputDecoration(hintText: strings.addTaskHint),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: AppSpacing.lg),
                _FieldLabel(strings.dateLabel),
                const SizedBox(height: AppSpacing.sm),
                _dateChips(strings),
                const SizedBox(height: AppSpacing.lg),
                _FieldLabel(strings.timeLabel),
                const SizedBox(height: AppSpacing.sm),
                _timeRow(strings),
                const SizedBox(height: AppSpacing.lg),
                _FieldLabel(strings.repeatLabel),
                const SizedBox(height: AppSpacing.sm),
                _recurrenceChips(strings),
                if (_recurrence == RecurrenceType.weeklyDays) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  _weekdayChips(strings),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    _error!,
                    key: AddTaskSheet.errorKey,
                    style: AppText.caption.copyWith(color: AppColors.primary),
                  ),
                  if (_errorDetail != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    // Left-aligned whatever the language: this is an
                    // exception message, not prose.
                    Text(
                      _errorDetail!,
                      key: AddTaskSheet.errorDetailKey,
                      textAlign: TextAlign.left,
                      style: AppText.micro.copyWith(color: AppColors.inkFaint),
                    ),
                  ],
                ],
                const SizedBox(height: AppSpacing.xl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: AddTaskSheet.saveButtonKey,
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving ? strings.addTaskSaving : strings.addTaskButton,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dateChips(AppStrings strings) {
    final DateTime tomorrow = _today.add(const Duration(days: 1));
    final bool isCustom = _date != _today && _date != tomorrow;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        _ChoiceChip(
          chipKey: AddTaskSheet.todayChipKey,
          label: strings.dateToday,
          isActive: _date == _today,
          onTap: () => setState(() => _date = _today),
        ),
        _ChoiceChip(
          chipKey: AddTaskSheet.tomorrowChipKey,
          label: strings.dateTomorrow,
          isActive: _date == tomorrow,
          onTap: () => setState(() => _date = tomorrow),
        ),
        _ChoiceChip(
          chipKey: AddTaskSheet.dateButtonKey,
          // Once a custom date is chosen the chip shows it, so the selection
          // is always visible without opening the picker again.
          label: isCustom
              ? DateFormat('d MMM', strings.languageCode).format(_date)
              : strings.datePick,
          isActive: isCustom,
          icon: Icons.calendar_today_rounded,
          onTap: _pickDate,
        ),
      ],
    );
  }

  Widget _timeRow(AppStrings strings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Material(
          color: AppColors.canvasSoft,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
          child: InkWell(
            key: AddTaskSheet.timeButtonKey,
            onTap: _pickTime,
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.md)),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                borderRadius:
                    const BorderRadius.all(Radius.circular(AppRadius.md)),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.schedule_rounded,
                    size: 18,
                    color: AppColors.inkMute,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    DateFormat.Hm(strings.languageCode)
                        .format(_scheduledDateTime),
                    style: AppText.bodyMd,
                  ),
                  const Spacer(),
                  Text(strings.changeTime, style: AppText.buttonCap),
                ],
              ),
            ),
          ),
        ),
        if (_isPast) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(strings.timeHasPassedNotice, style: AppText.micro),
        ],
      ],
    );
  }

  Widget _recurrenceChips(AppStrings strings) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        _ChoiceChip(
          chipKey: AddTaskSheet.recurrenceKey(RecurrenceType.none),
          label: strings.repeatOnce,
          isActive: _recurrence == RecurrenceType.none,
          onTap: () => _selectRecurrence(RecurrenceType.none),
        ),
        _ChoiceChip(
          chipKey: AddTaskSheet.recurrenceKey(RecurrenceType.daily),
          label: strings.repeatDaily,
          isActive: _recurrence == RecurrenceType.daily,
          onTap: () => _selectRecurrence(RecurrenceType.daily),
        ),
        _ChoiceChip(
          chipKey: AddTaskSheet.recurrenceKey(RecurrenceType.weeklyDays),
          label: strings.repeatSpecificDays,
          isActive: _recurrence == RecurrenceType.weeklyDays,
          onTap: () => _selectRecurrence(RecurrenceType.weeklyDays),
        ),
      ],
    );
  }

  Widget _weekdayChips(AppStrings strings) {
    final List<String> labels =
        AddTaskSheet.weekdayLabels(strings.languageCode);

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: List<Widget>.generate(7, (int index) {
        final int weekday = index + 1;
        return _ChoiceChip(
          chipKey: AddTaskSheet.weekdayKey(weekday),
          label: labels[index],
          isActive: _repeatDays.contains(weekday),
          compact: true,
          onTap: () => _toggleWeekday(weekday),
        );
      }),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppText.micro);
}

/// Pill-shaped selector, matching the settings and report chips.
class _ChoiceChip extends StatelessWidget {
  final Key chipKey;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final IconData? icon;
  final bool compact;

  const _ChoiceChip({
    required this.chipKey,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.icon,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? AppColors.primary : AppColors.canvas,
      borderRadius: const BorderRadius.all(Radius.circular(999)),
      child: InkWell(
        key: chipKey,
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        child: Container(
          constraints: BoxConstraints(minHeight: 44, minWidth: compact ? 44 : 0),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.md : AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            border: Border.all(
              color: isActive ? AppColors.primary : AppColors.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(
                  icon,
                  size: 14,
                  color: isActive ? AppColors.onPrimary : AppColors.inkMute,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                label,
                style: AppText.buttonCap.copyWith(
                  color: isActive ? AppColors.onPrimary : AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
