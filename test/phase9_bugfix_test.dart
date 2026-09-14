import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:todo_list/l10n/app_strings.dart';
import 'package:todo_list/models/report_range.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/home_screen.dart';
import 'package:todo_list/screens/report_screen.dart';
import 'package:todo_list/services/ai_service.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/notification_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';
import 'package:todo_list/widgets/add_task_sheet.dart';
import 'package:todo_list/widgets/task_card.dart';

const MethodChannel _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

/// Monday 7 September 2026.
final DateTime kMonday = DateTime(2026, 9, 7);
final DateTime kTuesday = DateTime(2026, 9, 8);
final DateTime kWednesday = DateTime(2026, 9, 9);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Map<int, Map<Object?, Object?>> pendingAlarms =
      <int, Map<Object?, Object?>>{};
  final List<int> cancelled = <int>[];

  /// Makes the fake plugin throw on cancel, the way the real one does in a
  /// release build missing its Gson keep rules.
  bool cancelThrows = false;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.debugDatabaseName = 'phase9_test.db';
    initializeDateFormatting();
    NotificationService.configureLocalTimeZone();
  });

  setUp(() async {
    pendingAlarms.clear();
    cancelled.clear();
    cancelThrows = false;

    final Database database = await DatabaseService.instance.database;
    await database.delete(DatabaseService.tasksTable);
    await database.delete(DatabaseService.completionsTable);

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
          return true;
        case 'zonedSchedule':
          final Map<Object?, Object?> map = args! as Map<Object?, Object?>;
          pendingAlarms[map['id']! as int] = map;
          return null;
        case 'cancel':
          if (cancelThrows) {
            throw PlatformException(
              code: 'error',
              message: 'Missing type parameter.',
            );
          }
          final int id = (args! as Map<Object?, Object?>)['id']! as int;
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
    for (int i = 0; i < 12; i++) {
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
      supportedLocales: const <Locale>[Locale('en'), Locale('ar'), Locale('fr')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );
  }

  /// Tears the screen down and builds a fresh one on a reopened database —
  /// as close to an app restart as a widget test gets.
  Future<void> restart(WidgetTester tester, DateTime day) async {
    // Let any reload still in flight land before the handle goes away.
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await onDb(tester, () => DatabaseService.instance.close());
    await tester.pumpWidget(wrap(HomeScreen(key: UniqueKey(), day: day)));
    await settle(tester);
  }

  Task daily(String title, {DateTime? from, int hour = 9, int minute = 0}) {
    final DateTime start = from ?? kMonday;
    return Task(
      title: title,
      scheduledTime:
          DateTime(start.year, start.month, start.day, hour, minute),
      recurrenceType: RecurrenceType.daily,
    );
  }

  bool isStruckThrough(WidgetTester tester, String title) {
    final Text text = tester.widget<Text>(find.text(title));
    return text.style?.decoration == TextDecoration.lineThrough;
  }

  // ================= 1. Local dates =================

  group('Local calendar dates', () {
    test('a UTC instant is held as local time', () {
      final DateTime utc = DateTime.utc(2026, 9, 9, 12);
      final Task task = Task(title: 'UTC', scheduledTime: utc);

      expect(task.scheduledTime.isUtc, isFalse);
      expect(task.scheduledTime, utc.toLocal());
      expect(task.scheduledTime.isAtSameMomentAs(utc), isTrue);
    });

    test('dayStart lands on the local calendar day, even from UTC', () {
      final DateTime utc = DateTime.utc(2026, 9, 9, 12);
      final DateTime local = utc.toLocal();
      expect(
        Task.dayStart(utc),
        DateTime(local.year, local.month, local.day),
      );
    });

    test('addDays steps the calendar and always lands on midnight', () {
      expect(Task.addDays(DateTime(2026, 12, 31, 18), 1), DateTime(2027));
      expect(Task.addDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));

      // Every day across a whole year, which covers any DST change the
      // machine running this has: never 23:00, never the same day twice.
      DateTime day = DateTime(2026);
      for (int i = 0; i < 366; i++) {
        final DateTime next = Task.addDays(day, 1);
        expect(next.hour, 0, reason: 'after $day');
        expect(next.day == day.day && next.month == day.month, isFalse);
        day = next;
      }
    });

    test('dayKey round-trips', () {
      expect(Task.dayKey(DateTime(2026, 9, 7, 23, 59)), 20260907);
      expect(Task.fromDayKey(20260907), DateTime(2026, 9, 7));
    });

    test('report ranges count calendar days', () {
      final DateTime wednesday = DateTime(2026, 9, 9, 15);
      expect(ReportRange.today.dayCount(wednesday), 1);
      expect(ReportRange.lastThreeDays.dayCount(wednesday), 3);
      expect(ReportRange.thisWeek.dayCount(wednesday), 3);
      expect(ReportRange.thisWeek.start(wednesday), kMonday);
      expect(ReportRange.today.end(wednesday), DateTime(2026, 9, 10));
    });
  });

  // ================= 2. Recurring completion =================

  group('Recurring completion history', () {
    testWidgets('each day keeps its own outcome', (WidgetTester tester) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );

      await onDb(tester, () async {
        await DatabaseService.instance.updateStatusWithNote(
            id, TaskStatus.completed, null,
            forDate: kMonday);
        // The old single status slot let this overwrite Monday.
        await DatabaseService.instance.updateStatusWithNote(
            id, TaskStatus.skipped, 'rain',
            forDate: kTuesday);
      });

      Future<Task> on(DateTime day) async => (await onDb(
            tester,
            () => DatabaseService.instance.getTasksForDate(day),
          ))
              .single;

      expect((await on(kMonday)).statusOn(kMonday), TaskStatus.completed);
      final Task tuesday = await on(kTuesday);
      expect(tuesday.statusOn(kTuesday), TaskStatus.skipped);
      expect(tuesday.noteOn(kTuesday), 'rain');
      expect((await on(kWednesday)).statusOn(kWednesday), TaskStatus.pending);
    });

    testWidgets('the series row itself is never marked done', (
      WidgetTester tester,
    ) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );
      await onDb(
        tester,
        () => DatabaseService.instance.updateStatusWithNote(
            id, TaskStatus.completed, null,
            forDate: kMonday),
      );

      final Task? row =
          await onDb(tester, () => DatabaseService.instance.getTaskById(id));
      expect(row!.status, TaskStatus.pending);
      expect(row.statusDate, isNull);
    });

    testWidgets('an edit made from a completed day does not stamp the series',
        (WidgetTester tester) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );
      await onDb(
        tester,
        () => DatabaseService.instance.updateStatusWithNote(
            id, TaskStatus.completed, 'done',
            forDate: kMonday),
      );

      // What the edit sheet saves: the day's copy, status and all.
      final Task loaded = (await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kMonday),
      ))
          .single;
      await onDb(
        tester,
        () => DatabaseService.instance
            .updateTask(loaded.copyWith(title: 'Stretch longer')),
      );

      final Task tuesday = (await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kTuesday),
      ))
          .single;
      expect(tuesday.title, 'Stretch longer');
      expect(tuesday.statusOn(kTuesday), TaskStatus.pending);

      final Task monday = (await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kMonday),
      ))
          .single;
      expect(monday.statusOn(kMonday), TaskStatus.completed);
    });

    testWidgets('the checkmark stays checked and struck through after restart',
        (WidgetTester tester) async {
      await onDb(tester,
          () => DatabaseService.instance.insertTask(daily('Stretch')));

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);
      expect(find.text(AppStrings.en.statusDone), findsOneWidget);
      expect(isStruckThrough(tester, 'Stretch'), isTrue);

      await restart(tester, kWednesday);

      expect(find.text(AppStrings.en.statusDone), findsOneWidget,
          reason: 'the completion must survive a reload');
      expect(isStruckThrough(tester, 'Stretch'), isTrue);

      // And the next day's instance is still open.
      await tester.tap(find.byKey(HomeScreen.nextDayKey));
      await settle(tester);
      expect(find.text(AppStrings.en.statusDone), findsNothing);
      expect(isStruckThrough(tester, 'Stretch'), isFalse);
    });

    testWidgets('tapping the checkmark again unchecks only that day', (
      WidgetTester tester,
    ) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );
      await onDb(
        tester,
        () => DatabaseService.instance.updateStatusWithNote(
            id, TaskStatus.completed, null,
            forDate: kTuesday),
      );

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);
      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);
      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      expect(find.text(AppStrings.en.statusDone), findsNothing);
      final List<TaskCompletion> history = await onDb(
        tester,
        () => DatabaseService.instance.getCompletionsForTask(id),
      );
      expect(history.map((TaskCompletion c) => c.day), <int>[20260908]);
    });

    testWidgets('completing today keeps the repeating alarm, from tomorrow', (
      WidgetTester tester,
    ) async {
      final DateTime now = DateTime.now();
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(
          daily('Stretch', from: Task.addDays(now, -3), hour: 23, minute: 59),
        ),
      );

      await tester.pumpWidget(wrap(HomeScreen(day: now)));
      await settle(tester);
      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      // The old code cancelled every alarm and never re-armed a recurring
      // task, so completing today silenced every day after it.
      expect(pendingAlarms.containsKey(id), isTrue);
      final DateTime first = DateTime.parse(
        pendingAlarms[id]!['scheduledDateTimeISO8601']! as String,
      );
      expect(
        DateTime(first.year, first.month, first.day),
        Task.addDays(now, 1),
        reason: "today's instance is done, so the first ring is tomorrow",
      );
    });

    testWidgets('upgrading moves the stored day into history', (
      WidgetTester tester,
    ) async {
      const String name = 'phase9_migration_v6.db';
      await onDb(tester, () async {
        await DatabaseService.instance.close();
        final String path =
            '${await databaseFactory.getDatabasesPath()}/$name';
        await databaseFactory.deleteDatabase(path);

        final Database v6 = await databaseFactory.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 6,
            onCreate: (Database db, int version) async {
              await db.execute(
                'CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'title TEXT NOT NULL, scheduled_time INTEGER NOT NULL, '
                "status TEXT NOT NULL DEFAULT 'pending', "
                'created_at INTEGER NOT NULL, note TEXT, '
                "recurrence_type TEXT NOT NULL DEFAULT 'none', "
                'repeat_days TEXT, status_date INTEGER)',
              );
            },
          ),
        );
        await v6.insert('tasks', <String, Object?>{
          'id': 1,
          'title': 'Stretch',
          'scheduled_time': DateTime(2026, 9, 7, 9).millisecondsSinceEpoch,
          'status': TaskStatus.completed,
          'created_at': DateTime(2026, 9, 7).millisecondsSinceEpoch,
          'note': 'early',
          'recurrence_type': RecurrenceType.daily,
          'status_date': kTuesday.millisecondsSinceEpoch,
        });
        await v6.close();
        DatabaseService.debugDatabaseName = name;
      });

      final Task tuesday = (await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kTuesday),
      ))
          .single;
      expect(tuesday.statusOn(kTuesday), TaskStatus.completed);
      expect(tuesday.noteOn(kTuesday), 'early');

      final Task? row =
          await onDb(tester, () => DatabaseService.instance.getTaskById(1));
      expect(row!.status, TaskStatus.pending);

      await onDb(tester, () async {
        await DatabaseService.instance.close();
        DatabaseService.debugDatabaseName = 'phase9_test.db';
      });
    });
  });

  // ================= 3. Deletion =================

  group('Deleting a task', () {
    testWidgets('it is gone from the database, the screen and the alarms', (
      WidgetTester tester,
    ) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(
          Task(title: 'Dentist', scheduledTime: DateTime(2026, 9, 9, 9)),
        ),
      );

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);
      await tester.drag(
        find.byKey(HomeScreen.dismissibleKey(id)),
        const Offset(-500, 0),
      );
      // The card leaves on the swipe itself, before any database work.
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsNothing);
      await settle(tester);

      expect(
        await onDb(tester, () => DatabaseService.instance.getTaskById(id)),
        isNull,
      );
      expect(cancelled, contains(id));

      await restart(tester, kWednesday);
      expect(find.text('Dentist'), findsNothing,
          reason: 'a deleted task must not come back on restart');
    });

    testWidgets('a plugin that throws on cancel cannot resurrect the task', (
      WidgetTester tester,
    ) async {
      cancelThrows = true;
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(
          Task(title: 'Dentist', scheduledTime: DateTime(2026, 9, 9, 9)),
        ),
      );

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);
      await tester.drag(
        find.byKey(HomeScreen.dismissibleKey(id)),
        const Offset(-500, 0),
      );
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(
        await onDb(tester, () => DatabaseService.instance.getTaskById(id)),
        isNull,
      );

      await restart(tester, kWednesday);
      expect(find.text('Dentist'), findsNothing);
    });

    testWidgets('deleting a recurring task removes its history too, and undo '
        'restores both', (WidgetTester tester) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );
      await onDb(
        tester,
        () => DatabaseService.instance.updateStatusWithNote(
            id, TaskStatus.completed, null,
            forDate: kMonday),
      );
      final Task task =
          (await onDb(tester, () => DatabaseService.instance.getTaskById(id)))!;
      final List<TaskCompletion> history = await onDb(
        tester,
        () => DatabaseService.instance.getCompletionsForTask(id),
      );

      final int removed =
          await onDb(tester, () => DatabaseService.instance.deleteTask(id));
      expect(removed, 1);
      expect(
        await onDb(
            tester, () => DatabaseService.instance.getCompletionsForTask(id)),
        isEmpty,
      );
      expect(
        await onDb(
            tester, () => DatabaseService.instance.getTasksForDate(kMonday)),
        isEmpty,
      );

      await onDb(
        tester,
        () => DatabaseService.instance
            .restoreTask(task, completions: history),
      );
      final Task monday = (await onDb(
        tester,
        () => DatabaseService.instance.getTasksForDate(kMonday),
      ))
          .single;
      expect(monday.id, id);
      expect(monday.statusOn(kMonday), TaskStatus.completed);
    });
  });

  // ================= 5. Alarm times =================

  group('Alarm scheduling', () {
    test('the next occurrence is strictly in the future', () {
      final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
      final DateTime past = DateTime.now().subtract(const Duration(minutes: 1));

      final tz.TZDateTime next = NotificationService.nextDailyOccurrence(past);
      expect(next.isAfter(now), isTrue);
      expect(next.hour, past.hour);
      expect(next.minute, past.minute);
    });

    test('notBefore pushes the first ring to that day', () {
      final DateTime inThreeDays = Task.addDays(DateTime.now(), 3);
      final tz.TZDateTime next = NotificationService.nextDailyOccurrence(
        DateTime(2026, 1, 1, 7, 30),
        notBefore: inThreeDays,
      );
      expect(
        DateTime(next.year, next.month, next.day),
        inThreeDays,
      );
      expect(next.hour, 7);
      expect(next.minute, 30);
    });

    test('a weekly occurrence lands on its weekday', () {
      for (int weekday = 1; weekday <= 7; weekday++) {
        expect(
          NotificationService.nextWeekdayOccurrence(
            DateTime(2026, 1, 1, 8),
            weekday,
          ).weekday,
          weekday,
        );
      }
    });

    test('a recurring task done today first rings tomorrow', () async {
      final NotificationService service =
          NotificationService.withPlugin(FlutterLocalNotificationsPlugin());
      await service.init();
      final DateTime today = Task.dayStart(DateTime.now());

      await service.scheduleForTask(
        daily('Stretch', from: DateTime(2026), hour: 23, minute: 59)
            .copyWith(id: 40, status: TaskStatus.completed, statusDate: today),
      );

      final DateTime first = DateTime.parse(
        pendingAlarms[40]!['scheduledDateTimeISO8601']! as String,
      );
      expect(
        DateTime(first.year, first.month, first.day),
        Task.addDays(today, 1),
      );
    });

    test('a recurring task never rings before its start date', () async {
      final NotificationService service =
          NotificationService.withPlugin(FlutterLocalNotificationsPlugin());
      await service.init();
      final DateTime start = Task.addDays(DateTime.now(), 5);

      await service.scheduleForTask(
        daily('Later', from: start).copyWith(id: 41),
      );

      final DateTime first = DateTime.parse(
        pendingAlarms[41]!['scheduledDateTimeISO8601']! as String,
      );
      expect(DateTime(first.year, first.month, first.day), start);
    });
  });

  // ================= 4. Report completeness =================

  group('Truncated replies', () {
    final AiCredentials credentials = AiCredentials(
      apiKey: 'key',
      baseUrl: 'https://api.example.com/v1',
      model: 'model',
    );

    http.Response reply(String content, String finishReason) => http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'finish_reason': finishReason,
                'message': <String, String>{
                  'role': 'assistant',
                  'content': content,
                },
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );

    test('a reply cut at the ceiling is continued and joined', () async {
      final List<Map<String, Object?>> bodies = <Map<String, Object?>>[];
      final List<http.Response> replies = <http.Response>[
        reply('### Summary\nYou finished two of', 'length'),
        reply('five tasks.\n\n### Next\nDo the rest.', 'stop'),
      ];
      final AiService ai = AiService(
        client: MockClient((http.Request request) async {
          bodies.add(jsonDecode(request.body) as Map<String, Object?>);
          return replies.removeAt(0);
        }),
      );

      final String text = await ai.complete(
        const <AiMessage>[AiMessage.user('debrief')],
        credentials: credentials,
        maxTokens: AiService.debriefMaxTokens,
        continueIfTruncated: true,
      );

      expect(text,
          '### Summary\nYou finished two of five tasks.\n\n### Next\nDo the rest.');
      expect(bodies, hasLength(2));

      final List<Object?> second = bodies[1]['messages']! as List<Object?>;
      expect((second[1]! as Map<String, Object?>)['role'], 'assistant');
      expect(
        (second.last! as Map<String, Object?>)['content'],
        AiService.continuationPrompt,
      );
      for (final Map<String, Object?> body in bodies) {
        expect(body.containsKey('stop'), isFalse);
        expect(body['max_tokens'], AiService.debriefMaxTokens);
      }
    });

    test('continuation is bounded', () async {
      int calls = 0;
      final AiService ai = AiService(
        client: MockClient((http.Request request) async {
          calls++;
          return reply('more', 'length');
        }),
      );

      await ai.complete(
        const <AiMessage>[AiMessage.user('debrief')],
        credentials: credentials,
        continueIfTruncated: true,
      );
      expect(calls, 1 + AiService.maxContinuations);
    });

    test('without opting in, a truncated reply is a single request', () async {
      int calls = 0;
      final AiService ai = AiService(
        client: MockClient((http.Request request) async {
          calls++;
          return reply('cut', 'length');
        }),
      );

      expect(
        await ai.complete(
          const <AiMessage>[AiMessage.user('hi')],
          credentials: credentials,
        ),
        'cut',
      );
      expect(calls, 1);
    });

    test('a continuation starting a heading gets its line break back', () {
      expect(AiService.joinContinuation('a', '### B'), 'a\n\n### B');
      expect(AiService.joinContinuation('two of', 'five'), 'two of five');
    });
  });

  // ================= Follow-up: date sync, double taps, 503s =================

  group('Today stays the real today', () {
    Material chipMaterial(WidgetTester tester, Key key) =>
        tester.widget<Material>(
          find
              .ancestor(of: find.byKey(key), matching: find.byType(Material))
              .first,
        );

    testWidgets('browsing another day does not make the add sheet call it '
        'today', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      await tester.tap(find.byKey(HomeScreen.previousDayKey));
      await settle(tester);
      await tester.tap(find.byKey(HomeScreen.addTaskKey));
      await settle(tester);

      // Tuesday is on screen, but "Today" still means Wednesday — so the
      // form starts on Tuesday as a custom date, with neither chip lit.
      expect(
        chipMaterial(tester, AddTaskSheet.todayChipKey).color,
        isNot(AppColors.primary),
      );
      expect(
        chipMaterial(tester, AddTaskSheet.tomorrowChipKey).color,
        isNot(AppColors.primary),
      );
      expect(
        chipMaterial(tester, AddTaskSheet.dateButtonKey).color,
        AppColors.primary,
      );
    });

    testWidgets('the add sheet opened on today marks today', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);
      await tester.tap(find.byKey(HomeScreen.addTaskKey));
      await settle(tester);

      expect(
        chipMaterial(tester, AddTaskSheet.todayChipKey).color,
        AppColors.primary,
      );
    });
  });

  group('Checkmark double taps', () {
    testWidgets('a fast double tap on the checkmark leaves it checked', (
      WidgetTester tester,
    ) async {
      final int id = await onDb(
        tester,
        () => DatabaseService.instance.insertTask(daily('Stretch')),
      );

      await tester.pumpWidget(wrap(HomeScreen(day: kWednesday)));
      await settle(tester);

      // Two taps before the first write has landed. The second used to read
      // as "tap the active status again" and undo the first.
      await tester.tap(find.byKey(TaskCard.completeKey));
      await tester.pump();
      await tester.tap(find.byKey(TaskCard.completeKey));
      await settle(tester);

      expect(find.text(AppStrings.en.statusDone), findsOneWidget);
      final Task stored = (await onDb(
        tester,
        () => DatabaseService.instance.getTaskOnDate(id, kWednesday),
      ))!;
      expect(stored.statusOn(kWednesday), TaskStatus.completed);

      await restart(tester, kWednesday);
      expect(isStruckThrough(tester, 'Stretch'), isTrue);
    });
  });

  group('Transient AI failures', () {
    final AiCredentials credentials = AiCredentials(
      apiKey: 'key',
      baseUrl: 'https://api.example.com/v1',
      model: 'model',
    );

    http.Response ok(String content) => http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'finish_reason': 'stop',
                'message': <String, String>{'content': content},
              },
            ],
          }),
          200,
        );

    http.Response overloaded() => http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 503,
              'message': 'The model is overloaded.',
              'status': 'UNAVAILABLE',
            },
          }),
          503,
        );

    Duration noWait(int _) => Duration.zero;

    test('a 503 is retried and the report still arrives', () async {
      final List<http.Response> replies = <http.Response>[
        overloaded(),
        overloaded(),
        ok('### Summary\nDone.'),
      ];
      int calls = 0;
      final AiService ai = AiService(
        retryBackoff: noWait,
        client: MockClient((http.Request request) async {
          calls++;
          return replies.removeAt(0);
        }),
      );

      expect(
        await ai.complete(
          const <AiMessage>[AiMessage.user('debrief')],
          credentials: credentials,
        ),
        '### Summary\nDone.',
      );
      expect(calls, 3);
    });

    test('a 503 that never clears gives up as unavailable', () async {
      int calls = 0;
      final AiService ai = AiService(
        retryBackoff: noWait,
        client: MockClient((http.Request request) async {
          calls++;
          return overloaded();
        }),
      );

      await expectLater(
        ai.complete(
          const <AiMessage>[AiMessage.user('debrief')],
          credentials: credentials,
        ),
        throwsA(
          isA<AiException>()
              .having((AiException e) => e.kind, 'kind', AiFailure.unavailable)
              .having((AiException e) => e.statusCode, 'status', 503),
        ),
      );
      expect(calls, 1 + AiService.maxRetries);
    });

    test('the backoff waits longer each time', () {
      expect(AiService.defaultRetryBackoff(1), const Duration(seconds: 2));
      expect(AiService.defaultRetryBackoff(2), const Duration(seconds: 4));
    });

    test('a client error is not retried', () async {
      int calls = 0;
      final AiService ai = AiService(
        retryBackoff: noWait,
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response('{"error":{"message":"bad"}}', 400);
        }),
      );

      await expectLater(
        ai.complete(
          const <AiMessage>[AiMessage.user('x')],
          credentials: credentials,
        ),
        throwsA(isA<AiException>()),
      );
      expect(calls, 1);
    });

    test('the settings connection test does not retry', () async {
      int calls = 0;
      final AiService ai = AiService(
        retryBackoff: noWait,
        client: MockClient((http.Request request) async {
          calls++;
          return overloaded();
        }),
      );

      await expectLater(
        ai.testConnection(credentials: credentials),
        throwsA(isA<AiException>()),
      );
      expect(calls, 1);
    });

    test('every failure kind has a message in every language', () {
      for (final AppStrings strings in <AppStrings>[
        AppStrings.en,
        AppStrings.ar,
        AppStrings.fr,
      ]) {
        for (final AiFailure kind in AiFailure.values) {
          final String text = strings.aiFailure(kind);
          expect(text, isNotEmpty);
          expect(text, isNot(contains('{')));
        }
      }
      expect(
        AppStrings.ar.aiFailure(AiFailure.unavailable),
        contains('مشغولة'),
      );
    });

    testWidgets('the report shows a friendly Arabic message, not JSON', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'api_key': 'sk-test',
        'base_url': 'https://api.example.com/v1',
        'model_name': 'test-model',
      });
      SharedPreferences.resetStatic();
      SettingsService.instance.resetCacheForTesting();
      // Generate is only offered for a range that has something in it.
      await onDb(
        tester,
        () => DatabaseService.instance.insertTask(Task(
          title: 'Done',
          scheduledTime: DateTime(2026, 9, 9, 9),
          status: TaskStatus.completed,
        )),
      );

      await tester.pumpWidget(wrap(
        ReportScreen(
          now: DateTime(2026, 9, 9, 18),
          client: MockClient((http.Request request) async {
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': <String, Object?>{
                  'code': 401,
                  'message': 'API key not valid.',
                  'status': 'INVALID_ARGUMENT',
                },
              }),
              401,
            );
          }),
        ),
        language: 'ar',
      ));
      await settle(tester);

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      expect(
        find.text(AppStrings.ar.aiFailure(AiFailure.unauthorized)),
        findsOneWidget,
      );
      expect(find.textContaining('INVALID_ARGUMENT'), findsNothing);
      expect(find.textContaining('API key not valid'), findsNothing);
    });
  });
}
