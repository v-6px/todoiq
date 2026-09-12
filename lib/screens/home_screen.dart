import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';
import '../models/task_model.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/add_task_sheet.dart';
import '../widgets/note_sheet.dart';
import '../widgets/task_card.dart';
import 'chat_coach_screen.dart';
import 'report_screen.dart';
import 'settings_screen.dart';

/// Explains why nothing will fire, and offers the one tap that fixes it.
///
/// Shown in place of nagging the user with a second system dialog at launch:
/// granting exact alarms means leaving the app, so it happens only when they
/// choose it here.
class _AlarmPermissionBanner extends StatelessWidget {
  final AppStrings strings;
  final VoidCallback onGrant;
  final VoidCallback onDismiss;

  const _AlarmPermissionBanner({
    required this.strings,
    required this.onGrant,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: HomeScreen.alarmBannerKey,
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.xl,
        AppSpacing.md,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.canvasSoft,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.alarm_off_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  strings.exactAlarmBannerTitle,
                  style: AppText.bodyMd.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(strings.exactAlarmBannerBody, style: AppText.caption),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              FilledButton(
                key: HomeScreen.alarmBannerActionKey,
                onPressed: onGrant,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                ),
                child: Text(
                  strings.exactAlarmBannerAction,
                  style: AppText.buttonCap,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              TextButton(
                key: HomeScreen.alarmBannerDismissKey,
                onPressed: onDismiss,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.inkMute,
                  minimumSize: const Size(0, 40),
                ),
                child: Text(
                  strings.exactAlarmBannerDismiss,
                  style: AppText.buttonCap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Today's dashboard: the date, the three AI entry points, and the task list.
class HomeScreen extends StatefulWidget {
  static const Key reportsKey = Key('home_action_reports');
  static const Key chatKey = Key('home_action_chat');
  static const Key settingsKey = Key('home_action_settings');
  static const Key addTaskKey = Key('home_add_task');
  static const Key previousDayKey = Key('home_previous_day');
  static const Key nextDayKey = Key('home_next_day');
  static const Key todayKey = Key('home_today');
  static const Key alarmBannerKey = Key('home_alarm_banner');
  static const Key alarmBannerActionKey = Key('home_alarm_banner_action');
  static const Key alarmBannerDismissKey = Key('home_alarm_banner_dismiss');

  /// The day to show. Injectable so tests are not clock-dependent.
  final DateTime? day;

  const HomeScreen({super.key, this.day});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Task> _tasks = <Task>[];
  bool _loading = true;

  /// True once the OS has told us it will refuse to arm exact alarms.
  ///
  /// Starts false so nothing flashes on screen before the answer arrives —
  /// the banner appearing a frame late is better than it appearing wrongly.
  bool _exactAlarmsBlocked = false;

  /// Hides the banner for the rest of this session.
  ///
  /// Not persisted: without exact alarms the app cannot do the one thing it
  /// exists for, so the next launch asks again rather than letting a single
  /// dismissal quietly turn every future reminder off.
  bool _alarmBannerDismissed = false;

  bool get _showAlarmBanner => _exactAlarmsBlocked && !_alarmBannerDismissed;

  /// The day on screen. Starts at [HomeScreen.day] (or today) and moves with
  /// the header arrows.
  late DateTime _day = _midnight(widget.day ?? DateTime.now());

  /// Today, fixed at the widget's reference point so tests are not
  /// clock-dependent.
  late final DateTime _today = _midnight(widget.day ?? DateTime.now());

  static DateTime _midnight(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  bool get _isToday => _day == _today;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTasks();
    _requestPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back into the foreground is the moment the answer may have
    // changed — either from the settings screen this banner opens, or from
    // the user revoking the permission while away.
    if (state == AppLifecycleState.resumed) _refreshAlarmPermission();
  }

  /// Asks at launch rather than at first save.
  ///
  /// The notification prompt is answered in place; the exact-alarm state is
  /// only read, and a refusal surfaces as the banner instead of a second
  /// unexpected system screen.
  Future<void> _requestPermissions() async {
    try {
      final NotificationPermissions granted =
          await NotificationService.instance.requestPermissions();
      if (!mounted) return;
      setState(() => _exactAlarmsBlocked = granted.exactAlarmsGranted == false);
    } catch (error, stack) {
      // A platform that has no such permissions at all, or a plugin that is
      // not registered: never a reason to fail the screen.
      debugPrint('HomeScreen: permission check failed with '
          '${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'HomeScreen');
    }
  }

  /// Re-reads the exact-alarm state, and re-arms everything if it improved.
  Future<void> _refreshAlarmPermission() async {
    final bool? granted =
        await NotificationService.instance.canScheduleExactAlarms();
    if (!mounted) return;

    final bool blocked = granted == false;
    final bool justGranted = _exactAlarmsBlocked && !blocked;
    setState(() => _exactAlarmsBlocked = blocked);

    // Tasks created while the permission was missing have no alarm at all.
    // Without this they stay silent until each one is edited by hand.
    if (justGranted) {
      final List<Task> live =
          await DatabaseService.instance.getTasksWithLiveAlarms();
      await NotificationService.instance.tryRescheduleAll(live);
    }
  }

  /// Sends the user to the system screen, then picks up their answer.
  Future<void> _grantExactAlarms() async {
    await NotificationService.instance.openExactAlarmSettings();
    await _refreshAlarmPermission();
  }

  Future<void> _goToDay(DateTime day) async {
    setState(() {
      _day = _midnight(day);
      _loading = true;
    });
    await _loadTasks();
  }

  Future<void> _loadTasks() async {
    final List<Task> tasks =
        await DatabaseService.instance.getTasksForDate(_day);
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loading = false;
    });
  }

  /// Applies [status] to [task] and cancels its alarm.
  ///
  /// This is the single path every status change travels, which is what
  /// guarantees a completed, partial or skipped task can never leave a live
  /// alarm behind. Tapping the status a task already has clears it back to
  /// pending and re-arms the alarm if the time is still ahead.
  Future<void> _changeStatus(Task task, String status) async {
    final int? id = task.id;
    if (id == null) return;

    // For a recurring task the status belongs to the day on screen, not to
    // the row as a whole.
    final String current = task.statusOn(_day);
    final bool isUndo = current == status;
    final String next = isUndo ? TaskStatus.pending : status;

    // Partial and skipped are the states worth explaining; completed needs no
    // excuse and pending is an undo. The prompt is always skippable, so the
    // status change is never blocked on typing.
    String? note = isUndo ? null : task.noteOn(_day);
    if (!isUndo &&
        (next == TaskStatus.partial || next == TaskStatus.skipped)) {
      final NoteResult result = await NoteSheet.show(
        context,
        taskTitle: task.title,
        status: next,
        initialNote: task.noteOn(_day),
      );
      note = result.note;
    }

    await DatabaseService.instance
        .updateStatusWithNote(id, next, note, forDate: _day);
    await NotificationService.instance.cancelNotification(id);

    if (next == TaskStatus.pending) {
      // Re-arm whatever the task's recurrence calls for; a one-off in the
      // past simply arms nothing. Best-effort: undoing a status must not fail
      // because the OS is refusing alarms.
      await NotificationService.instance.trySchedule(task);
    }

    await _loadTasks();
  }

  Future<void> _addTask() async {
    final Task? created = await AddTaskSheet.show(context, day: _day);
    if (created != null) {
      await _loadTasks();
    }
  }

  Future<void> _openReports() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const ReportScreen(),
      ),
    );
  }

  Future<void> _openSettings() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const SettingsScreen(),
      ),
    );
  }

  Future<void> _openCoach() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ChatCoachScreen(day: _day),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header(
              day: _day,
              isToday: _isToday,
              strings: strings,
              pendingCount: _tasks
                  .where((Task t) => t.statusOn(_day) == TaskStatus.pending)
                  .length,
              totalCount: _tasks.length,
              onPreviousDay: () =>
                  _goToDay(_day.subtract(const Duration(days: 1))),
              onNextDay: () => _goToDay(_day.add(const Duration(days: 1))),
              onToday: () => _goToDay(_today),
              onReports: _openReports,
              onChat: _openCoach,
              onSettings: _openSettings,
            ),
            if (_showAlarmBanner)
              _AlarmPermissionBanner(
                strings: strings,
                onGrant: _grantExactAlarms,
                onDismiss: () =>
                    setState(() => _alarmBannerDismissed = true),
              ),
            Expanded(child: _buildBody(strings)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: HomeScreen.addTaskKey,
        onPressed: _addTask,
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        elevation: 2,
        // Rounded rectangle, not a pill — the pill is hero-only in the system.
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)),
        ),
        icon: const Icon(Icons.add_rounded, size: 20),
        label: Text(strings.newTask, style: AppText.buttonMd),
      ),
    );
  }

  Widget _buildBody(AppStrings strings) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.inkFaint,
          ),
        ),
      );
    }

    if (_tasks.isEmpty) {
      return _EmptyState(isToday: _isToday, strings: strings);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xs,
        AppSpacing.xl,
        // Clear the floating action button.
        96,
      ),
      itemCount: _tasks.length,
      itemBuilder: (BuildContext context, int index) {
        final Task task = _tasks[index];
        return TaskCard(
          key: ValueKey<int?>(task.id),
          task: task,
          day: _day,
          onStatusChanged: (String status) => _changeStatus(task, status),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final DateTime day;
  final bool isToday;
  final AppStrings strings;
  final int pendingCount;
  final int totalCount;
  final VoidCallback onPreviousDay;
  final VoidCallback onNextDay;
  final VoidCallback onToday;
  final VoidCallback onReports;
  final VoidCallback onChat;
  final VoidCallback onSettings;

  const _Header({
    required this.day,
    required this.isToday,
    required this.strings,
    required this.pendingCount,
    required this.totalCount,
    required this.onPreviousDay,
    required this.onNextDay,
    required this.onToday,
    required this.onReports,
    required this.onChat,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      DateFormat('EEEE', strings.languageCode).format(day),
                      style: AppText.displayLg,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      '${DateFormat('d MMMM', strings.languageCode).format(day)}'
                      ' \u00b7 $_summary',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              _HeaderAction(
                actionKey: HomeScreen.reportsKey,
                icon: Icons.auto_graph_outlined,
                tooltip: strings.aiReports,
                onPressed: onReports,
              ),
              _HeaderAction(
                actionKey: HomeScreen.chatKey,
                icon: Icons.chat_bubble_outline,
                tooltip: strings.aiCoach,
                onPressed: onChat,
              ),
              _HeaderAction(
                actionKey: HomeScreen.settingsKey,
                icon: Icons.settings_outlined,
                tooltip: strings.settings,
                onPressed: onSettings,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _DayNavigator(
            isToday: isToday,
            strings: strings,
            onPrevious: onPreviousDay,
            onNext: onNextDay,
            onToday: onToday,
          ),
        ],
      ),
    );
  }

  String get _summary {
    if (totalCount == 0) return strings.summaryNothingScheduled();
    if (pendingCount == 0) return strings.summaryAllDone(totalCount);
    return strings.summaryRemaining(pendingCount, totalCount);
  }
}

/// Left/right day stepper, with a "Today" shortcut that only appears when it
/// would actually do something.
class _DayNavigator extends StatelessWidget {
  final bool isToday;
  final AppStrings strings;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;

  const _DayNavigator({
    required this.isToday,
    required this.strings,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        // The Row already flips in RTL, so the chevrons must flip with it:
        // "previous" always points away from the reading direction.
        _StepButton(
          buttonKey: HomeScreen.previousDayKey,
          icon: Icons.chevron_left_rounded,
          tooltip: strings.previousDay,
          onPressed: onPrevious,
        ),
        const SizedBox(width: AppSpacing.xs),
        _StepButton(
          buttonKey: HomeScreen.nextDayKey,
          icon: Icons.chevron_right_rounded,
          tooltip: strings.nextDay,
          onPressed: onNext,
        ),
        if (!isToday) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            key: HomeScreen.todayKey,
            onPressed: onToday,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              textStyle: AppText.buttonCap,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
              ),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(strings.today),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _StepButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.canvas,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      child: InkWell(
        key: buttonKey,
        onTap: onPressed,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: 44,
            height: 36,
            decoration: BoxDecoration(
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.md)),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Icon(
            icon,
            size: 20,
            color: AppColors.inkMute,
            // Mirrors the chevron under RTL so it still reads as back/forward.
            textDirection: Directionality.of(context),
          ),
          ),
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final Key actionKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _HeaderAction({
    required this.actionKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: actionKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      color: AppColors.inkMute,
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isToday;
  final AppStrings strings;

  const _EmptyState({required this.isToday, required this.strings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              isToday
                  ? strings.nothingScheduledToday
                  : strings.nothingScheduledThisDay,
              style: AppText.displayMd,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              strings.emptyStateHint,
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}
