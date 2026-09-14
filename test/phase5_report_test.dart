import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/l10n/app_strings.dart';
import 'package:todo_list/l10n/bidi_text.dart';
import 'package:todo_list/models/report_range.dart';
import 'package:todo_list/models/saved_report.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/report_screen.dart';
import 'package:todo_list/screens/settings_screen.dart';
import 'package:todo_list/services/ai_service.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/debrief_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';
import 'package:todo_list/widgets/stat_chip.dart';

/// A Wednesday, so week-start maths is unambiguous.
final DateTime kNow = DateTime(2026, 9, 9, 18, 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Test files run in parallel isolates; sharing one SQLite file across
    // them deadlocks.
    DatabaseService.debugDatabaseName = 'phase5_test.db';

    // main() does this before the first frame; DateFormat with an explicit
    // locale throws without it.
    initializeDateFormatting();
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
    useStoredSettings();

    final Database database = await DatabaseService.instance.database;
    await database.delete(DatabaseService.tasksTable);
    await database.delete(DatabaseService.reportsTable);
  });

  MockClient replyWith(String content, {int status = 200}) {
    return MockClient((http.Request request) async {
      requests.add(request);
      return http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, String>{
                'role': 'assistant',
                'content': content,
              },
            },
          ],
        }),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
  }

  MockClient failWith(int status, String body) {
    return MockClient((http.Request request) async {
      requests.add(request);
      return http.Response(body, status);
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

  Future<int> seed(
    WidgetTester tester,
    String title,
    DateTime when,
    String status,
  ) {
    return onDb(
      tester,
      () => DatabaseService.instance.insertTask(
        Task(title: title, scheduledTime: when, status: status),
      ),
    );
  }

  Future<void> pumpReport(
    WidgetTester tester, {
    http.Client? client,
    String language = 'en',
  }) async {
    await tester.pumpWidget(MaterialApp(
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
      home: ReportScreen(now: kNow, client: client ?? replyWith('## Summary')),
    ));
    await settle(tester);
  }

  // ---- Pure aggregation -------------------------------------------------

  group('ReportRange', () {
    test('today spans exactly one day ending tonight', () {
      expect(ReportRange.today.start(kNow), DateTime(2026, 9, 9));
      expect(ReportRange.today.end(kNow), DateTime(2026, 9, 10));
      expect(ReportRange.today.dayCount(kNow), 1);
    });

    test('last 3 days is today plus the two before it', () {
      expect(ReportRange.lastThreeDays.start(kNow), DateTime(2026, 9, 7));
      expect(ReportRange.lastThreeDays.end(kNow), DateTime(2026, 9, 10));
      expect(ReportRange.lastThreeDays.dayCount(kNow), 3);
    });

    test('this week starts on Monday', () {
      // 9 Sept 2026 is a Wednesday, so Monday is the 7th.
      expect(kNow.weekday, DateTime.wednesday);
      expect(ReportRange.thisWeek.start(kNow), DateTime(2026, 9, 7));
      expect(ReportRange.thisWeek.dayCount(kNow), 3);
    });

    test('a Monday week starts on that same day', () {
      final DateTime monday = DateTime(2026, 9, 7, 10);
      expect(monday.weekday, DateTime.monday);
      expect(ReportRange.thisWeek.start(monday), DateTime(2026, 9, 7));
      expect(ReportRange.thisWeek.dayCount(monday), 1);
    });

    test('a Sunday week still starts on the preceding Monday', () {
      final DateTime sunday = DateTime(2026, 9, 13, 10);
      expect(sunday.weekday, DateTime.sunday);
      expect(ReportRange.thisWeek.start(sunday), DateTime(2026, 9, 7));
      expect(ReportRange.thisWeek.dayCount(sunday), 7);
    });

    test('no range reaches beyond the end of today', () {
      for (final ReportRange range in ReportRange.values) {
        expect(range.end(kNow), DateTime(2026, 9, 10), reason: range.name);
      }
    });
  });

  group('ReportSummary', () {
    test('reads every status out of the counts map', () {
      final ReportSummary summary = ReportSummary.fromCounts(<String, int>{
        TaskStatus.completed: 4,
        TaskStatus.partial: 2,
        TaskStatus.skipped: 1,
        TaskStatus.pending: 3,
      });

      expect(summary.completed, 4);
      expect(summary.partial, 2);
      expect(summary.skipped, 1);
      expect(summary.pending, 3);
      expect(summary.total, 10);
      expect(summary.resolved, 7);
      expect(summary.isEmpty, isFalse);
    });

    test('missing keys count as zero', () {
      final ReportSummary summary =
          ReportSummary.fromCounts(<String, int>{TaskStatus.completed: 1});
      expect(summary.partial, 0);
      expect(summary.skipped, 0);
      expect(summary.total, 1);
    });

    test('an all-zero summary is empty', () {
      expect(const ReportSummary().isEmpty, isTrue);
      expect(const ReportSummary().completionRate, isNull);
    });

    test('completion rate is a share of resolved, not of total', () {
      // 3 of 4 resolved were completed; the 10 pending must not dilute it.
      const ReportSummary summary = ReportSummary(
        completed: 3,
        partial: 1,
        pending: 10,
      );
      expect(summary.completionRate, 75);
    });
  });

  group('Debrief prompt', () {
    List<Task> sample() => <Task>[
          Task(
            title: 'Write the spec',
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
          Task(
            title: 'Email review',
            scheduledTime: DateTime(2026, 9, 9, 20),
          ),
        ];

    test('groups tasks under their status with titles and times', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        sample(),
        kNow,
      );

      expect(prompt, contains('COMPLETED'));
      expect(prompt, contains('"Write the spec"'));
      expect(prompt, contains('PARTIAL'));
      expect(prompt, contains('"Refactor parser"'));
      expect(prompt, contains('SKIPPED'));
      expect(prompt, contains('"Gym"'));
      expect(prompt, contains('STILL PENDING'));
      expect(prompt, contains('"Email review"'));
      expect(prompt, contains('14:00'));
    });

    test('asks for the three sections, in order, with their marks', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        sample(),
        kNow,
      );

      final int summary =
          prompt.indexOf('### ${DebriefService.summaryMark}');
      final int obstacles =
          prompt.indexOf('### ${DebriefService.obstaclesMark}');
      final int plan = prompt.indexOf('### ${DebriefService.planMark}');

      expect(summary, greaterThan(-1));
      expect(obstacles, greaterThan(summary), reason: 'order is part of it');
      expect(plan, greaterThan(obstacles));

      expect(prompt, contains(AppStrings.en.reportHeadingSummary));
      expect(prompt, contains(AppStrings.en.reportHeadingBottlenecks));
      expect(prompt, contains(AppStrings.en.reportHeadingNextSteps));
      expect(prompt, contains('PARTIAL tasks specifically'));
    });

    test('demands analysis rather than encouragement', () {
      // The point of the rewrite: a debrief that opens with praise is worth
      // nothing to somebody looking at three skipped tasks.
      final String system = DebriefService.systemPrompt(AppStrings.en);

      expect(system, contains('high-accountability'));
      expect(system, contains('analytical, direct and unsentimental'));
      expect(system, contains('do not open with praise'));
      expect(system, contains('No greetings, no encouragement'));

      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        sample(),
        kNow,
      );
      expect(prompt, contains('No compliments, no hedging'));
      expect(prompt, contains('No general advice, no motivational'));
    });

    test('hands the model the totals and the date, not just the log', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        sample(),
        kNow,
      );

      expect(prompt, contains('Today is 2026-09-09.'));
      expect(prompt, contains('Totals: '));
    });

    test('insists on a finished debrief rather than a truncated one', () {
      // Running out of room is the failure users actually see: the report
      // stops mid-sentence. Both turns of the prompt have to rule it out.
      final String system = DebriefService.systemPrompt(AppStrings.en);
      expect(system, contains('never stopping mid-thought'));
      expect(system, contains('200-350 words'));

      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        sample(),
        kNow,
      );
      expect(prompt, contains('Finish the last section properly'));
    });

    test('marks an absent status as none rather than omitting it', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        <Task>[
          Task(
            title: 'Only one',
            scheduledTime: DateTime(2026, 9, 9, 9),
            status: TaskStatus.completed,
          ),
        ],
        kNow,
      );

      expect(prompt, contains('PARTIAL (progress made, not finished): none'));
      expect(prompt, contains('SKIPPED (never started or postponed): none'));
    });

    test('quotes the note beside the task it belongs to', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        <Task>[
          Task(
            title: 'Refactor parser',
            scheduledTime: DateTime(2026, 9, 9, 14),
            status: TaskStatus.partial,
            note: 'blocked on review',
          ),
          Task(
            title: 'Gym',
            scheduledTime: DateTime(2026, 9, 9, 18),
            status: TaskStatus.skipped,
          ),
        ],
        kNow,
      );

      expect(
        prompt,
        contains('"Refactor parser" scheduled Wed 9 Sep at 14:00; '
            'their reason: "blocked on review"'),
      );
      // A task without a note gets no dangling clause.
      expect(prompt, contains('"Gym" scheduled Wed 9 Sep at 18:00\n'));
    });

    test('tells the model to treat quoted reasons as primary evidence', () {
      expect(
        DebriefService.systemPrompt(AppStrings.en),
        contains('that reason is evidence'),
      );
      expect(
        DebriefService.buildPrompt(ReportRange.today, <Task>[], kNow),
        contains('working from the reasons quoted in the log above'),
      );
    });

    test('names the range and its length', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.thisWeek,
        sample(),
        kNow,
      );
      expect(prompt, contains('this week'));
      expect(prompt, contains('3 day(s)'));
    });
  });

  // ---- Screen behaviour -------------------------------------------------

  group('Long debriefs', () {
    /// A debrief far taller than the 600px test surface.
    String longMarkdown() {
      final StringBuffer buffer = StringBuffer('## Summary\n');
      for (int i = 1; i <= 40; i++) {
        buffer.writeln('Paragraph $i of the debrief, with enough words in it '
            'to wrap onto more than one line on a phone.');
        buffer.writeln();
      }
      buffer.writeln('## Tomorrow’s steps');
      buffer.writeln('FINAL LINE OF THE DEBRIEF.');
      return buffer.toString();
    }

    testWidgets('every part of a long debrief is rendered, not clipped', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: longMarkdown(),
        )),
      );

      await pumpReport(tester);

      // Built, even though it starts far below the fold.
      expect(find.textContaining('FINAL LINE OF THE DEBRIEF.'), findsOneWidget);
      expect(find.textContaining('Paragraph 40'), findsOneWidget);
    });

    testWidgets('the end of a long debrief can be scrolled to', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: longMarkdown(),
        )),
      );

      await pumpReport(tester);

      final Finder last = find.textContaining('FINAL LINE OF THE DEBRIEF.');
      await tester.scrollUntilVisible(last, 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      // On screen, and inside the viewport rather than painted past its edge.
      final Rect box = tester.getRect(last);
      final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(box.top, greaterThanOrEqualTo(0));
      expect(box.bottom, lessThanOrEqualTo(screen.height));
    });

    testWidgets('a reply is read whole, however long', (
      WidgetTester tester,
    ) async {
      // 12k characters of debrief: nothing on this side may shorten it.
      final String huge = List<String>.generate(
        200,
        (int i) => 'Sentence $i of a very long debrief that keeps going.',
      ).join(' ');

      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await pumpReport(tester, client: replyWith(huge));

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      final SavedReport? stored = await onDb(
        tester,
        () => DatabaseService.instance.getLatestReport(ReportRange.today.name),
      );
      expect(stored!.contentMarkdown.length, huge.length);
      expect(stored.contentMarkdown, huge);
    });

    test('a provider that stopped at its ceiling is noticed', () {
      // finish_reason "length" is the provider saying the text ends early.
      // Nothing throws — it is a log line, not a failure — but the parse has
      // to survive every shape of body.
      AiService.warnIfTruncated(jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'length',
            'message': <String, String>{'content': 'cut off here'},
          },
        ],
      }));
      AiService.warnIfTruncated('not json at all');
      AiService.warnIfTruncated('{}');
      AiService.warnIfTruncated(jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{'finish_reason': 'stop'},
        ],
      }));
    });

    testWidgets('the debrief asks for a budget that fits a full report', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await pumpReport(tester, client: replyWith('## Summary\nDone.'));

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      // 700 tokens used to cut an Arabic debrief off mid-sentence; Arabic
      // costs markedly more tokens per word than English.
      final Map<String, Object?> body =
          jsonDecode(requests.single.body) as Map<String, Object?>;
      expect(body['max_tokens'], AiService.defaultMaxTokens);
      // 2048 still cut debriefs off: thinking models spend part of it on
      // hidden reasoning before writing a word of the report.
      expect(AiService.defaultMaxTokens, 8192);

      // max_completion_tokens was sent alongside for a while; Gemini's
      // compatibility layer rejects the unknown field with a 400.
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });
  });

  group('Stat chip rendering', () {
    /// Every Text inside one chip, in the order they are laid out.
    List<String> chipTexts(WidgetTester tester, String label) {
      final Finder chip = find.ancestor(
        of: find.text(label),
        matching: find.byType(StatChip),
      );
      return tester
          .widgetList<Text>(find.descendant(of: chip, matching: find.byType(Text)))
          .map((Text t) => t.data ?? '')
          .toList();
    }

    testWidgets('a chip is a number and a label, and nothing else', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await pumpReport(tester);

      expect(chipTexts(tester, 'Completed'), <String>['1', 'Completed']);

      // The old design drew a 3px tall bar to the left of the number, which
      // at this size reads as a pipe character stuck to the digits — "|1".
      // One decorated box per chip means the rail has not come back.
      final Finder chip = find.ancestor(
        of: find.text('Completed'),
        matching: find.byType(StatChip),
      );
      expect(
        find.descendant(of: chip, matching: find.byType(Container)),
        findsOneWidget,
      );
    });

    testWidgets('the number sits centred in its box', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await pumpReport(tester);

      final Finder chip = find.ancestor(
        of: find.text('Completed'),
        matching: find.byType(StatChip),
      );

      // The rail used to push the digits off-centre; nothing should now.
      expect(
        tester.getCenter(find.text('1')).dx,
        moreOrLessEquals(tester.getCenter(chip).dx, epsilon: 1.0),
      );
      expect(
        tester.getCenter(find.text('Completed')).dx,
        moreOrLessEquals(tester.getCenter(chip).dx, epsilon: 1.0),
      );
    });

    testWidgets('counts are plain 0-9 digits in English', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await seed(tester, 'Half', DateTime(2026, 9, 9, 10), TaskStatus.partial);
      await seed(tester, 'Half 2', DateTime(2026, 9, 9, 11),
          TaskStatus.partial);
      await pumpReport(tester);

      expect(chipTexts(tester, 'Completed').first, '1');
      expect(chipTexts(tester, 'Partial').first, '2');
      expect(chipTexts(tester, 'Skipped').first, '0');
    });

    testWidgets('counts stay plain 0-9 digits in Arabic', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9), TaskStatus.completed);
      await pumpReport(tester, language: 'ar');

      // A count is data, not prose: it must not come back as ١ or ٠.
      final Iterable<StatChip> chips =
          tester.widgetList<StatChip>(find.byType(StatChip));
      for (final StatChip chip in chips) {
        final List<String> texts = chipTexts(tester, chip.label);
        expect(
          texts.first,
          matches(RegExp(r'^[0-9]+$')),
          reason: 'chip "${chip.label}" rendered "${texts.first}"',
        );
      }
    });

    testWidgets('the three chips line up at the same width', (
      WidgetTester tester,
    ) async {
      // One chip on a double-digit count, the others on single digits.
      for (int i = 0; i < 12; i++) {
        await seed(tester, 'Done $i', DateTime(2026, 9, 9, 9),
            TaskStatus.completed);
      }
      await pumpReport(tester);

      final double completed = tester
          .getSize(find.ancestor(
            of: find.text('Completed'),
            matching: find.byType(StatChip),
          ))
          .height;
      final double skipped = tester
          .getSize(find.ancestor(
            of: find.text('Skipped'),
            matching: find.byType(StatChip),
          ))
          .height;

      expect(completed, skipped, reason: 'chips share one baseline');
    });
  });

  group('Counts', () {
    testWidgets('shows a stat chip per terminal status', (
      WidgetTester tester,
    ) async {
      await pumpReport(tester);
      expect(find.byType(StatChip), findsNWidgets(3));
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Partial'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
    });

    testWidgets('counts only tasks inside the selected range', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done today', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await seed(tester, 'Partial today', DateTime(2026, 9, 9, 10),
          TaskStatus.partial);
      // Two days back: outside "Today", inside "Last 3 days".
      await seed(tester, 'Skipped Monday', DateTime(2026, 9, 7, 9),
          TaskStatus.skipped);

      await pumpReport(tester);

      int countFor(String label) => tester
          .widgetList<StatChip>(find.byType(StatChip))
          .firstWhere((StatChip c) => c.label == label)
          .count;

      expect(countFor('Completed'), 1);
      expect(countFor('Partial'), 1);
      expect(countFor('Skipped'), 0, reason: 'Monday is outside today');

      await tester.tap(
        find.byKey(ReportScreen.rangeKey(ReportRange.lastThreeDays)),
      );
      await settle(tester);

      expect(countFor('Skipped'), 1, reason: 'Monday is inside last 3 days');
    });

    testWidgets('offers no generate button when the range is empty', (
      WidgetTester tester,
    ) async {
      await pumpReport(tester);

      expect(find.byKey(ReportScreen.generateKey), findsNothing);
      expect(find.textContaining('No tasks in this range'), findsOneWidget);
    });

    testWidgets('warns when nothing has been resolved yet', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Untouched', DateTime(2026, 9, 9, 9),
          TaskStatus.pending);
      await pumpReport(tester);

      expect(find.byKey(ReportScreen.generateKey), findsOneWidget);
      expect(
        find.textContaining('Nothing has been marked done'),
        findsOneWidget,
      );
    });
  });

  group('Range chips', () {
    testWidgets('renders one chip per range with today active', (
      WidgetTester tester,
    ) async {
      await pumpReport(tester);

      for (final ReportRange range in ReportRange.values) {
        expect(find.byKey(ReportScreen.rangeKey(range)), findsOneWidget);
      }
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Last 3 days'), findsOneWidget);
      expect(find.text('This week'), findsOneWidget);
    });

    testWidgets('switching range discards a debrief for the old window', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await pumpReport(tester, client: replyWith('## Summary\nAll good.'));

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);
      expect(find.byKey(ReportScreen.markdownKey), findsOneWidget);

      await tester.tap(
        find.byKey(ReportScreen.rangeKey(ReportRange.thisWeek)),
      );
      await settle(tester);

      expect(find.byKey(ReportScreen.markdownKey), findsNothing);
    });
  });

  group('Generating a debrief', () {
    testWidgets('posts the task log and renders the markdown reply', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Refactor parser', DateTime(2026, 9, 9, 14),
          TaskStatus.partial);
      await pumpReport(
        tester,
        client: replyWith('## Summary\nA partial day.\n\n## Bottlenecks\nLate starts.'),
      );

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      // The request carried the real task log.
      expect(requests, hasLength(1));
      final Map<String, Object?> body =
          jsonDecode(requests.single.body) as Map<String, Object?>;
      final List<Object?> messages = body['messages']! as List<Object?>;
      expect(messages, hasLength(2));
      expect(
        (messages.first as Map<Object?, Object?>)['role'],
        'system',
      );
      final String userTurn =
          (messages.last as Map<Object?, Object?>)['content']! as String;
      expect(userTurn, contains('"Refactor parser"'));
      expect(body['model'], 'test-model');

      // And the reply is rendered as markdown, not raw text.
      expect(find.byKey(ReportScreen.markdownKey), findsOneWidget);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.textContaining('A partial day'), findsWidgets);
    });

    testWidgets('uses the stored credentials and endpoint', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await pumpReport(tester, client: replyWith('ok'));

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      final http.Request request = requests.single;
      expect(
        request.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(request.headers['Authorization'], 'Bearer sk-test');
      expect(request.headers['User-Agent'], AiService.userAgent);
    });

    testWidgets('explains a rejected key plainly, without the raw body', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await pumpReport(
        tester,
        client: failWith(401, '{"error":{"message":"Bad key"}}'),
      );

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      expect(find.byKey(ReportScreen.errorKey), findsOneWidget);
      expect(
        find.text(AppStrings.en.aiFailure(AiFailure.unauthorized)),
        findsOneWidget,
      );
      // The provider's JSON stays in the log, never on screen.
      expect(find.textContaining('Bad key'), findsNothing);
      expect(find.textContaining('{'), findsNothing);
      expect(find.byKey(ReportScreen.markdownKey), findsNothing);
    });

    testWidgets('a network failure is caught, not thrown', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await pumpReport(
        tester,
        client: MockClient((http.Request request) async {
          throw Exception('no route to host');
        }),
      );

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      expect(find.text(AppStrings.en.aiFailure(AiFailure.network)),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a 200 with no content is reported, not rendered blank', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await pumpReport(
        tester,
        client: MockClient((http.Request request) async {
          return http.Response('{"choices":[]}', 200);
        }),
      );

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      expect(find.text(AppStrings.en.aiFailure(AiFailure.emptyResponse)),
          findsOneWidget);
      expect(find.byKey(ReportScreen.markdownKey), findsNothing);
    });

    testWidgets('missing credentials offer a shortcut to Settings', (
      WidgetTester tester,
    ) async {
      useStoredSettings(<String, Object>{});
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);
      await pumpReport(tester);

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      // No request should ever leave without a key.
      expect(requests, isEmpty);
      expect(
        find.text(AppStrings.en.aiFailure(AiFailure.missingConfiguration)),
        findsOneWidget,
      );

      await tester.tap(find.byKey(ReportScreen.settingsShortcutKey));
      await settle(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('a retry after an error clears the error', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Done', DateTime(2026, 9, 9, 9),
          TaskStatus.completed);

      bool firstCall = true;
      await pumpReport(
        tester,
        client: MockClient((http.Request request) async {
          requests.add(request);
          if (firstCall) {
            firstCall = false;
            return http.Response('{"error":{"message":"nope"}}', 500);
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, String>{'content': '## Summary\nFine.'},
                },
              ],
            }),
            200,
          );
        }),
      );

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);
      expect(find.byKey(ReportScreen.errorKey), findsOneWidget);

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      expect(find.byKey(ReportScreen.errorKey), findsNothing);
      expect(find.byKey(ReportScreen.markdownKey), findsOneWidget);
    });
  });

  // ---- Bidirectional text -----------------------------------------------

  group('BidiText', () {
    test('isolates a Latin run so it cannot disturb the Arabic line', () {
      final String out = BidiText.isolateLatin('أنجزت مهمة Deep Work اليوم.');

      expect(out, contains('${BidiText.fsi}Deep Work${BidiText.pdi}'));
      expect(BidiText.strip(out), 'أنجزت مهمة Deep Work اليوم.');
    });

    test('pure Arabic is left byte-for-byte alone', () {
      const String arabic = 'لم تكتمل المهمة بسبب ضيق الوقت.';
      expect(BidiText.isolateLatin(arabic), arabic);
    });

    test('applying it twice changes nothing', () {
      const String source = 'راجعت Gym مرتين';
      final String once = BidiText.isolateLatin(source);
      expect(BidiText.isolateLatin(once), once);
    });

    test('markdown structure survives untouched', () {
      // Every one of these would parse differently if an isolate landed
      // inside the syntax rather than around the words.
      const String markdown = '## Summary\n'
          '- **Deep Work** لم تكتمل\n'
          '- see [the log](https://example.com/log)\n';
      final String out = BidiText.isolateLatin(markdown);

      expect(out, contains('## '));
      expect(out, contains('- **'));
      expect(out, contains('**${BidiText.fsi}Deep Work${BidiText.pdi}**'));
      expect(out, contains(']('));
      expect(BidiText.strip(out), markdown);
    });

    test('an English document is left alone in an LTR layout', () {
      const String english = 'You finished Deep Work today.';
      expect(BidiText.forDirection(english, isRtl: false), english);
      expect(
        BidiText.forDirection(english, isRtl: true),
        isNot(english),
      );
    });
  });

  // ---- Saved reports ----------------------------------------------------

  group('Saved debriefs', () {
    testWidgets('a generated debrief is stored and read back', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await pumpReport(tester, client: replyWith('## Summary\nAll good.'));

      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      final SavedReport? stored = await onDb(
        tester,
        () => DatabaseService.instance.getLatestReport(ReportRange.today.name),
      );
      expect(stored, isNotNull);
      expect(stored!.contentMarkdown, '## Summary\nAll good.');
      expect(stored.range, ReportRange.today);
    });

    testWidgets('reopening shows the stored debrief without calling the API', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: '## Summary\nFrom yesterday.',
        )),
      );

      await pumpReport(tester);

      expect(find.byKey(ReportScreen.markdownKey), findsOneWidget);
      expect(find.textContaining('From yesterday.'), findsOneWidget);
      expect(requests, isEmpty, reason: 'a stored report costs nothing');

      // The button now offers to replace what is on screen, not to create it.
      expect(find.text('Re-generate'), findsOneWidget);
      expect(find.byKey(ReportScreen.generatedAtKey), findsOneWidget);
    });

    testWidgets('each range keeps its own debrief', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await onDb(tester, () async {
        await DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'TODAY REPORT',
        ));
        await DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.thisWeek,
          contentMarkdown: 'WEEK REPORT',
        ));
      });

      await pumpReport(tester);
      expect(find.textContaining('TODAY REPORT'), findsOneWidget);

      await tester.tap(find.byKey(ReportScreen.rangeKey(ReportRange.thisWeek)));
      await settle(tester);

      expect(find.textContaining('WEEK REPORT'), findsOneWidget);
      expect(find.textContaining('TODAY REPORT'), findsNothing);
    });

    testWidgets('a range with no stored debrief offers to generate one', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await pumpReport(tester);

      expect(find.byKey(ReportScreen.markdownKey), findsNothing);
      expect(find.byKey(ReportScreen.generatedAtKey), findsNothing);
      expect(find.text('Generate AI debrief'), findsOneWidget);
    });

    testWidgets('re-generating replaces what is shown', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'OLD REPORT',
        )),
      );

      await pumpReport(tester, client: replyWith('NEW REPORT'));
      await tester.tap(find.byKey(ReportScreen.generateKey));
      await settle(tester);

      expect(find.textContaining('NEW REPORT'), findsOneWidget);
      expect(find.textContaining('OLD REPORT'), findsNothing);

      final SavedReport? latest = await onDb(
        tester,
        () => DatabaseService.instance.getLatestReport(ReportRange.today.name),
      );
      expect(latest!.contentMarkdown, 'NEW REPORT');
    });
  });

  // ---- Right-to-left rendering ------------------------------------------

  group('Arabic debriefs', () {
    testWidgets('the markdown is pinned to right-to-left', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'أنجزت مهمة Deep Work اليوم.',
        )),
      );

      await pumpReport(tester, language: 'ar');

      final Directionality wrapper = tester.widget<Directionality>(
        find
            .ancestor(
              of: find.byKey(ReportScreen.markdownKey),
              matching: find.byType(Directionality),
            )
            .first,
      );
      expect(wrapper.textDirection, TextDirection.rtl);
    });

    testWidgets('Latin task titles are isolated in an Arabic debrief', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'أنجزت مهمة Deep Work اليوم.',
        )),
      );

      await pumpReport(tester, language: 'ar');

      final MarkdownBody rendered = tester.widget<MarkdownBody>(
        find.byKey(ReportScreen.markdownKey),
      );
      expect(
        rendered.data,
        contains('${BidiText.fsi}Deep Work${BidiText.pdi}'),
      );
      // What was stored is untouched — the isolates are a rendering concern.
      expect(BidiText.strip(rendered.data), 'أنجزت مهمة Deep Work اليوم.');
    });

    testWidgets('an English debrief is rendered exactly as written', (
      WidgetTester tester,
    ) async {
      await seed(tester, 'Deep work', kNow, TaskStatus.completed);
      await onDb(
        tester,
        () => DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'You finished Deep Work today.',
        )),
      );

      await pumpReport(tester);

      final MarkdownBody rendered = tester.widget<MarkdownBody>(
        find.byKey(ReportScreen.markdownKey),
      );
      expect(rendered.data, 'You finished Deep Work today.');
    });

    test('the prompt asks for Arabic headings when replying in Arabic', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        <Task>[],
        kNow,
        strings: AppStrings.ar,
      );

      expect(prompt, contains('### 📊 خلاصة الإنجاز'));
      expect(prompt, contains('### ❌ نقاط التعثر والخلل'));
      expect(prompt, contains('### 🎯 خطة الضبط لليوم القادم'));
      expect(prompt, isNot(contains('Completion summary')));
      expect(prompt, isNot(contains('Where it broke down')));
    });

    test('the English prompt keeps the English headings', () {
      final String prompt = DebriefService.buildPrompt(
        ReportRange.today,
        <Task>[],
        kNow,
      );

      expect(prompt, contains('### 📊 Completion summary'));
      expect(prompt, contains('### ❌ Where it broke down'));
      expect(prompt, contains('### 🎯 Correction plan for tomorrow'));
    });
  });
}
