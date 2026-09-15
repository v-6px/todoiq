import 'dart:async';

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

  /// The swipe-to-delete wrapper around one task, addressed by task id.
  static Key dismissibleKey(int id) => Key('home_task_dismissible_$id');

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
  late DateTime _day = _midnight(widget.day ?? _localNow());

  /// Today on the device's local calendar.
  ///
  /// Fixed at [HomeScreen.day] when one is injected, so tests are not
  /// clock-dependent. Otherwise it follows the clock: an app left open
  /// overnight must not keep calling yesterday "today".
  late DateTime _today = _midnight(widget.day ?? _localNow());

  /// Re-reads the wall clock every [_dateCheckInterval].
  ///
  /// A poll rather than one timer aimed at midnight: Dart timers run on a
  /// monotonic clock that stops while the phone sleeps, so a midnight timer
  /// set in the evening can fire hours late and leave yesterday on screen.
  /// Comparing against the wall clock each tick cannot drift.
  Timer? _dateTimer;
  static const Duration _dateCheckInterval = Duration(seconds: 30);

  static DateTime _localNow() => DateTime.now().toLocal();

  /// Bumped on every load, so a slow read that started before a newer change
  /// cannot land afterwards and paint stale state over it.
  int _loadGeneration = 0;

  static DateTime _midnight(DateTime value) => Task.dayStart(value);

  bool get _isToday => _day == _today;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.day == null) {
      _dateTimer = Timer.periodic(_dateCheckInterval, (_) => _syncToday());
    }
    _loadTasks();
    _requestPermissions();
  }

  @override
  void dispose() {
    _dateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // First, and synchronously: the date is what everything else on screen
      // hangs off, so it must be right before anything else reloads.
      _syncToday();
      // The alarm permission may have changed too — from the settings screen
      // the banner opens, or revoked while the user was away.
      _refreshAlarmPermission();
    }
  }

  /// Moves "today" to the device's current local date if the calendar has
  /// turned over. Returns true if it did.
  ///
  /// Called on resume, on a timer, and before anything that acts on "today"
  /// — so a tap never lands on a day that has already ended. Someone looking
  /// at today is carried along to the new today; someone deliberately
  /// browsing another day stays there, and gains the "Today" shortcut.
  bool _syncToday() {
    if (widget.day != null || !mounted) return false;
    final DateTime now = _midnight(_localNow());
    if (now == _today) return false;

    final bool wasOnToday = _isToday;
    setState(() => _today = now);
    if (wasOnToday) _goToDay(now);
    return true;
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
    final int generation = ++_loadGeneration;
    final List<Task> tasks =
        await DatabaseService.instance.getTasksForDate(_day);
    if (!mounted || generation != _loadGeneration) return;
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
  Future<void> _changeStatus(Task tapped, String status) async {
    final int? id = tapped.id;
    if (id == null) return;

    // A tap made on a day that has since ended would record against
    // yesterday. Roll over and let the user act on the real today instead.
    if (_syncToday()) return;

    // One change per task at a time. A second tap while the first is still
    // being written reads as "tap the active status again", which is undo —
    // so a quick double-tap on the checkmark used to uncheck it again.
    if (!_statusInFlight.add(id)) return;
    try {
      await _applyStatusChange(tapped, status);
    } finally {
      _statusInFlight.remove(id);
    }
  }

  /// Task ids with a status change still being written.
  final Set<int> _statusInFlight = <int>{};

  Future<void> _applyStatusChange(Task tapped, String status) async {
    final int id = tapped.id!;

    // The freshest copy on screen, not the one captured when the card was
    // built, so the undo decision reads the state the user is looking at.
    final Task task = _tasks.firstWhere(
      (Task t) => t.id == id,
      orElse: () => tapped,
    );

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
      if (!mounted) return;
    }

    // Paint first. Writing the row, cancelling the alarm and re-reading the
    // day is three round trips — one of them eight platform-channel calls —
    // and until this was hoisted above them the checkmark did nothing visible
    // for long enough to look broken.
    _applyStatusLocally(task, next, note);

    // Any load already in flight read the row before this write; it must not
    // land afterwards and uncheck the box.
    _loadGeneration++;
    final DateTime day = _day;

    try {
      // The write goes first and alone: it is the part that has to stick.
      await DatabaseService.instance
          .updateStatusWithNote(id, next, note, forDate: day);
    } catch (error, stack) {
      debugPrint('HomeScreen: could not record $next on task $id with '
          '${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'HomeScreen');
    }

    await _syncAlarms(task, next);

    // Reconcile with what was actually stored. On the happy path this repaints
    // the same thing; if the write failed, the optimistic change is undone
    // here rather than left on screen as a lie.
    await _loadTasks();
  }

  /// Brings [task]'s alarms in line with a status change to [next].
  ///
  /// A one-off that is resolved has nothing left to ring for; one returned
  /// to pending is re-armed if its time is still ahead. A recurring task is
  /// never simply cancelled — that would silence every future day. It is
  /// re-armed from the next instance still open: tomorrow if today's is done,
  /// today if it is not. Best-effort throughout: an OS refusing alarms must
  /// never undo a status the database already holds.
  Future<void> _syncAlarms(Task task, String next) async {
    final int id = task.id!;
    final NotificationService alarms = NotificationService.instance;

    if (!task.isRecurring) {
      if (next == TaskStatus.pending) {
        await alarms.trySchedule(task.copyWith(status: next));
      } else {
        await alarms.tryCancelNotification(id);
      }
      return;
    }

    try {
      // Read back rather than inferred from [next]: the change may have been
      // made on another day, and only today's outcome decides today's alarm.
      final Task? current = await DatabaseService.instance
          .getTaskOnDate(id, DateTime.now());
      if (current != null) await alarms.trySchedule(current);
    } catch (error, stack) {
      debugPrint('HomeScreen: could not re-arm task $id with '
          '${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'HomeScreen');
    }
  }

  /// Shows [next] on [task] immediately, in the right place in the list.
  ///
  /// Mirrors what the database write plus a reload would produce — including
  /// the re-sort, so a completed task drops to the bottom on the same frame
  /// rather than jumping down a moment later.
  void _applyStatusLocally(Task task, String next, String? note) {
    final int index = _tasks.indexWhere((Task t) => t.id == task.id);
    if (index == -1) return;

    final String? trimmed =
        (note == null || note.trim().isEmpty) ? null : note.trim();

    setState(() {
      _tasks[index] = _tasks[index].copyWith(
        status: next,
        note: trimmed,
        clearNote: trimmed == null,
        // The status belongs to the day on screen, which is what stops a
        // recurring task's completion leaking into tomorrow.
        statusDate: _day,
      );
      _tasks.sort((Task a, Task b) =>
          DatabaseService.compareForDay(a, b, _day));
    });
  }

  Future<void> _addTask() async {
    if (_syncToday()) return;
    final Task? created =
        await AddTaskSheet.show(context, day: _day, today: _today);
    if (created != null) {
      await _loadTasks();
    }
  }

  /// Reopens [task] in the sheet, prefilled.
  ///
  /// The sheet does the saving and the re-arming; all that is left here is to
  /// pick up the change, since an edit can move a task off the day on screen.
  Future<void> _editTask(Task task) async {
    final Task? updated = await AddTaskSheet.show(
      context,
      day: _day,
      today: _today,
      task: task,
    );
    if (updated != null) {
      await _loadTasks();
    }
  }

  /// Deletes [task], with a window to take it back.
  ///
  /// The row goes immediately — a confirmation dialog on every swipe is the
  /// heavier tax, because deleting is rare and undoing is cheap.
  ///
  /// Order matters. The card leaves the list on this frame, because a
  /// dismissed [Dismissible] must not be rebuilt. The row is deleted next, on
  /// its own, so nothing can stand between the swipe and the DELETE — alarm
  /// cancellation used to go first, and a plugin that threw left the row in
  /// place to reappear on the next reload. The alarms are cleared after, and
  /// a failure there is logged rather than allowed to resurrect the task.
  Future<void> _deleteTask(Task task) async {
    final int? id = task.id;
    if (id == null) return;

    final AppStrings strings = AppStrings.of(context);

    _loadGeneration++;
    setState(() => _tasks.removeWhere((Task t) => t.id == id));

    List<TaskCompletion> history = const <TaskCompletion>[];
    try {
      // Only a recurring task has per-day history worth keeping for undo.
      if (task.isRecurring) {
        history = await DatabaseService.instance.getCompletionsForTask(id);
      }
      await DatabaseService.instance.deleteTask(id);
    } catch (error, stack) {
      debugPrint('HomeScreen: could not delete task $id with '
          '${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'HomeScreen');
      // Show what is really stored rather than pretend it went.
      await _loadTasks();
      return;
    }

    await NotificationService.instance.tryCancelNotification(id);
    await _loadTasks();

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(strings.taskDeleted),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: strings.undo,
            onPressed: () => _restoreTask(task, history),
          ),
        ),
      );
  }

  /// Puts a deleted task back, id and all.
  ///
  /// [Task.toMap] carries the id when it has one, so SQLite reuses the same
  /// primary key — which keeps the restored task's alarm ids identical to the
  /// ones that were just cancelled. A recurring task's per-day [history]
  /// comes back with it.
  Future<void> _restoreTask(Task task, List<TaskCompletion> history) async {
    try {
      await DatabaseService.instance
          .restoreTask(task, completions: history);
      final Task current = await DatabaseService.instance
              .getTaskOnDate(task.id!, DateTime.now()) ??
          task;
      // A one-off already dealt with has nothing left to ring for.
      if (current.isRecurring || current.isPending) {
        await NotificationService.instance.trySchedule(current);
      }
    } catch (error, stack) {
      debugPrint('HomeScreen: could not restore "${task.title}" with '
          '${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'HomeScreen');
    }
    await _loadTasks();
  }

  /// Pushes [page], and re-checks the date on the way back — time spent on
  /// another screen can carry the clock past midnight.
  Future<void> _open(Widget page) async {
    _syncToday();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
    _syncToday();
  }

  Future<void> _openReports() => _open(const ReportScreen());

  Future<void> _openSettings() => _open(const SettingsScreen());

  Future<void> _openCoach() {
    _syncToday();
    return _open(ChatCoachScreen(day: _day, today: _today));
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
              onPreviousDay: () => _goToDay(Task.addDays(_day, -1)),
              onNextDay: () => _goToDay(Task.addDays(_day, 1)),
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
        final TaskCard card = TaskCard(
          key: ValueKey<int?>(task.id),
          task: task,
          day: _day,
          onStatusChanged: (String status) => _changeStatus(task, status),
          onEdit: () => _editTask(task),
        );

        final int? id = task.id;
        if (id == null) return card;

        return Dismissible(
          key: HomeScreen.dismissibleKey(id),
          // Either direction: which way a swipe-to-delete runs is muscle
          // memory, and it flips with the language.
          background: _DeleteBackground(
            strings: strings,
            alignment: AlignmentDirectional.centerStart,
          ),
          secondaryBackground: _DeleteBackground(
            strings: strings,
            alignment: AlignmentDirectional.centerEnd,
          ),
          onDismissed: (DismissDirection _) => _deleteTask(task),
          child: card,
        );
      },
    );
  }
}

/// What shows behind a task as it is swiped away.
class _DeleteBackground extends StatelessWidget {
  final AppStrings strings;
  final AlignmentGeometry alignment;

  const _DeleteBackground({required this.strings, required this.alignment});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      alignment: alignment,
      decoration: BoxDecoration(
        color: AppColors.canvasSoft,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.delete_outline_rounded,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            strings.deleteTask,
            style: AppText.buttonCap.copyWith(color: AppColors.primary),
          ),
        ],
      ),
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
                // An assistant rather than a bare chat bubble, to match what
                // the label now calls it.
                icon: Icons.assistant_outlined,
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
              textStyle: AppTheme.localizedText(context, AppText.buttonCap),
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
