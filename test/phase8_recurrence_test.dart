import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/l10n/app_strings.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/home_screen.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/notification_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';
import 'package:todo_list/widgets/add_task_sheet.dart';
import 'package:todo_list/widgets/note_sheet.dart';
import 'package:todo_list/widgets/task_card.dart';

const MethodChannel _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

/// Monday 7 September 2026 — a fixed week so weekday maths is unambiguous.
final DateTime kMonday = DateTime(2026, 9, 7);
final DateTime kTuesday = DateTime(2026, 9, 8);
final DateTime kWednesday = DateTime(2026, 9, 9);
final DateTime kNextMonday = DateTime(2026, 9, 14);

/// Makes the fake OS refuse to arm alarms, the way a device does when the
/// exact-alarm permission has not been granted.
bool refuseAlarms = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Map<int, Map<Object?, Object?>> pendingAlarms =
      <int, Map<Object?, Object?>>{};
  final List<int> cancelled = <int>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.debugDatabaseName = 'phase8_test.db';
    initializeDateFormatting();
    NotificationService.configureLocalTimeZone();
  });

  setUp(() async {
    pendingAlarms.clear();
    cancelled.clear();
    refuseAlarms = false;

    final Database database = await DatabaseService.instance.database;
    await database.delete(DatabaseService.tasksTable);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();

    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationChannel,
            (MethodCall call) async {
      final Object? args = call.arguments;
      switch (call.method) {
        case 'initialize':
          // The Android plugin declares a bool return; null throws.
          return true;
        case 'zonedSchedule':
          if (refuseAlarms) {
            // What the plugin actually throws when the user has not granted
            // the exact-alarm permission.
            throw PlatformException(
              code: 'exact_alarms_not_permitted',
              message: 'Exact alarms are not permitted',
            );
          }
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

  Future<T> onDb<T>(WidgetTester tester, Future<T> Function() action) async {
    late T result;
    await tester.runAsync(() async {
      result = await action();
    });
    return result;
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

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

  Task daily(String title, {DateTime? from, int hour = 9}) => Task(
        title: title,
        scheduledTime: DateTime(
          (from ?? kMonday).year,
          (from ?? kMonday).month,
          (from ?? kMonday).day,
          hour,
        ),
        recurrenceType: RecurrenceType.daily,
      );

  Task weekly(String title, List<int> days, {DateTime? from, int hour = 9}) =>
      Task(
        title: title,
        scheduledTime: DateTime(
          (from ?? kMonday).year,
          (from ?? kMonday).month,
          (from ?? kMonday).day,
          hour,
        ),
        recurrenceType: RecurrenceType.weeklyDays,
        repeatDays: days,
      );

  // ================= Model =================

  group('Repeat day encoding', () {
    test('sorts, dedupes and drops out-of-range days', () {
      expect(Task.encodeRepeatDays(<int>[5, 1, 3]), '1,3,5');
      expect(Task.encodeRepeatDays(<int>[2, 2, 2]), '2');
      expect(Task.encodeRepeatDays(<int>[0, 8, 3]), '3');
      expect(Task.encodeRepeatDays(<int>[]), isNull);
      expect(Task.encodeRepeatDays(null), isNull);
    });

    test('decodes and survives a corrupt value', () {
      expect(Task.decodeRepeatDays('1,3,5'), <int>[1, 3, 5]);
      expect(Task.decodeRepeatDays(' 2 , 4 '), <int>[2, 4]);
      expect(Task.decodeRepeatDays('9,x,'), isNull);
      expect(Task.decodeRepeatDays(''), isNull);
      expect(Task.decodeRepeatDays(null), isNull);
    });

    test('round-trips through the map', () {
      final Task task = weekly('W', <int>[1, 4, 7]);
      final Task restored = Task.fromMap(task.toMap());
      expect(restored.repeatDays, <int>[1, 4, 7]);
      expect(restored.recurrenceType, RecurrenceType.weeklyDays);
    });
  });

  group('occursOn', () {
    test('a one-off matches only its own date', () {
      final Task task = Task(title: 'Once', scheduledTime: kMonday);
      expect(task.occursOn(kMonday), isTrue);
      expect(task.occursOn(kTuesday), isFalse);
      expect(task.occursOn(kNextMonday), isFalse);
    });

    test('daily matches every day from its start', () {
      final Task task = daily('Daily');
      expect(task.occursOn(kMonday), isTrue);
      expect(task.occursOn(kWednesday), isTrue);
      expect(task.occursOn(kNextMonday), isTrue);
    });

    test('nothing recurs before its start date', () {
      final Task task = daily('Daily', from: kWednesday);
      expect(task.occursOn(kMonday), isFalse,
          reason: 'adding a task must not backfill history');
      expect(task.occursOn(kWednesday), isTrue);
    });

    test('weekly matches only its selected weekdays', () {
      // Monday and Wednesday.
      final Task task = weekly('Gym', <int>[1, 3]);
      expect(task.occursOn(kMonday), isTrue);
      expect(task.occursOn(kTuesday), isFalse);
      expect(task.occursOn(kWednesday), isTrue);
      expect(task.occursOn(kNextMonday), isTrue, reason: 'and the week after');
    });

    test('a weekly task with no days matches nothing', () {
      final Task task = Task(
        title: 'Broken',
        scheduledTime: kMonday,
        recurrenceType: RecurrenceType.weeklyDays,
      );
      expect(task.occursOn(kMonday), isFalse);
    });

    test('occurrenceOn keeps the time and moves the date', () {
      final Task task = daily('Daily', hour: 14);
      final DateTime occurrence = task.occurrenceOn(kWednesday);
      expect(occurrence, DateTime(2026, 9, 9, 14));
    });
  });

  group('Per-day status', () {
    test('a one-off reports its stored status on any day', () {
      final Task task = Task(
        title: 'Once',
        scheduledTime: kMonday,
        status: TaskStatus.completed,
      );
      expect(task.statusOn(kMonday), TaskStatus.completed);
      expect(task.statusOn(kTuesday), TaskStatus.completed);
    });

    test('a recurring task only counts the day it was marked on', () {
      final Task task = daily('Daily').copyWith(
        status: TaskStatus.completed,
        note: 'done early',
        statusDate: kMonday,
      );

      expect(task.statusOn(kMonday), TaskStatus.completed);
      expect(task.noteOn(kMonday), 'done early');

      // The whole point: tomorrow starts clean.
      expect(task.statusOn(kTuesday), TaskStatus.pending);
      expect(task.noteOn(kTuesday), isNull);
    });

    test('a recurring task with no status date is pending everywhere', () {
      final Task task = daily('Daily').copyWith(status: TaskStatus.completed);
      expect(task.statusOn(kMonday), TaskStatus.pending);
    });
  });

  // ================= Database =================

  group('Querying by day', () {
    testWidgets('a daily task appears on every day from its start', (
      WidgetTester tester,
    ) async {
      await onDb(tester,
          () => DatabaseService.instance.insertTask(daily('Stretch')));

      for (final DateTime day in <DateTime>[
        kMonday,
        kTuesday,
        kWednesday,
        kNextMonday,
      ]) {
        final List<Task> tasks = await onDb(
          tester,
          () => DatabaseService.instance.getTasksForDate(day),
        );
        expect(tasks.map((Task t) => t.title), <String>['Stretch'],
            reason: 'missing on $day');
      }
    });

    testWidgets('a weekly task appears only on its days', (
      WidgetTester tester,
    ) async {
      await onDb(
        tester,
        () => DatabaseService.instance.insertTask(weekly('Gym', <int>[1, 3])),
      );

      Future<List<Task>> on(DateTime day) => onDb(
            tester,
            () => DatabaseService.instance.getTasksForDate(day),
          );

      expect((await on(kMonday)).length, 1);
      expect((await on(kTuesday)), isEmpty);
      expect((await on(kWednesday)).length, 1);
      expect((await on(kNextMonday)).length, 1);
    });

    testWidgets('one-off and recurring tasks share the day, in time order', (
      WidgetTester tester,
    ) async {
      await onDb(tester, () async {
        await DatabaseService.instance
            .insertTask(daily('Morning stretch', hour: 7));
        await DatabaseService.instance.insertTask(
          Task(
            title: 'One-off meeting',
            scheduledTime: DateTime(2026, 9, 9, 15),
          ),
        );
        await DatabaseService.instance
            .insertTask(weekly('Gym', <int>[3], hour: 18));
      });

      final List<Task> tasks = await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kWednesday),
      );

      expect(
        tasks.map((Task t) => t.title),
        <String>['Morning stretch', 'One-off meeting', 'Gym'],
      );
    });

    testWidgets('a recurring task does not leak into earlier days', (
      WidgetTester tester,
    ) async {
      await onDb(
        tester,
        () => DatabaseService.instance
            .insertTask(daily('Started Wednesday', from: kWednesday)),
      );

      expect(
        await onDb(tester,
            () => DatabaseService.instance.getTasksForDate(kMonday)),
        isEmpty,
      );
    });

    testWidgets('occurrences expand across a range with per-day status', (
      WidgetTester tester,
    ) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );
      await onDb(
        tester,
        () => DatabaseService.instance.updateStatusWithNote(
          id,
          TaskStatus.completed,
          'felt good',
          forDate: kTuesday,
        ),
      );

      final List<Task> occurrences = await onDb(
        tester,
        () => DatabaseService.instance
            .getOccurrencesBetween(kMonday, DateTime(2026, 9, 10)),
      );

      // Mon, Tue, Wed.
      expect(occurrences, hasLength(3));
      expect(occurrences[0].status, TaskStatus.pending);
      expect(occurrences[1].status, TaskStatus.completed);
      expect(occurrences[1].note, 'felt good');
      expect(occurrences[2].status, TaskStatus.pending);
      expect(occurrences[2].note, isNull);
    });

    testWidgets('status counts cover every occurrence in the range', (
      WidgetTester tester,
    ) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );
      await onDb(
        tester,
        () => DatabaseService.instance.updateStatusWithNote(
          id,
          TaskStatus.skipped,
          null,
          forDate: kMonday,
        ),
      );

      final Map<String, int> counts = await onDb(
        tester,
        () => DatabaseService.instance
            .getStatusCounts(kMonday, DateTime(2026, 9, 10)),
      );

      expect(counts[TaskStatus.skipped], 1);
      expect(counts[TaskStatus.pending], 2);
    });
  });

  group('Schema migration to v3', () {
    testWidgets('a v2 row becomes a one-off task with null recurrence', (
      WidgetTester tester,
    ) async {
      await onDb(tester, () async {
        await DatabaseService.instance.close();

        final String path =
            '${await databaseFactory.getDatabasesPath()}/migration_v3.db';
        await databaseFactory.deleteDatabase(path);

        final Database v2 = await databaseFactory.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (Database db, int version) async {
              await db.execute(
                'CREATE TABLE tasks ('
                'id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'title TEXT NOT NULL, '
                'scheduled_time INTEGER NOT NULL, '
                "status TEXT NOT NULL DEFAULT 'pending', "
                'created_at INTEGER NOT NULL, '
                'note TEXT)',
              );
            },
          ),
        );
        await v2.insert('tasks', <String, Object?>{
          'title': 'Legacy v2 task',
          'scheduled_time': DateTime(2026, 9, 9, 9).millisecondsSinceEpoch,
          'status': TaskStatus.partial,
          'created_at': DateTime(2026, 9, 8).millisecondsSinceEpoch,
          'note': 'old reason',
        });
        await v2.close();

        DatabaseService.debugDatabaseName = 'migration_v3.db';
      });

      final List<Task> tasks = await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kWednesday),
      );

      expect(tasks, hasLength(1));
      expect(tasks.single.title, 'Legacy v2 task');
      expect(tasks.single.note, 'old reason', reason: 'v2 data survives');
      expect(tasks.single.recurrenceType, RecurrenceType.none);
      expect(tasks.single.repeatDays, isNull);
      expect(tasks.single.statusDate, isNull);

      // And the new columns are writable.
      await onDb(tester, () async {
        await DatabaseService.instance.updateStatusWithNote(
          tasks.single.id!,
          TaskStatus.completed,
          'now done',
          forDate: kWednesday,
        );
      });
      final Task? updated = await onDb(
        tester,
        () => DatabaseService.instance.getTaskById(tasks.single.id!),
      );
      expect(updated!.statusDate, isNotNull);

      await onDb(tester, () async {
        await DatabaseService.instance.close();
        DatabaseService.debugDatabaseName = 'phase8_test.db';
      });
    });
  });

  // ================= Notifications =================

  group('Recurring alarms', () {
    late NotificationService service;

    setUp(() async {
      service = NotificationService.withPlugin(
        FlutterLocalNotificationsPlugin(),
      );
      await service.init();
      pendingAlarms.clear();
      cancelled.clear();
    });

    Map<Object?, Object?> alarm(int id) => pendingAlarms[id]!;

    test('a daily task matches on time only', () async {
      final int armed = await service.scheduleForTask(
        daily('Stretch').copyWith(id: 5),
      );

      expect(armed, 1);
      expect(pendingAlarms.keys, <int>[5]);
      expect(
        alarm(5)['matchDateTimeComponents'],
        DateTimeComponents.time.index,
      );
    });

    test('a weekly task arms one alarm per selected day', () async {
      final int armed = await service.scheduleForTask(
        weekly('Gym', <int>[1, 3, 5]).copyWith(id: 7),
      );

      expect(armed, 3);
      expect(pendingAlarms, hasLength(3));
      for (final int weekday in <int>[1, 3, 5]) {
        final int id = NotificationService.weeklyNotificationId(7, weekday);
        expect(pendingAlarms.containsKey(id), isTrue, reason: 'day $weekday');
        expect(
          alarm(id)['matchDateTimeComponents'],
          DateTimeComponents.dayOfWeekAndTime.index,
        );
      }
    });

    test('each weekly alarm lands on its own weekday', () async {
      await service.scheduleForTask(
        weekly('Gym', <int>[2, 6]).copyWith(id: 9),
      );

      for (final int weekday in <int>[2, 6]) {
        final int id = NotificationService.weeklyNotificationId(9, weekday);
        final String iso =
            alarm(id)['scheduledDateTimeISO8601']! as String;
        expect(DateTime.parse(iso).weekday, weekday);
      }
    });

    test('weekly ids never collide with a plain task id', () {
      final Set<int> ids = <int>{};
      for (int taskId = 1; taskId <= 200; taskId++) {
        ids.add(taskId);
        for (int weekday = 1; weekday <= 7; weekday++) {
          ids.add(NotificationService.weeklyNotificationId(taskId, weekday));
        }
      }
      // 200 plain ids + 200*7 weekly ids, all distinct.
      expect(ids, hasLength(200 + 200 * 7));
    });

    test('a one-off still schedules a single non-repeating alarm', () async {
      final int armed = await service.scheduleForTask(
        Task(
          title: 'Once',
          scheduledTime: DateTime.now().add(const Duration(hours: 2)),
        ).copyWith(id: 3),
      );

      expect(armed, 1);
      expect(alarm(3).containsKey('matchDateTimeComponents'), isFalse);
    });

    test('a one-off in the past arms nothing', () async {
      final int armed = await service.scheduleForTask(
        Task(
          title: 'Missed',
          scheduledTime: DateTime.now().subtract(const Duration(hours: 2)),
        ).copyWith(id: 4),
      );

      expect(armed, 0);
      expect(pendingAlarms, isEmpty);
    });

    test('a daily task in the past still arms — it repeats', () async {
      final int armed = await service.scheduleForTask(
        daily('Stretch', from: DateTime(2020)).copyWith(id: 6),
      );
      expect(armed, 1);
      expect(pendingAlarms, hasLength(1));
    });

    test('cancelling clears every weekday slot', () async {
      await service.scheduleForTask(
        weekly('Gym', <int>[1, 3, 5]).copyWith(id: 11),
      );
      expect(pendingAlarms, hasLength(3));

      await service.cancelNotification(11);

      expect(pendingAlarms, isEmpty);
      // The plain id plus all seven slots are swept.
      expect(cancelled, contains(11));
      for (int weekday = 1; weekday <= 7; weekday++) {
        expect(
          cancelled,
          contains(NotificationService.weeklyNotificationId(11, weekday)),
        );
      }
    });

    test('rescheduling replaces the previous set of alarms', () async {
      final Task task = weekly('Gym', <int>[1, 3, 5]).copyWith(id: 12);
      await service.scheduleForTask(task);
      expect(pendingAlarms, hasLength(3));

      await service.scheduleForTask(
        task.copyWith(repeatDays: <int>[2]),
      );

      expect(pendingAlarms, hasLength(1));
      expect(
        pendingAlarms.keys.single,
        NotificationService.weeklyNotificationId(12, 2),
      );
    });
  });

  // ================= UI =================

  group('Add task sheet', () {
    Future<void> openSheet(WidgetTester tester, {String language = 'en'}) async {
      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday),
          language: language));
      await settle(tester);
      await tester.tap(find.byKey(HomeScreen.addTaskKey));
      await settle(tester);
    }

    testWidgets('offers date chips and recurrence chips', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);

      expect(find.byKey(AddTaskSheet.todayChipKey), findsOneWidget);
      expect(find.byKey(AddTaskSheet.tomorrowChipKey), findsOneWidget);
      expect(find.byKey(AddTaskSheet.dateButtonKey), findsOneWidget);
      for (final String type in RecurrenceType.values) {
        expect(find.byKey(AddTaskSheet.recurrenceKey(type)), findsOneWidget);
      }
    });

    testWidgets('weekday chips appear only for specific days', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);
      expect(find.byKey(AddTaskSheet.weekdayKey(1)), findsNothing);

      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.weeklyDays)),
      );
      await settle(tester);

      for (int weekday = 1; weekday <= 7; weekday++) {
        expect(find.byKey(AddTaskSheet.weekdayKey(weekday)), findsOneWidget);
      }
    });

    testWidgets('saves a daily task and arms a repeating alarm', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Stretch',
      );
      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.daily)),
      );
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kWednesday),
      );
      expect(stored.single.recurrenceType, RecurrenceType.daily);
      expect(pendingAlarms, hasLength(1));
      expect(
        pendingAlarms.values.single['matchDateTimeComponents'],
        DateTimeComponents.time.index,
      );
    });

    testWidgets('saves specific weekdays', (WidgetTester tester) async {
      await openSheet(tester);

      await tester.enterText(find.byKey(AddTaskSheet.titleFieldKey), 'Gym');
      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.weeklyDays)),
      );
      await settle(tester);

      // Wednesday is pre-selected from the sheet's date; add Friday.
      await tester.tap(find.byKey(AddTaskSheet.weekdayKey(5)));
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      final List<Task> stored = await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kWednesday),
      );
      expect(stored.single.recurrenceType, RecurrenceType.weeklyDays);
      expect(stored.single.repeatDays, <int>[3, 5]);
    });

    testWidgets('an alarm the OS refuses is not reported as a failed save', (
      WidgetTester tester,
    ) async {
      refuseAlarms = true;
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Call the bank',
      );
      // Daily, so an alarm is always attempted — a one-off on a day already
      // past arms nothing and would never reach the OS.
      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.daily)),
      );
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      // The row is what matters, and it is committed before the alarm.
      final List<Task> stored = await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kWednesday),
      );
      expect(stored.single.title, 'Call the bank');

      // The sheet closes and says what actually went wrong, rather than
      // sitting there claiming the task could not be saved.
      expect(find.byType(AddTaskSheet), findsNothing);
      expect(find.byKey(AddTaskSheet.errorKey), findsNothing);
      expect(
        find.textContaining('the reminder could not be set'),
        findsOneWidget,
      );
    });

    testWidgets('an Arabic session still stores ASCII digits and integers', (
      WidgetTester tester,
    ) async {
      await openSheet(tester, language: 'ar');

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'اجتماع',
      );
      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.weeklyDays)),
      );
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.weekdayKey(5)));
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      // Read the raw row: Arabic-Indic digits reaching SQLite would show up
      // here, and would break every int and date parser downstream.
      final List<Map<String, Object?>> rows = await onDb(
        tester,
        () async {
          final Database db = await DatabaseService.instance.database;
          return db.query(DatabaseService.tasksTable);
        },
      );

      final Map<String, Object?> row = rows.single;
      expect(row['scheduled_time'], isA<int>());
      expect(row['created_at'], isA<int>());
      expect(row['status'], TaskStatus.pending);
      expect(row['recurrence_type'], RecurrenceType.weeklyDays);
      expect(row['repeat_days'], matches(RegExp(r'^[0-9](,[0-9])*$')));
      expect(row['title'], 'اجتماع');
    });

    testWidgets('refuses specific days with none selected', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);

      await tester.enterText(find.byKey(AddTaskSheet.titleFieldKey), 'Gym');
      await tester.tap(
        find.byKey(AddTaskSheet.recurrenceKey(RecurrenceType.weeklyDays)),
      );
      await settle(tester);

      // Clear the seeded weekday.
      await tester.tap(find.byKey(AddTaskSheet.weekdayKey(3)));
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      expect(find.text(AppStrings.en.pickAtLeastOneDay), findsOneWidget);
      expect(
        await onDb(tester,
            () => DatabaseService.instance.getTasksForDate(kWednesday)),
        isEmpty,
      );
    });

    testWidgets('the tomorrow chip schedules for the next day', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);

      await tester.enterText(
        find.byKey(AddTaskSheet.titleFieldKey),
        'Tomorrow task',
      );
      await tester.tap(find.byKey(AddTaskSheet.tomorrowChipKey));
      await settle(tester);
      await tester.tap(find.byKey(AddTaskSheet.saveButtonKey));
      await settle(tester);

      expect(
        await onDb(tester,
            () => DatabaseService.instance.getTasksForDate(kWednesday)),
        isEmpty,
      );
      final List<Task> tomorrow = await onDb(
        tester,
        () => DatabaseService.instance
            .getTasksForDate(kWednesday.add(const Duration(days: 1))),
      );
      expect(tomorrow.single.title, 'Tomorrow task');
    });

    testWidgets('the date picker opens from the custom chip', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);

      await tester.tap(find.byKey(AddTaskSheet.dateButtonKey));
      await settle(tester);

      expect(find.byType(DatePickerDialog), findsOneWidget);
    });

    testWidgets('the recurrence chips are translated in Arabic', (
      WidgetTester tester,
    ) async {
      await openSheet(tester, language: 'ar');

      expect(find.text(AppStrings.ar.repeatOnce), findsOneWidget);
      expect(find.text(AppStrings.ar.repeatDaily), findsOneWidget);
      expect(find.text(AppStrings.ar.repeatSpecificDays), findsOneWidget);
      expect(find.text(AppStrings.ar.dateTomorrow), findsOneWidget);
    });
  });

  group('Home screen with recurrence', () {
    testWidgets('a daily task shows on whichever day is open', (
      WidgetTester tester,
    ) async {
      await onDb(tester,
          () => DatabaseService.instance.insertTask(daily('Stretch')));

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);
      expect(find.text('Stretch'), findsOneWidget);

      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);
      expect(find.text('Stretch'), findsOneWidget);
    });

    testWidgets('a weekly task only shows on its weekdays', (
      WidgetTester tester,
    ) async {
      // Wednesday only.
      await onDb(
        tester,
        () => DatabaseService.instance.insertTask(weekly('Gym', <int>[3])),
      );

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);
      expect(find.text('Gym'), findsOneWidget);

      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);
      expect(find.text('Gym'), findsNothing);
    });

    testWidgets('the card labels the recurrence', (WidgetTester tester) async {
      await onDb(tester,
          () => DatabaseService.instance.insertTask(daily('Stretch')));

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      expect(find.text(AppStrings.en.repeatsDaily), findsOneWidget);
      expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);
    });

    testWidgets('completing today does not complete tomorrow', (
      WidgetTester tester,
    ) async {
      await onDb(tester,
          () => DatabaseService.instance.insertTask(daily('Stretch')));

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);
      expect(find.text(AppStrings.en.statusDone), findsOneWidget);

      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);

      // The whole reason status is dated.
      expect(find.text('Stretch'), findsOneWidget);
      expect(find.text(AppStrings.en.statusDone), findsNothing);
    });

    testWidgets('a note on one occurrence stays on that day', (
      WidgetTester tester,
    ) async {
      await onDb(tester,
          () => DatabaseService.instance.insertTask(daily('Stretch')));

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      await tester.tap(find.byKey(TaskCard.partialKey));
      await settle(tester);
      await tester.enterText(find.byKey(NoteSheet.fieldKey), 'knee hurt');
      await tester.tap(find.byKey(NoteSheet.saveKey));
      await settle(tester);
      expect(find.text('knee hurt'), findsOneWidget);

      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);

      expect(find.text('knee hurt'), findsNothing);
    });

    testWidgets('the summary counts the open day only', (
      WidgetTester tester,
    ) async {
      await onDb(tester, () async {
        await DatabaseService.instance.insertTask(daily('Stretch'));
        await DatabaseService.instance.insertTask(
          Task(title: 'One-off', scheduledTime: DateTime(2026, 9, 9, 15)),
        );
      });

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      expect(find.textContaining('2 of 2 left'), findsOneWidget);

      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);

      // Only the daily task carries over.
      expect(find.textContaining('1 of 1 left'), findsOneWidget);
    });
  });

  group('Notification body language', () {
    late NotificationService service;

    setUp(() async {
      service = NotificationService.withPlugin(
        FlutterLocalNotificationsPlugin(),
      );
      await service.init();
      pendingAlarms.clear();
    });

    void setLanguage(String code) {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'language_code': code},
      );
      SharedPreferences.resetStatic();
      SettingsService.instance.resetCacheForTesting();
    }

    test('formats the clock into the localised sentence', () {
      final DateTime at = DateTime(2026, 9, 9, 14, 5);
      expect(
        NotificationService.defaultBody(at, AppStrings.en),
        'Scheduled for 14:05',
      );
      expect(
        NotificationService.defaultBody(at, AppStrings.ar),
        'موعد المهمة: 14:05',
      );
    });

    test('pads single-digit hours and minutes', () {
      expect(
        NotificationService.defaultBody(DateTime(2026, 9, 9, 7, 5),
            AppStrings.en),
        'Scheduled for 07:05',
      );
    });

    test('resolves strings from the stored language', () async {
      setLanguage('ar');
      expect((await service.resolveStrings()).languageCode, 'ar');

      setLanguage('en');
      expect((await service.resolveStrings()).languageCode, 'en');
    });

    test('a one-off alarm is worded in the active language', () async {
      setLanguage('ar');
      await service.scheduleNotification(
        21,
        'مهمة',
        DateTime.now().add(const Duration(hours: 3)),
      );

      expect(pendingAlarms[21]!['body'], startsWith('موعد المهمة:'));
    });

    test('a daily alarm is worded in the active language', () async {
      setLanguage('ar');
      await service.scheduleForTask(daily('يوميّة', hour: 8).copyWith(id: 22));

      expect(
        pendingAlarms[22]!['body'],
        NotificationService.defaultBody(
          DateTime(2026, 9, 7, 8),
          AppStrings.ar,
        ),
      );
    });

    test('every weekly alarm carries the same localised body', () async {
      setLanguage('ar');
      await service.scheduleForTask(
        weekly('نادي', <int>[1, 4], hour: 18).copyWith(id: 23),
      );

      for (final int weekday in <int>[1, 4]) {
        final int id = NotificationService.weeklyNotificationId(23, weekday);
        expect(pendingAlarms[id]!['body'], 'موعد المهمة: 18:00');
      }
    });

    test('English stays English', () async {
      setLanguage('en');
      await service.scheduleForTask(daily('Stretch', hour: 9).copyWith(id: 24));

      expect(pendingAlarms[24]!['body'], 'Scheduled for 09:00');
    });

    test('an explicit body is never overridden by the language', () async {
      setLanguage('ar');
      await service.scheduleNotification(
        25,
        'Task',
        DateTime.now().add(const Duration(hours: 2)),
        body: 'Custom body',
      );

      expect(pendingAlarms[25]!['body'], 'Custom body');
    });

    test('the language in force at schedule time is the one used', () async {
      setLanguage('en');
      await service.scheduleForTask(daily('Stretch', hour: 9).copyWith(id: 26));
      expect(pendingAlarms[26]!['body'], startsWith('Scheduled for'));

      // Switching language and re-arming rewrites the pending alarm.
      setLanguage('ar');
      await service.rescheduleAll(
        <Task>[daily('Stretch', hour: 9).copyWith(id: 26)],
      );
      expect(pendingAlarms[26]!['body'], startsWith('موعد المهمة:'));
    });

    testWidgets('live alarms are the recurring plus pending future ones', (
      WidgetTester tester,
    ) async {
      await onDb(tester, () async {
        await DatabaseService.instance.insertTask(daily('Recurring'));
        await DatabaseService.instance.insertTask(
          Task(
            title: 'Future one-off',
            scheduledTime: DateTime.now().add(const Duration(days: 1)),
          ),
        );
        await DatabaseService.instance.insertTask(
          Task(
            title: 'Past one-off',
            scheduledTime: DateTime.now().subtract(const Duration(days: 1)),
          ),
        );
      });

      final List<Task> live = await onDb(
        tester,
        () => DatabaseService.instance.getTasksWithLiveAlarms(),
      );

      expect(
        live.map((Task t) => t.title).toSet(),
        <String>{'Recurring', 'Future one-off'},
        reason: 'a past one-off has no alarm left to re-arm',
      );
    });
  });

  group('Weekday labels', () {
    test('start on Monday and match DateTime.weekday', () {
      final List<String> english = AddTaskSheet.weekdayLabels('en');
      expect(english, hasLength(7));
      expect(english.first, 'Mon');
      expect(english.last, 'Sun');
    });

    test('are localised for Arabic', () {
      final List<String> arabic = AddTaskSheet.weekdayLabels('ar');
      expect(arabic, hasLength(7));
      expect(RegExp(r'[؀-ۿ]').hasMatch(arabic.first), isTrue);
      expect(arabic.first, isNot(AddTaskSheet.weekdayLabels('en').first));
    });
  });
}
