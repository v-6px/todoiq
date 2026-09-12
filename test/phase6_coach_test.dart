import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/models/chat_message_model.dart';
import 'package:todo_list/models/task_action.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/chat_coach_screen.dart';
import 'package:todo_list/screens/settings_screen.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/notification_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';

final DateTime kDay = DateTime(2026, 9, 9, 18, 30);

const MethodChannel _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;

  /// Alarms the fake OS is holding, so a confirmed task can be checked for
  /// having actually been armed and not just written to SQLite.
  final Map<int, Map<Object?, Object?>> alarms =
      <int, Map<Object?, Object?>>{};

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.debugDatabaseName = 'phase6_test.db';

    // main() does this before the first frame; DateFormat with an explicit
    // locale throws without it.
    initializeDateFormatting();

    // Confirming a proposed task arms a real alarm, which needs a timezone.
    NotificationService.configureLocalTimeZone();
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  void useStoredSettings([
    Map<String, Object> values = const <String, Object>{
      'api_key': 'sk-test',
      'base_url': 'https://api.example.com/v1',
      'model_name': 'test-model',
    },
  ]) {
    SharedPreferences.setMockInitialValues(values);
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();
  }

  setUp(() async {
    requests = <http.Request>[];
    alarms.clear();
    useStoredSettings();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationChannel,
            (MethodCall call) async {
      switch (call.method) {
        case 'zonedSchedule':
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          alarms[args['id']! as int] = args;
          return null;
        case 'cancel':
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          alarms.remove(args['id']);
          return null;
        default:
          return null;
      }
    });

    final Database database = await DatabaseService.instance.database;
    await database.delete(DatabaseService.tasksTable);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationChannel, null);
  });

  MockClient replyWith(String content) {
    return MockClient((http.Request request) async {
      requests.add(request);
      // Encoded explicitly: http.Response falls back to latin-1, which
      // cannot even hold an em dash, let alone Arabic.
      return http.Response.bytes(
        utf8.encode(jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, String>{'content': content},
            },
          ],
        })),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
  }

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

  Future<void> seed(
    WidgetTester tester,
    String title,
    int hour,
    String status, {
    String? note,
  }) {
    return onDb(
      tester,
      () => DatabaseService.instance.insertTask(
        Task(
          title: title,
          scheduledTime: DateTime(2026, 9, 9, hour),
          status: status,
          note: note,
        ),
      ),
    );
  }

  Future<void> pumpCoach(
    WidgetTester tester, {
    http.Client? client,
    String language = 'en',
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.forLocale(Locale(language)),
      locale: Locale(language),
      supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: ChatCoachScreen(
        day: kDay,
        client: client ?? replyWith('Sure.'),
      ),
    ));
    await settle(tester);
  }

  Future<void> ask(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(ChatCoachScreen.inputKey), text);
    await tester.tap(find.byKey(ChatCoachScreen.sendKey));
    await settle(tester);
  }

  /// The system turn from the most recent request.
  String systemTurn() {
    final Map<String, Object?> body =
        jsonDecode(requests.last.body) as Map<String, Object?>;
    final List<Object?> messages = body['messages']! as List<Object?>;
    return (messages.first as Map<Object?, Object?>)['content']! as String;
  }

  // ---- Model ------------------------------------------------------------

  group('ChatMessage', () {
    test('named constructors set their role', () {
      expect(ChatMessage.user('hi').role, ChatRole.user);
      expect(ChatMessage.assistant('yo').role, ChatRole.assistant);
      expect(ChatMessage.system('ctx').role, ChatRole.system);
      expect(ChatMessage.user('hi').isUser, isTrue);
      expect(ChatMessage.assistant('yo').isAssistant, isTrue);
    });

    test('pending and error turns are never sent to the model', () {
      expect(ChatMessage.user('real').isSendable, isTrue);
      expect(
        ChatMessage.assistant('', isPending: true).isSendable,
        isFalse,
      );
      expect(
        ChatMessage.assistant('failed', isError: true).isSendable,
        isFalse,
      );
    });

    test('copyWith keeps the role and timestamp', () {
      final ChatMessage pending =
          ChatMessage.assistant('', isPending: true);
      final ChatMessage settled =
          pending.copyWith(content: 'done', isPending: false);

      expect(settled.role, ChatRole.assistant);
      expect(settled.timestamp, pending.timestamp);
      expect(settled.content, 'done');
      expect(settled.isPending, isFalse);
    });

    test('serialises to the wire shape', () {
      expect(
        ChatMessage.user('hello').toJson(),
        <String, String>{'role': 'user', 'content': 'hello'},
      );
    });
  });

  // ---- System prompt ----------------------------------------------------

  group('System prompt', () {
    test('lists every task with its status', () {
      final String prompt = ChatCoachScreen.buildSystemPrompt(
        <Task>[
          Task(
            title: 'Write spec',
            scheduledTime: DateTime(2026, 9, 9, 9),
            status: TaskStatus.completed,
          ),
          Task(
            title: 'Refactor parser',
            scheduledTime: DateTime(2026, 9, 9, 14),
            status: TaskStatus.partial,
          ),
          Task(
            title: 'Gym',
            scheduledTime: DateTime(2026, 9, 9, 18),
            status: TaskStatus.skipped,
          ),
          Task(title: 'Email', scheduledTime: DateTime(2026, 9, 9, 20)),
        ],
        kDay,
      );

      expect(prompt, contains('"Write spec" at 09:00 — completed'));
      expect(
        prompt,
        contains('"Refactor parser" at 14:00 — partially done, not finished'),
      );
      expect(prompt, contains('"Gym" at 18:00 — skipped'));
      expect(prompt, contains('"Email" at 20:00 — still pending'));
    });

    test('quotes the note as the reason', () {
      final String prompt = ChatCoachScreen.buildSystemPrompt(
        <Task>[
          Task(
            title: 'Refactor parser',
            scheduledTime: DateTime(2026, 9, 9, 14),
            status: TaskStatus.partial,
            note: 'blocked waiting on review',
          ),
        ],
        kDay,
      );

      expect(prompt, contains('their reason: "blocked waiting on review"'));
    });

    test('omits the reason clause when there is no note', () {
      final String prompt = ChatCoachScreen.buildSystemPrompt(
        <Task>[
          Task(
            title: 'Gym',
            scheduledTime: DateTime(2026, 9, 9, 18),
            status: TaskStatus.skipped,
          ),
        ],
        kDay,
      );
      expect(prompt, isNot(contains('their reason')));
    });

    test('says so when the day is empty', () {
      final String prompt =
          ChatCoachScreen.buildSystemPrompt(<Task>[], kDay);
      expect(prompt, contains('(no tasks scheduled)'));
    });

    test('names the day and forbids inventing tasks', () {
      final String prompt =
          ChatCoachScreen.buildSystemPrompt(<Task>[], kDay);
      expect(prompt, contains('Wednesday 9 September'));
      expect(prompt, contains('Never invent tasks'));
    });
  });

  // ---- Screen -----------------------------------------------------------

  group('Coach screen', () {
    testWidgets('opens on an empty conversation with a composer', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester);

      expect(find.byKey(ChatCoachScreen.inputKey), findsOneWidget);
      expect(find.byKey(ChatCoachScreen.sendKey), findsOneWidget);
      expect(find.textContaining('Your coach has today'), findsOneWidget);
      expect(requests, isEmpty, reason: 'no call before the user speaks');
    });

    testWidgets('sends the task log as the system turn', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Refactor parser', 14, TaskStatus.partial,
          note: 'ran out of time');
      await pumpCoach(tester, client: replyWith('Let us look at that.'));

      await ask(tester, 'Why did today stall?');

      expect(requests, hasLength(1));
      final String system = systemTurn();
      expect(system, contains('"Refactor parser"'));
      expect(system, contains('partially done, not finished'));
      expect(system, contains('their reason: "ran out of time"'));
    });

    testWidgets('renders the exchange as bubbles', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester, client: replyWith('**Start** with the parser.'));

      await ask(tester, 'What first?');

      expect(find.text('What first?'), findsOneWidget);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.textContaining('with the parser'), findsWidgets);
      expect(find.byKey(ChatCoachScreen.listKey), findsOneWidget);
    });

    testWidgets('clears the input after sending', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester);
      await ask(tester, 'Hello');

      final TextField input =
          tester.widget<TextField>(find.byKey(ChatCoachScreen.inputKey));
      expect(input.controller!.text, isEmpty);
    });

    testWidgets('ignores an empty or whitespace-only message', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester);

      await tester.tap(find.byKey(ChatCoachScreen.sendKey));
      await settle(tester);
      expect(requests, isEmpty);

      await ask(tester, '   ');
      expect(requests, isEmpty);
    });

    testWidgets('carries the earlier turns into the next request', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester, client: replyWith('First answer.'));

      await ask(tester, 'Question one');
      await ask(tester, 'Question two');

      expect(requests, hasLength(2));
      final Map<String, Object?> body =
          jsonDecode(requests.last.body) as Map<String, Object?>;
      final List<Object?> messages = body['messages']! as List<Object?>;

      // system + user1 + assistant1 + user2
      expect(messages, hasLength(4));
      final List<String> roles = messages
          .map((Object? m) => (m! as Map<Object?, Object?>)['role']! as String)
          .toList();
      expect(roles, <String>['system', 'user', 'assistant', 'user']);
      expect(
        (messages[3] as Map<Object?, Object?>)['content'],
        'Question two',
      );
    });

    testWidgets('a failed turn is shown but never resent', (
      WidgetTester tester,
    ) async {
      bool first = true;
      await pumpCoach(
        tester,
        client: MockClient((http.Request request) async {
          requests.add(request);
          if (first) {
            first = false;
            return http.Response('{"error":{"message":"Bad key"}}', 401);
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, String>{'content': 'Recovered.'},
                },
              ],
            }),
            200,
          );
        }),
      );

      await ask(tester, 'First try');
      expect(find.textContaining('API key was rejected'), findsOneWidget);
      expect(find.textContaining('Bad key'), findsOneWidget);

      await ask(tester, 'Second try');

      final Map<String, Object?> body =
          jsonDecode(requests.last.body) as Map<String, Object?>;
      final List<Object?> messages = body['messages']! as List<Object?>;
      final List<String> roles = messages
          .map((Object? m) => (m! as Map<Object?, Object?>)['role']! as String)
          .toList();

      // The error bubble must not travel as an assistant turn.
      expect(roles, <String>['system', 'user', 'user']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a network failure is caught, not thrown', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        client: MockClient((http.Request request) async {
          throw Exception('offline');
        }),
      );

      await ask(tester, 'Anything there?');

      expect(
        find.textContaining('Could not reach the endpoint'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('missing credentials offer a Settings shortcut', (
      WidgetTester tester,
    ) async {
      useStoredSettings(<String, Object>{});
      await pumpCoach(tester);

      await ask(tester, 'Coach me');

      expect(requests, isEmpty, reason: 'never call without a key');
      expect(find.textContaining('Add an API key in Settings'), findsOneWidget);

      await tester.tap(find.byKey(ChatCoachScreen.settingsShortcutKey));
      await settle(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('uses the stored endpoint and credentials', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester);
      await ask(tester, 'Hi');

      expect(
        requests.single.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(requests.single.headers['Authorization'], 'Bearer sk-test');
    });
  });

  // ---- Scheduling from chat ---------------------------------------------

  String withAction(String prose, String json) =>
      '$prose\n\n```task_action\n$json\n```';

  group('CoachReply parsing', () {
    test('splits the prose from the action block', () {
      final CoachReply reply = CoachReply.parse(
        withAction(
          'Sounds good — I have drafted it.',
          '{"title": "Review notes", "date": "2026-09-10", "time": "07:30", '
              '"recurrence": "none"}',
        ),
        now: kDay,
      );

      expect(reply.text, 'Sounds good — I have drafted it.');
      expect(reply.text, isNot(contains('task_action')));
      expect(reply.hasAction, isTrue);
      expect(reply.action!.title, 'Review notes');
      expect(reply.action!.scheduledTime, DateTime(2026, 9, 10, 7, 30));
      expect(reply.action!.recurrenceType, RecurrenceType.none);
      expect(reply.action!.repeatDays, isNull);
    });

    test('maps "weekly" plus days onto the recurrence model', () {
      final CoachReply reply = CoachReply.parse(
        withAction(
          'Every Monday and Wednesday then.',
          '{"title": "Gym", "date": "2026-09-14", "time": "18:00", '
              '"recurrence": "weekly", "days": [3, 1, 1]}',
        ),
        now: kDay,
      );

      expect(reply.action!.recurrenceType, RecurrenceType.weeklyDays);
      expect(reply.action!.repeatDays, <int>[1, 3]);
      expect(reply.action!.toTask().repeatDays, <int>[1, 3]);
    });

    test('a daily block carries no weekday list', () {
      final CoachReply reply = CoachReply.parse(
        withAction(
          'Daily it is.',
          '{"title": "Stretch", "date": "2026-09-10", "time": "06:00", '
              '"recurrence": "daily"}',
        ),
        now: kDay,
      );

      expect(reply.action!.recurrenceType, RecurrenceType.daily);
      expect(reply.action!.toTask().repeatDays, isNull);
    });

    test('an ordinary reply is left exactly as written', () {
      const String prose = 'You skipped the gym twice. What got in the way?';
      final CoachReply reply = CoachReply.parse(prose, now: kDay);

      expect(reply.text, prose);
      expect(reply.hasAction, isFalse);
    });

    test('a malformed block is still hidden from the user', () {
      final CoachReply reply = CoachReply.parse(
        withAction('Here you go.', '{"title": "Broken", "date":'),
        now: kDay,
      );

      expect(reply.text, 'Here you go.');
      expect(reply.hasAction, isFalse, reason: 'nothing safe to insert');
    });

    test('a block the provider truncated mid-write is stripped too', () {
      final CoachReply reply = CoachReply.parse(
        'On it.\n\n```task_action\n{"title": "Call the bank", '
        '"date": "2026-09-11", "time": "10:00"}',
        now: kDay,
      );

      expect(reply.text, 'On it.');
      expect(reply.action!.title, 'Call the bank');
    });

    test('a reply that is nothing but a block leaves no raw JSON behind', () {
      final CoachReply reply = CoachReply.parse(
        '```task_action\n{"title": "Only this", "date": "2026-09-10", '
        '"time": "08:00"}\n```',
        now: kDay,
      );

      expect(reply.text, isEmpty);
      expect(reply.action!.title, 'Only this');
    });

    test('missing or nonsense fields fall back rather than fail', () {
      final CoachReply reply = CoachReply.parse(
        withAction('Sure.', '{"title": "Vague", "time": "99:99"}'),
        now: kDay,
      );

      // No date means the day being coached; an impossible clock means 09:00.
      expect(reply.action!.scheduledTime, DateTime(2026, 9, 9, 9, 0));
    });

    test('a weekly block with no days is anchored to its own weekday', () {
      final CoachReply reply = CoachReply.parse(
        withAction(
          'Weekly.',
          '{"title": "Plan", "date": "2026-09-10", "time": "09:00", '
              '"recurrence": "weekly"}',
        ),
        now: kDay,
      );

      // 2026-09-10 is a Thursday.
      expect(reply.action!.repeatDays, <int>[4]);
    });

    test('a titleless block is dropped', () {
      final CoachReply reply = CoachReply.parse(
        withAction('Hmm.', '{"title": "   ", "date": "2026-09-10"}'),
        now: kDay,
      );

      expect(reply.hasAction, isFalse);
    });
  });

  group('Coach scheduling', () {
    testWidgets('the system prompt teaches the block format and today', (
      WidgetTester tester,
    ) async {
      await pumpCoach(tester);
      await ask(tester, 'Hi');

      final String prompt = systemTurn();
      expect(prompt, contains('```task_action'));
      expect(prompt, contains('"recurrence": "none|daily|weekly"'));
      expect(prompt, contains('Today is 2026-09-09'));
    });

    testWidgets('a proposed task is offered as a card, not as raw JSON', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        client: replyWith(withAction(
          'Good idea — want me to add it?',
          '{"title": "Deep work", "date": "2026-09-10", "time": "09:00", '
              '"recurrence": "none"}',
        )),
      );
      await ask(tester, 'Schedule deep work tomorrow at 9');

      expect(find.byKey(ChatCoachScreen.taskActionKey(1)), findsOneWidget);
      expect(find.text('Deep work'), findsOneWidget);
      expect(
        find.textContaining('Add Task to Schedule'),
        findsOneWidget,
      );

      // The prose survives; the block never reaches the renderer.
      final MarkdownBody rendered =
          tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(rendered.data, 'Good idea — want me to add it?');
    });

    testWidgets('an ordinary reply gets no card', (WidgetTester tester) async {
      await pumpCoach(tester, client: replyWith('Just rest tonight.'));
      await ask(tester, 'What now?');

      expect(find.byKey(ChatCoachScreen.taskActionKey(1)), findsNothing);
    });

    testWidgets('tapping the card writes the task and arms its alarm', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        client: replyWith(withAction(
          'Added below.',
          '{"title": "Gym", "date": "2036-09-14", "time": "18:00", '
              '"recurrence": "weekly", "days": [1, 3]}',
        )),
      );
      await ask(tester, 'Put the gym in for Mondays and Wednesdays');

      await tester.tap(find.byKey(ChatCoachScreen.taskActionAddKey(1)));
      await settle(tester);

      final List<Task> stored = await onDb(
        tester,
        () => DatabaseService.instance.getTasksBetween(
          DateTime(2036, 9, 1),
          DateTime(2036, 10, 1),
        ),
      );

      expect(stored, hasLength(1));
      expect(stored.single.title, 'Gym');
      expect(stored.single.scheduledTime, DateTime(2036, 9, 14, 18, 0));
      expect(stored.single.recurrenceType, RecurrenceType.weeklyDays);
      expect(stored.single.repeatDays, <int>[1, 3]);

      // One alarm per selected weekday, so the repeat actually fires.
      expect(alarms, hasLength(2));

      expect(find.text('Task added to your schedule.'), findsWidgets);
    });

    testWidgets('a confirmed card cannot be tapped into a second task', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        client: replyWith(withAction(
          'Done.',
          '{"title": "Call mum", "date": "2036-09-11", "time": "19:00"}',
        )),
      );
      await ask(tester, 'Remind me to call mum');

      for (int i = 0; i < 3; i++) {
        final Finder button = find.byKey(ChatCoachScreen.taskActionAddKey(1));
        if (tester.any(button)) {
          await tester.tap(button, warnIfMissed: false);
          await settle(tester);
        }
      }

      final List<Task> stored = await onDb(
        tester,
        () => DatabaseService.instance.getTasksBetween(
          DateTime(2036, 9, 1),
          DateTime(2036, 10, 1),
        ),
      );
      expect(stored, hasLength(1), reason: 'confirming is one-shot');
    });

    testWidgets('a reply that is only an unreadable block is not blank', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        client: replyWith(withAction('', '{"title": ')),
      );
      await ask(tester, 'Schedule something');

      expect(find.byKey(ChatCoachScreen.taskActionKey(1)), findsNothing);
      expect(find.textContaining('task_action'), findsNothing);
      expect(find.text('Something went wrong. Try again.'), findsOneWidget);
    });

    testWidgets('the next turn sends the stripped reply, not the JSON', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        client: replyWith(withAction(
          'Noted.',
          '{"title": "Read", "date": "2026-09-10", "time": "21:00"}',
        )),
      );
      await ask(tester, 'Add reading at nine');
      await ask(tester, 'Thanks');

      final Map<String, Object?> body =
          jsonDecode(requests.last.body) as Map<String, Object?>;
      final List<String> history = (body['messages']! as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .where((Map<Object?, Object?> m) => m['role'] == 'assistant')
          .map((Map<Object?, Object?> m) => m['content']! as String)
          .toList();

      expect(history, <String>['Noted.']);
    });

    testWidgets('the Arabic card keeps the ASCII JSON contract', (
      WidgetTester tester,
    ) async {
      await pumpCoach(
        tester,
        language: 'ar',
        client: replyWith(withAction(
          'تمام.',
          '{"title": "قراءة", "date": "2036-09-10", "time": "21:00"}',
        )),
      );
      await ask(tester, 'أضف القراءة');

      expect(find.byKey(ChatCoachScreen.taskActionKey(1)), findsOneWidget);
      expect(find.text('قراءة'), findsOneWidget);
      expect(find.textContaining('إضافة المهمة إلى الجدول'), findsOneWidget);
      expect(systemTurn(), contains('```task_action'));
    });
  });
}
