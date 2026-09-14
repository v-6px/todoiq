import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/home_screen.dart';
import 'package:todo_list/screens/report_screen.dart';
import 'package:todo_list/screens/settings_screen.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/notification_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';
import 'package:todo_list/widgets/add_task_sheet.dart';
import 'package:todo_list/widgets/note_sheet.dart';
import 'package:todo_list/widgets/task_card.dart';

const MethodChannel _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Alarms the fake OS is holding, keyed by notification id.
  final Map<int, Map<Object?, Object?>> pendingAlarms =
      <int, Map<Object?, Object?>>{};

  /// Ids passed to cancel, in order — the Phase 3 contract under test.
  final List<int> cancelled = <int>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Test files run in parallel isolates; sharing one SQLite file across
    // them deadlocks.
    DatabaseService.debugDatabaseName = 'phase3_test.db';

    // main() does this before the first frame; DateFormat with an explicit
    // locale throws without it.
    initializeDateFormatting();

    // The app does this in main() via NotificationService.init(). Without it
    // tz.local is unusable and scheduleNotification throws, which the add
    // sheet would swallow into an error state.
    NotificationService.configureLocalTimeZone();
  });

  /// What the fake OS says when asked whether it will arm exact alarms.
  /// Null stands for a platform that does not gate them at all.
  bool? canScheduleExactAlarms;

  /// Method names seen on the notification channel this test.
  late List<String> notificationCalls;

  setUp(() async {
    canScheduleExactAlarms = null;
    notificationCalls = <String>[];
    pendingAlarms.clear();
    cancelled.clear();

    // Clear the rows rather than closing the database. A widget disposed at
    // the end of the previous test can still have a query in flight, and
    // closing underneath it throws "database has already been closed".
    final Database database = await DatabaseService.instance.database;
    await database.delete(DatabaseService.tasksTable);

    // The settings screen reads shared_preferences as soon as it is pushed,
    // so the navigation test needs a store in place.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();

    // testWidgets already runs as Android, and it asserts that foundation
    // debug variables are untouched at the end of each test body — so the
    // platform must not be overridden here. Registering the Android
    // implementation is enough to route the plugin at the mocked channel.
    AndroidFlutterLocalNotificationsPlugin.registerWith();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationChannel,
            (MethodCall call) async {
      final Object? args = call.arguments;
      notificationCalls.add(call.method);
      switch (call.method) {
        case 'requestNotificationsPermission':
          return true;
        case 'canScheduleExactNotifications':
          return canScheduleExactAlarms;
        case 'requestExactAlarmsPermission':
          // Standing in for the user granting it on the settings screen.
          canScheduleExactAlarms = true;
          return true;
        case 'pendingNotificationRequests':
          return <Object?>[];
        case 'zonedSchedule':
          final Map<Object?, Object?> map = args! as Map<Object?, Object?>;
          pendingAlarms[map['id']! as int] = map;
          return null;
        case 'cancel':
          final Map<Object?, Object?> map = args! as Map<Object?, Object?>;
          final int id = map['id']! as int;
          cancelled.add(id);
          pendingAlarms.remove(id);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationChannel, null);
  });

  /// The day every test operates on, fixed so nothing depends on the clock.
  final DateTime today = DateTime.now();
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(today.year, today.month, today.day, hour, minute);

  /// Runs database work on the real event loop.
  ///
  /// A testWidgets body executes inside fake async, which never delivers the
  /// reply from sqflite_common_ffi's isolate — awaiting a query directly in a
  /// test hangs forever. runAsync is the only way to reach real I/O.
  Future<T> onDb<T>(WidgetTester tester, Future<T> Function() action) async {
    late T result;
    await tester.runAsync(() async {
      result = await action();
    });
    return result;
  }

  /// Drains pending real async work, then settles the tree.
  ///
  /// A handler like `_changeStatus` awaits several times in a row — update,
  /// cancel, reload — alternating between the widget tester's fake async and
  /// real isolate I/O. One runAsync only advances the chain by a step, so the
  /// turns are interleaved until it has run out.
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<int> seedTask(
    WidgetTester tester,
    String title, {
    DateTime? when,
    String status = TaskStatus.pending,
  }) {
    return onDb(
      tester,
      () => DatabaseService.instance.insertTask(
        Task(title: title, scheduledTime: when ?? at(9), status: status),
      ),
    );
  }

  Future<Task?> readTask(WidgetTester tester, int id) =>
      onDb(tester, () => DatabaseService.instance.getTaskById(id));

  Future<List<Task>> readToday(WidgetTester tester) =>
      onDb(tester, () => DatabaseService.instance.getTasksForDate(today));

  Widget wrap(Widget child, {String language = 'en'}) {
    return MaterialApp(
      theme: AppTheme.forLocale(Locale(language)),
      locale: Locale(language),
      supportedLocales: const <Locale>[
        Locale('en'),
        Locale('ar'),
        Locale('fr'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(wrap(HomeScreen(day: today)));
    await settle(tester);
  }

  Future<void> pumpCard(
    WidgetTester tester,
    Task task, {
    ValueChanged<String>? onStatusChanged,
  }) {
    return tester.pumpWidget(wrap(
      Scaffold(
        body: TaskCard(
          task: task,
          onStatusChanged: onStatusChanged ?? (_) {},
        ),
      ),
    ));
  }

  group('TaskCard rendering', () {
    testWidgets('shows the title and 24-hour scheduled time', (
      WidgetTester tester,
    ) async {
      await pumpCard(
        tester,
        Task(title: 'Draft the brief', scheduledTime: at(14, 5)),
      );

      expect(find.text('Draft the brief'), findsOneWidget);
      expect(find.text('14:05'), findsOneWidget);
    });

    testWidgets('a pending task shows no status label', (
      WidgetTester tester,
    ) async {
      await pumpCard(tester, Task(title: 'Pending', scheduledTime: at(9)));

      expect(find.text('Done'), findsNothing);
      expect(find.text('Partial'), findsNothing);
      expect(find.text('Skipped'), findsNothing);
    });

    testWidgets('each resolved status gets its own label', (
      WidgetTester tester,
    ) async {
      for (final MapEntry<String, String> entry in <String, String>{
        TaskStatus.completed: 'Done',
        TaskStatus.partial: 'Partial',
        TaskStatus.skipped: 'Skipped',
      }.entries) {
        await pumpCard(
          tester,
          Task(title: 'Task', scheduledTime: at(9), status: entry.key),
        );
        await tester.pump();

        expect(find.text(entry.value), findsOneWidget,
            reason: 'missing label for ${entry.key}');
      }
    });

    test('status colours stay inside the allowed palette', () {
      expect(TaskCard.statusColor(TaskStatus.completed), AppColors.tealDeep);
      expect(TaskCard.statusColor(TaskStatus.partial), AppColors.primary);
      expect(TaskCard.statusColor(TaskStatus.skipped), AppColors.inkFaint);
      expect(TaskCard.statusColor(TaskStatus.pending), AppColors.hairline);
    });

    testWidgets('a completed task is struck through', (
      WidgetTester tester,
    ) async {
      await pumpCard(
        tester,
        Task(
          title: 'Finished',
          scheduledTime: at(9),
          status: TaskStatus.completed,
        ),
      );

      final Text title = tester.widget<Text>(find.text('Finished'));
      expect(title.style!.decoration, TextDecoration.lineThrough);
    });

    testWidgets('the three actions report their own status', (
      WidgetTester tester,
    ) async {
      final List<String> reported = <String>[];
      await pumpCard(
        tester,
        Task(title: 'Tap me', scheduledTime: at(9)),
        onStatusChanged: reported.add,
      );

      await tester.tap(find.byKey(TaskCard.completeKey));
      await tester.tap(find.byKey(TaskCard.partialKey));
      await tester.tap(find.byKey(TaskCard.skipKey));

      expect(reported, <String>[
        TaskStatus.completed,
        TaskStatus.partial,
        TaskStatus.skipped,
      ]);
    });

    testWidgets('action buttons meet the 44px touch target', (
      WidgetTester tester,
    ) async {
      await pumpCard(tester, Task(title: 'Touch', scheduledTime: at(9)));

      for (final Key key in <Key>[
        TaskCard.completeKey,
        TaskCard.partialKey,
        TaskCard.skipKey,
      ]) {
        final Size size = tester.getSize(find.byKey(key));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
    });
  });

  group('HomeScreen', () {
    testWidgets('shows the empty state when the day has no tasks', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      expect(find.text('Nothing scheduled today.'), findsOneWidget);
      expect(find.byType(TaskCard), findsNothing);
    });

    testWidgets('lists today\'s tasks in time order', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Second', when: at(15));
      await seedTask(tester, 'First', when: at(8));

      await pumpHome(tester);

      expect(find.byType(TaskCard), findsNWidgets(2));
      final List<String> titles = tester
          .widgetList<TaskCard>(find.byType(TaskCard))
          .map((TaskCard c) => c.task.title)
          .toList();
      expect(titles, <String>['First', 'Second']);
    });

    testWidgets('excludes tasks from other days', (WidgetTester tester) async {
      await seedTask(tester, 'Today', when: at(10));
      await seedTask(
        tester,
        'Tomorrow',
        when: at(10).add(const Duration(days: 1)),
      );

      await pumpHome(tester);

      expect(find.byType(TaskCard), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('renders the three AI actions', (WidgetTester tester) async {
      await pumpHome(tester);

      expect(find.byKey(HomeScreen.reportsKey), findsOneWidget);
      expect(find.byKey(HomeScreen.chatKey), findsOneWidget);
      expect(find.byKey(HomeScreen.settingsKey), findsOneWidget);
      expect(find.byIcon(Icons.auto_graph_outlined), findsOneWidget);
      expect(find.byIcon(Icons.assistant_outlined), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    });

    testWidgets('the reports icon opens the debrief screen', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.reportsKey));
      await settle(tester);

      expect(find.byType(ReportScreen), findsOneWidget);

      await tester.tap(find.byKey(ReportScreen.backKey));
      await settle(tester);

      expect(find.byType(ReportScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('the settings icon opens the settings screen', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.settingsKey));
      await settle(tester);

      expect(find.byType(SettingsScreen), findsOneWidget);

      // And back returns to the dashboard.
      await tester.tap(find.byKey(SettingsScreen.backKey));
      await settle(tester);

      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('summarises how many tasks are left', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'One', when: at(8));
      await seedTask(
        tester,
        'Two',
        when: at(9),
        status: TaskStatus.completed,
      );

      await pumpHome(tester);

      expect(find.textContaining('1 of 2 left'), findsOneWidget);
    });
  });

  group('Status toggling', () {
    for (final String status in <String>[
      TaskStatus.completed,
      TaskStatus.partial,
      TaskStatus.skipped,
    ]) {
      testWidgets('$status persists to SQLite and cancels the alarm', (
        WidgetTester tester,
      ) async {
        final int id = await seedTask(tester, 'Cancel me', when: at(23, 59));
        await pumpHome(tester);

        final Key actionKey = switch (status) {
          TaskStatus.completed => TaskCard.completeKey,
          TaskStatus.partial => TaskCard.partialKey,
          _ => TaskCard.skipKey,
        };

        await tester.tap(find.byKey(actionKey));
        await settle(tester);

        // Partial and skipped ask for a reason first; skip past it.
        if (find.byType(NoteSheet).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(NoteSheet.skipKey));
          await settle(tester);
        }

        // Persisted...
        final Task? stored = await readTask(tester, id);
        expect(stored!.status, status);

        // ...and the alarm is gone. This is the Phase 3 guarantee.
        expect(cancelled, contains(id));
      });
    }

    testWidgets('the resolved status is reflected back in the list', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Mark me', when: at(20));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      expect(find.text('Done'), findsOneWidget);
      expect(find.textContaining('all 1 done'), findsOneWidget);
    });

    testWidgets('tapping the active status again returns it to pending', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Undo me', when: at(23, 59));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.skipKey));
      await settle(tester);
      await tester.tap(find.byKey(NoteSheet.skipKey));
      await settle(tester);
      expect((await readTask(tester, id))!.status, TaskStatus.skipped);

      // Tapping the active status is an undo, so it asks for nothing.
      await tester.tap(find.byKey(TaskCard.skipKey));
      await settle(tester);

      expect((await readTask(tester, id))!.status, TaskStatus.pending);
      // Returning to pending re-arms the alarm, since the time is still ahead.
      expect(pendingAlarms.containsKey(id), isTrue);
    });

    testWidgets('changing one task leaves the others untouched', (
      WidgetTester tester,
    ) async {
      final int keep = await seedTask(tester, 'Keep', when: at(8));
      await seedTask(tester, 'Change', when: at(9));
      await pumpHome(tester);

      // The second card's complete button.
      await tester.tap(find.byKey(TaskCard.completeKey).last);
      await settle(tester);

      expect((await readTask(tester, keep))!.status, TaskStatus.pending);
      expect(cancelled, isNot(contains(keep)));
    });
  });

  group('Status notes', () {
    testWidgets('marking partial asks for a reason', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Refactor parser', when: at(14));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);

      expect(find.byType(NoteSheet), findsOneWidget);
      expect(find.text('What stopped you finishing?'), findsOneWidget);
      expect(find.text('Refactor parser'), findsWidgets);
    });

    testWidgets('marking skipped asks its own question', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Gym', when: at(18));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.skipKey));
      await settle(tester);

      expect(find.text('What got in the way?'), findsOneWidget);
    });

    testWidgets('completing a task never asks for a reason', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Done thing', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      expect(find.byType(NoteSheet), findsNothing);
      expect((await readTask(tester, id))!.status, TaskStatus.completed);
    });

    testWidgets('a saved reason is persisted and shown on the card', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Refactor parser', when: at(14));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);
      await tester.enterText(
        find.byKey(NoteSheet.fieldKey),
        'blocked on review',
      );
      await tester.tap(find.byKey(NoteSheet.saveKey));
      await settle(tester);

      final Task? stored = await readTask(tester, id);
      expect(stored!.status, TaskStatus.partial);
      expect(stored.note, 'blocked on review');
      expect(find.text('blocked on review'), findsOneWidget);
    });

    testWidgets('skipping the prompt still applies the status', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Gym', when: at(18));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.skipKey));
      await settle(tester);
      await tester.tap(find.byKey(NoteSheet.skipKey));
      await settle(tester);

      final Task? stored = await readTask(tester, id);
      expect(stored!.status, TaskStatus.skipped);
      expect(stored.note, isNull);
    });

    testWidgets('dismissing the sheet is treated as skipping it', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Gym', when: at(18));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.skipKey));
      await settle(tester);

      Navigator.of(tester.element(find.byType(NoteSheet))).pop();
      await settle(tester);

      final Task? stored = await readTask(tester, id);
      expect(stored!.status, TaskStatus.skipped);
      expect(stored.note, isNull);
    });

    testWidgets('an existing reason is offered for editing', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Refactor', when: at(14));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);
      await tester.enterText(find.byKey(NoteSheet.fieldKey), 'first reason');
      await tester.tap(find.byKey(NoteSheet.saveKey));
      await settle(tester);

      // Switching to skipped should pre-fill what was written before.
      await tester.tap(find.byKey(TaskCard.skipKey));
      await settle(tester);

      final TextField field =
          tester.widget<TextField>(find.byKey(NoteSheet.fieldKey));
      expect(field.controller!.text, 'first reason');

      await tester.enterText(find.byKey(NoteSheet.fieldKey), 'second reason');
      await tester.tap(find.byKey(NoteSheet.saveKey));
      await settle(tester);

      expect((await readTask(tester, id))!.note, 'second reason');
    });

    testWidgets('returning a task to pending drops its reason', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Refactor', when: at(23, 59));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);
      await tester.enterText(find.byKey(NoteSheet.fieldKey), 'stale reason');
      await tester.tap(find.byKey(NoteSheet.saveKey));
      await settle(tester);
      expect((await readTask(tester, id))!.note, 'stale reason');

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);

      final Task? stored = await readTask(tester, id);
      expect(stored!.status, TaskStatus.pending);
      expect(stored.note, isNull, reason: 'the reason no longer applies');
    });
  });

  group('Day navigation', () {
    testWidgets('starts on today with no Today shortcut', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      expect(find.byKey(HomeScreen.previousDayKey), findsOneWidget);
      expect(find.byKey(HomeScreen.nextDayKey), findsOneWidget);
      expect(find.byKey(HomeScreen.todayKey), findsNothing);
    });

    testWidgets('stepping back shows the previous day\'s tasks', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Today task', when: at(9));
      await seedTask(
        tester,
        'Yesterday task',
        when: at(9).subtract(const Duration(days: 1)),
      );

      await pumpHome(tester);
      expect(find.text('Today task'), findsOneWidget);
      expect(find.text('Yesterday task'), findsNothing);

      await tester.tap(find.byKey(HomeScreen.previousDayKey));
      await settle(tester);

      expect(find.text('Yesterday task'), findsOneWidget);
      expect(find.text('Today task'), findsNothing);
      expect(find.byKey(HomeScreen.todayKey), findsOneWidget);
    });

    testWidgets('the Today shortcut returns to the current day', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Today task', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.previousDayKey));
      await settle(tester);
      expect(find.text('Today task'), findsNothing);

      await tester.tap(find.byKey(HomeScreen.todayKey));
      await settle(tester);

      expect(find.text('Today task'), findsOneWidget);
      expect(find.byKey(HomeScreen.todayKey), findsNothing);
    });

    testWidgets('stepping forward and back returns to the same day', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Today task', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);
      expect(find.text('Today task'), findsNothing);

      await tester.tap(find.byKey(HomeScreen.previousDayKey));
      await settle(tester);
      expect(find.text('Today task'), findsOneWidget);
    });

    testWidgets('a past day can still be marked, note and all', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(
        tester,
        'Yesterday task',
        when: at(9).subtract(const Duration(days: 1)),
      );
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.previousDayKey));
      await settle(tester);

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);
      await tester.enterText(find.byKey(NoteSheet.fieldKey), 'late finish');
      await tester.tap(find.byKey(NoteSheet.saveKey));
      await settle(tester);

      final Task? stored = await readTask(tester, id);
      expect(stored!.status, TaskStatus.partial);
      expect(stored.note, 'late finish');
      expect(cancelled, contains(id));
    });

    testWidgets('the empty state names the day being viewed', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      expect(find.text('Nothing scheduled today.'), findsOneWidget);

      await tester.tap(find.byKey(HomeScreen.previousDayKey));
      await settle(tester);

      expect(find.text('Nothing scheduled this day.'), findsOneWidget);
    });
  });

  group('Task creation', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(HomeScreen.addTaskKey));
      await settle(tester);
    }

    testWidgets('the sheet opens from the floating action button', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      expect(find.byType(AddTaskSheet), findsOneWidget);
      expect(find.byKey(AddTaskSheet.titleFieldKey), findsOneWidget);
      expect(find.byKey(AddTaskSheet.timeButtonKey), findsOneWidget);
    });

    testWidgets('saving writes the task to SQLite and shows it in the list', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Buy milk',
      );
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      expect(stored, hasLength(1));
      expect(stored.single.title, 'Buy milk');
      expect(stored.single.status, TaskStatus.pending);

      expect(find.byType(AddTaskSheet), findsNothing);
      expect(find.text('Buy milk'), findsOneWidget);
    });

    testWidgets('a future time schedules the alarm on save', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Alarm please',
      );
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      final int id = stored.single.id!;

      // The sheet defaults to the next half hour, which is still ahead, so
      // the alarm must have been armed.
      expect(pendingAlarms.containsKey(id), isTrue);
      expect(pendingAlarms[id]!['title'], 'Alarm please');
    });

    testWidgets('an empty title is refused and nothing is written', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      expect(find.text('Give the task a name.'), findsOneWidget);
      expect(find.byType(AddTaskSheet), findsOneWidget);
      expect(await readToday(tester), isEmpty);
    });

    testWidgets('a whitespace-only title is refused', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.enterText(find.byKey(AddTaskSheet.titleFieldKey), '   ');
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      expect(find.text('Give the task a name.'), findsOneWidget);
      expect(await readToday(tester), isEmpty);
    });

    testWidgets('the title is trimmed before saving', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        '  Padded title  ',
      );
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      expect(stored.single.title, 'Padded title');
    });

    testWidgets('the time button opens the native picker', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.tap(find.byKey(AddTaskSheet.timeButtonKey));
      await settle(tester);

      expect(find.byType(TimePickerDialog), findsOneWidget);

      // Dismissing leaves the sheet intact and the time unchanged.
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.byType(TimePickerDialog), findsNothing);
      expect(find.byType(AddTaskSheet), findsOneWidget);
    });

    testWidgets('dismissing the sheet creates nothing', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Never saved',
      );

      Navigator.of(tester.element(find.byType(AddTaskSheet))).pop();
      await settle(tester);

      expect(await readToday(tester), isEmpty);
      expect(find.text('Nothing scheduled today.'), findsOneWidget);
    });
  });

  group('Alarm permission banner', () {
    testWidgets('permissions are asked for at launch, not at first save', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      // The prompt the user answers in place is fine to fire at launch.
      expect(notificationCalls, contains('requestNotificationsPermission'));
      expect(notificationCalls, contains('canScheduleExactNotifications'));

      // The one that leaves the app for a settings screen is not.
      expect(
        notificationCalls,
        isNot(contains('requestExactAlarmsPermission')),
      );
    });

    testWidgets('no banner when the OS will arm alarms', (
      WidgetTester tester,
    ) async {
      canScheduleExactAlarms = true;
      await pumpHome(tester);

      expect(find.byKey(HomeScreen.alarmBannerKey), findsNothing);
    });

    testWidgets('no banner on a platform that does not gate alarms', (
      WidgetTester tester,
    ) async {
      // Older Android answers null here; an unknown must never read as a
      // refusal, or every such device gets a banner it can do nothing about.
      canScheduleExactAlarms = null;
      await pumpHome(tester);

      expect(find.byKey(HomeScreen.alarmBannerKey), findsNothing);
    });

    testWidgets('a refusal is explained, not left silent', (
      WidgetTester tester,
    ) async {
      canScheduleExactAlarms = false;
      await pumpHome(tester);

      expect(find.byKey(HomeScreen.alarmBannerKey), findsOneWidget);
      expect(find.text('Reminders cannot be set'), findsOneWidget);
      expect(
        find.textContaining('will not notify you at their scheduled time'),
        findsOneWidget,
      );
      expect(find.byKey(HomeScreen.alarmBannerActionKey), findsOneWidget);
    });

    testWidgets('granting from the banner opens settings and clears it', (
      WidgetTester tester,
    ) async {
      canScheduleExactAlarms = false;
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.alarmBannerActionKey));
      await settle(tester);

      expect(notificationCalls, contains('requestExactAlarmsPermission'));
      expect(find.byKey(HomeScreen.alarmBannerKey), findsNothing);
    });

    testWidgets('granting re-arms tasks saved while alarms were blocked', (
      WidgetTester tester,
    ) async {
      canScheduleExactAlarms = false;

      // A task far enough ahead that its alarm is still live.
      await seedTask(tester, 'Dentist',
          when: today.add(const Duration(days: 3, hours: 9)));
      await pumpHome(tester);
      pendingAlarms.clear();

      await tester.tap(find.byKey(HomeScreen.alarmBannerActionKey));
      await settle(tester);

      expect(
        pendingAlarms,
        isNotEmpty,
        reason: 'a task created while blocked has no alarm until this runs',
      );
    });

    testWidgets('dismissing hides it without pretending it is fixed', (
      WidgetTester tester,
    ) async {
      canScheduleExactAlarms = false;
      await pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.alarmBannerDismissKey));
      await settle(tester);

      expect(find.byKey(HomeScreen.alarmBannerKey), findsNothing);
      expect(
        notificationCalls,
        isNot(contains('requestExactAlarmsPermission')),
        reason: 'dismissing must not silently grant anything',
      );
    });

    testWidgets('the banner is translated', (WidgetTester tester) async {
      canScheduleExactAlarms = false;
      await tester.pumpWidget(wrap(HomeScreen(day: today), language: 'ar'));
      await settle(tester);

      expect(find.text('التذكيرات معطّلة'), findsOneWidget);
      expect(find.text('السماح بالمنبّهات'), findsOneWidget);
    });
  });

  group('Completing a task', () {
    testWidgets('the checkmark completes it, and does not open the editor', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      expect(stored.single.status, TaskStatus.completed);
      expect(find.byType(AddTaskSheet), findsNothing);
    });

    testWidgets('a tap that lands just off the checkmark still completes', (
      WidgetTester tester,
    ) async {
      // The bug this replaces: a card-wide tap gesture sat over the buttons
      // with HitTestBehavior.opaque, so a thumb landing a few pixels off the
      // 44px target opened the editor instead of completing the task.
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      final Rect button = tester.getRect(find.byKey(TaskCard.completeKey));
      await tester.tapAt(Offset(
        button.center.dx - button.width / 2 + 4,
        button.center.dy + button.height / 2 - 4,
      ));
      await settle(tester);

      expect((await readToday(tester)).single.status, TaskStatus.completed);
      expect(find.byType(AddTaskSheet), findsNothing);
    });

    testWidgets('nothing over the status buttons competes for the tap', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      // No gesture detector may sit between a status button and the card.
      final Finder gestures = find.ancestor(
        of: find.byKey(TaskCard.completeKey),
        matching: find.byType(GestureDetector),
      );
      expect(
        gestures.evaluate().where((Element e) {
          final GestureDetector g = e.widget as GestureDetector;
          return g.onTap != null || g.onLongPress != null;
        }),
        isEmpty,
        reason: 'a tap here must only ever change the status',
      );
    });

    testWidgets('a completed task is struck through and faded', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);
      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      final Text title = tester.widget<Text>(find.text('Dentist'));
      expect(title.style!.decoration, TextDecoration.lineThrough);

      final Opacity faded = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('Dentist'), matching: find.byType(Opacity))
            .first,
      );
      expect(faded.opacity, lessThan(1.0));
    });

    testWidgets('a pending task is neither struck through nor faded', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      final Text title = tester.widget<Text>(find.text('Dentist'));
      expect(title.style!.decoration, isNot(TextDecoration.lineThrough));

      final Opacity faded = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('Dentist'), matching: find.byType(Opacity))
            .first,
      );
      expect(faded.opacity, 1.0);
    });

    testWidgets('completed tasks sink below the ones still to do', (
      WidgetTester tester,
    ) async {
      // Seeded out of order on purpose: the earliest is the one completed.
      await seedTask(tester, 'Early done', when: at(7),
          status: TaskStatus.completed);
      await seedTask(tester, 'Midday open', when: at(12));
      await seedTask(tester, 'Late open', when: at(18));

      final List<Task> ordered = await readToday(tester);
      expect(
        ordered.map((Task t) => t.title).toList(),
        <String>['Midday open', 'Late open', 'Early done'],
      );

      await pumpHome(tester);
      expect(
        tester.getCenter(find.text('Early done')).dy,
        greaterThan(tester.getCenter(find.text('Late open')).dy),
      );
    });

    testWidgets('partial and skipped keep their place in the timeline', (
      WidgetTester tester,
    ) async {
      // Only completed sinks. A skipped task is what the day went wrong on,
      // so it stays where it happened.
      await seedTask(tester, 'Skipped early', when: at(7),
          status: TaskStatus.skipped);
      await seedTask(tester, 'Open later', when: at(18));

      expect(
        (await readToday(tester)).map((Task t) => t.title).toList(),
        <String>['Skipped early', 'Open later'],
      );
    });
  });

  group('Immediate feedback', () {
    testWidgets('the strike-through lands on the very next frame', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      // One frame only. No settle, no waiting on the database, no waiting on
      // the eight platform-channel calls that cancel the alarm: the point of
      // the optimistic update is that none of that gates the paint.
      await tester.pump();

      final Text title = tester.widget<Text>(find.text('Dentist'));
      expect(
        title.style!.decoration,
        TextDecoration.lineThrough,
        reason: 'the checkmark must not wait on SQLite to show its effect',
      );

      await settle(tester);
      expect((await readToday(tester)).single.status, TaskStatus.completed);
    });

    testWidgets('the reorder happens on that same frame too', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Morning', when: at(8));
      await seedTask(tester, 'Evening', when: at(20));
      await pumpHome(tester);

      expect(
        tester.getCenter(find.text('Morning')).dy,
        lessThan(tester.getCenter(find.text('Evening')).dy),
      );

      // Complete the first one; it should drop below the other immediately.
      await tester.tap(find.byKey(TaskCard.completeKey).first);
      await tester.pump();

      expect(
        tester.getCenter(find.text('Morning')).dy,
        greaterThan(tester.getCenter(find.text('Evening')).dy),
        reason: 'a finished task sinks without waiting for a reload',
      );
    });

    testWidgets('undoing a completion repaints immediately as well', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9),
          status: TaskStatus.completed);
      await pumpHome(tester);

      // Tapping the status a task already has is the undo.
      await tester.tap(find.byKey(TaskCard.completeKey));
      await tester.pump();

      final Text title = tester.widget<Text>(find.text('Dentist'));
      expect(title.style!.decoration, isNot(TextDecoration.lineThrough));

      await settle(tester);
      expect((await readToday(tester)).single.status, TaskStatus.pending);
    });

    testWidgets('the optimistic state matches what the database ends up with',
        (WidgetTester tester) async {
      await seedTask(tester, 'Morning', when: at(8));
      await seedTask(tester, 'Midday', when: at(12));
      await seedTask(tester, 'Evening', when: at(20));
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.completeKey).first);
      await tester.pump();

      final List<String> painted = tester
          .widgetList<TaskCard>(find.byType(TaskCard))
          .map((TaskCard c) => c.task.title)
          .toList();

      // Once everything settles, the reload must agree with what was shown —
      // otherwise the list visibly rearranges itself a second time.
      await settle(tester);
      final List<String> reloaded = tester
          .widgetList<TaskCard>(find.byType(TaskCard))
          .map((TaskCard c) => c.task.title)
          .toList();

      expect(painted, reloaded);
      expect(
        reloaded,
        (await readToday(tester)).map((Task t) => t.title).toList(),
      );
    });
  });

  group('Adding a task leaves the others alone', () {
    testWidgets('inserting does not touch any existing row', (
      WidgetTester tester,
    ) async {
      final int keptId = await seedTask(tester, 'Existing', when: at(8));
      final int doneId = await seedTask(tester, 'Already done', when: at(9),
          status: TaskStatus.completed);
      final int skippedId = await seedTask(tester, 'Already skipped',
          when: at(10), status: TaskStatus.skipped);

      final List<Task> before = await readToday(tester);

      await pumpHome(tester);
      await tester.tap(find.byKey(HomeScreen.addTaskKey));
      await settle(tester);
      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Brand new',
      );
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> after = await readToday(tester);
      expect(after, hasLength(before.length + 1));

      Task byId(List<Task> list, int id) =>
          list.firstWhere((Task t) => t.id == id);

      for (final int id in <int>[keptId, doneId, skippedId]) {
        final Task was = byId(before, id);
        final Task now = byId(after, id);
        expect(now.title, was.title, reason: 'title changed on $id');
        expect(now.status, was.status, reason: 'status changed on $id');
        expect(now.scheduledTime, was.scheduledTime, reason: 'time on $id');
        expect(now.note, was.note, reason: 'note on $id');
        expect(now.recurrenceType, was.recurrenceType);
      }

      // And specifically: nothing was struck through by the insert.
      expect(byId(after, keptId).status, TaskStatus.pending);
      expect(find.text('Brand new'), findsOneWidget);
    });

    testWidgets('the add sheet opens empty, never prefilled from a task', (
      WidgetTester tester,
    ) async {
      // Saving a prefilled sheet would update that task instead of adding
      // one, which looks exactly like "adding a task changed my old one".
      await seedTask(tester, 'Existing', when: at(8));
      await pumpHome(tester);
      await tester.tap(find.byKey(HomeScreen.addTaskKey));
      await settle(tester);

      final TextField field = tester.widget<TextField>(
        find.byKey(AddTaskSheet.titleFieldKey),
      );
      expect(field.controller!.text, isEmpty);
      expect(find.text('New task'), findsWidgets);
      expect(find.text('Edit task'), findsNothing);
    });
  });

  group('Editing and deleting', () {
    testWidgets('swiping a task away deletes it and cancels its alarm', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Dentist');
      await pumpHome(tester);
      expect(find.text('Dentist'), findsOneWidget);

      await tester.drag(
        find.byKey(HomeScreen.dismissibleKey(id)),
        const Offset(-500, 0),
      );
      await settle(tester);

      expect(await readToday(tester), isEmpty);
      expect(find.text('Dentist'), findsNothing);

      // A deleted task must never be able to fire.
      expect(cancelled, contains(id));
    });

    testWidgets('a swipe the other way deletes it too', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Dentist');
      await pumpHome(tester);

      await tester.drag(
        find.byKey(HomeScreen.dismissibleKey(id)),
        const Offset(500, 0),
      );
      await settle(tester);

      expect(await readToday(tester), isEmpty);
    });

    testWidgets('undo puts the task back with the same id', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Dentist');
      await pumpHome(tester);

      await tester.drag(
        find.byKey(HomeScreen.dismissibleKey(id)),
        const Offset(-500, 0),
      );
      // Deleting is three async hops deep, and the snackbar only goes up
      // once the reload lands — one settle is not always enough.
      await settle(tester);
      await settle(tester);
      expect(find.text('Task deleted'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);

      final List<Task> restored = await readToday(tester);
      expect(restored, hasLength(1));
      expect(restored.single.title, 'Dentist');
      // The same primary key, so the restored task's alarm ids match the
      // ones that were cancelled.
      expect(restored.single.id, id);
      expect(find.text('Dentist'), findsOneWidget);
    });

    testWidgets('deleting does not disturb the other tasks', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Dentist', when: at(9));
      await seedTask(tester, 'Standup', when: at(11));
      await pumpHome(tester);

      await tester.drag(
        find.byKey(HomeScreen.dismissibleKey(id)),
        const Offset(-500, 0),
      );
      await settle(tester);

      final List<Task> left = await readToday(tester);
      expect(left.single.title, 'Standup');
    });

    testWidgets('tapping a task opens it for editing, prefilled', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.text('Dentist'));
      await settle(tester);

      expect(find.byType(AddTaskSheet), findsOneWidget);
      expect(find.text('Edit task'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);

      // The field holds the task as stored, not an empty form.
      final TextField field = tester.widget<TextField>(
        find.byKey(AddTaskSheet.titleFieldKey),
      );
      expect(field.controller!.text, 'Dentist');
    });

    testWidgets('long-pressing opens the same editor', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist');
      await pumpHome(tester);

      await tester.longPress(find.text('Dentist'));
      await settle(tester);

      expect(find.text('Edit task'), findsOneWidget);
    });

    testWidgets('an edit updates the row instead of adding another', (
      WidgetTester tester,
    ) async {
      final int id = await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.text('Dentist'));
      await settle(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Dentist — moved',
      );
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      expect(stored, hasLength(1), reason: 'edit replaces, never duplicates');
      expect(stored.single.id, id);
      expect(stored.single.title, 'Dentist — moved');
      expect(find.text('Dentist — moved'), findsOneWidget);
    });

    testWidgets('editing keeps the status and note already recorded', (
      WidgetTester tester,
    ) async {
      await seedTask(
        tester,
        'Dentist',
        when: at(9),
        status: TaskStatus.partial,
      );
      await pumpHome(tester);

      await tester.tap(find.text('Dentist'));
      await settle(tester);
      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Dentist visit',
      );
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      expect(
        stored.single.status,
        TaskStatus.partial,
        reason: 'renaming a task is not the same as undoing it',
      );
    });

    testWidgets('an edit can change the recurrence', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist', when: at(9));
      await pumpHome(tester);

      await tester.tap(find.text('Dentist'));
      await settle(tester);
      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.daily)),
      );
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await readToday(tester);
      expect(stored.single.recurrenceType, RecurrenceType.daily);
    });

    testWidgets('the status buttons still work through the edit gesture', (
      WidgetTester tester,
    ) async {
      await seedTask(tester, 'Dentist');
      await pumpHome(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      expect(find.byType(AddTaskSheet), findsNothing,
          reason: 'a status tap must not open the editor');
      final List<Task> stored = await readToday(tester);
      expect(stored.single.status, TaskStatus.completed);
    });
  });
}
