// Renders the Google Play screenshots from the real app screens.
//
// Run from the project root:
//
//   flutter test tool/screenshots/store_screenshots_test.dart
//
// Writes 1080x2400 PNGs to assets/store/screenshots/. Everything on screen is
// the production widget tree — HomeScreen, ChatCoachScreen, ReportScreen,
// SettingsScreen — fed with seeded Arabic data in a throwaway database and a
// fake network, so the images always match what the app actually looks like.
//
// Lives outside test/ on purpose: `flutter test` must not rewrite store assets.

// This is test code run by `flutter test`, but the analyzer only knows that
// for files under test/, so it would flag every test-only helper here.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/models/chat_message_model.dart';
import 'package:todo_list/models/report_range.dart';
import 'package:todo_list/models/saved_report.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/chat_coach_screen.dart';
import 'package:todo_list/screens/home_screen.dart';
import 'package:todo_list/screens/report_screen.dart';
import 'package:todo_list/screens/settings_screen.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/debrief_service.dart';
import 'package:todo_list/services/notification_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';

/// Play's recommended phone size, 9:20. 2.625 is a Pixel-class density, so
/// the layout is the one a typical 411dp-wide phone shows.
const Size kPhysicalSize = Size(1080, 2400);
const double kPixelRatio = 2.625;

/// Tuesday 15 September 2026, evening — late enough that the day has a story.
final DateTime kDay = DateTime(2026, 9, 15);
final DateTime kNow = DateTime(2026, 9, 15, 21, 30);

const String kOutDir = 'assets/store/screenshots';
const MethodChannel _notifications =
    MethodChannel('dexterous.com/flutter/local_notifications');

final GlobalKey _frame = GlobalKey();

Future<void> _loadFont(String family, List<String> paths) async {
  final FontLoader loader = FontLoader(family);
  for (final String path in paths) {
    final Uint8List bytes = File(path).readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  // flutter_test renders every family as the Ahem test font unless the real
  // files are registered, which would turn every glyph into a black box.
  final String flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent
          .parent.path;
  final String material = '$flutterRoot/bin/cache/artifacts/material_fonts';

  await _loadFont('Thmanyah', <String>['assets/fonts/Thmanyah-Regular.otf']);
  await _loadFont('MaterialIcons', <String>[
    '$material/materialicons-regular.otf',
  ]);
  await _loadFont('Roboto', <String>[
    '$material/roboto-regular.ttf',
    '$material/roboto-medium.ttf',
    '$material/roboto-bold.ttf',
  ]);
}

Widget _app(Widget home) {
  const Locale arabic = Locale('ar');
  return RepaintBoundary(
    key: _frame,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forLocale(arabic),
      locale: arabic,
      supportedLocales: const <Locale>[Locale('en'), Locale('ar'), Locale('fr')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    ),
  );
}

Future<T> _onDb<T>(WidgetTester tester, Future<T> Function() action) async {
  late T result;
  await tester.runAsync(() async {
    result = await action();
  });
  return result;
}

/// Lets real async work (SQLite on its isolate) land, then settles frames.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  await _settle(tester);
  final RenderRepaintBoundary boundary =
      _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;

  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: kPixelRatio);
    final ByteData? png =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final File file = File('$kOutDir/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.absolute.path}');
  });
  debugDisableShadows = true;
}

// --- Sample data ------------------------------------------------------------

DateTime _at(int hour, [int minute = 0]) =>
    DateTime(kDay.year, kDay.month, kDay.day, hour, minute);

Future<void> _seedTasks(WidgetTester tester) async {
  await _onDb(tester, () async {
    final DatabaseService db = DatabaseService.instance;

    final int sport = await db.insertTask(Task(
      title: 'الرياضة اليومية',
      scheduledTime: DateTime(2026, 9, 1, 6, 30),
      recurrenceType: RecurrenceType.daily,
      createdAt: DateTime(2026, 9, 1),
    ));
    await db.updateStatusWithNote(sport, TaskStatus.completed, null,
        forDate: kDay);

    final int reading = await db.insertTask(Task(
      title: 'قراءة كتاب الذكاء الاصطناعي',
      scheduledTime: DateTime(2026, 9, 7, 8, 0),
      recurrenceType: RecurrenceType.weeklyDays,
      repeatDays: <int>[1, 2, 4],
      createdAt: DateTime(2026, 9, 7),
    ));
    await db.updateStatusWithNote(reading, TaskStatus.completed, null,
        forDate: kDay);

    await db.insertTask(Task(
      title: 'الرد على بريد العملاء',
      scheduledTime: _at(9, 30),
      status: TaskStatus.completed,
      createdAt: _at(7),
    ));

    await db.insertTask(Task(
      title: 'مراجعة متطلبات المشروع',
      scheduledTime: _at(11),
      status: TaskStatus.partial,
      note: 'أنهيت القسم الأول، والباقي بعد اجتماع الفريق',
      createdAt: _at(7),
    ));

    await db.insertTask(Task(
      title: 'اجتماع فريق التطوير',
      scheduledTime: _at(14),
      createdAt: _at(7),
    ));

    await db.insertTask(Task(
      title: 'شراء المستلزمات',
      scheduledTime: _at(18, 30),
      createdAt: _at(7),
    ));

    await db.insertTask(Task(
      title: 'تخطيط مهام الغد',
      scheduledTime: DateTime(2026, 9, 1, 22, 0),
      recurrenceType: RecurrenceType.daily,
      createdAt: DateTime(2026, 9, 1),
    ));
  });
}

Future<void> _seedConversation(WidgetTester tester) async {
  await _onDb(tester, () async {
    final DatabaseService db = DatabaseService.instance;

    await db.insertChatMessage(ChatMessage.user(
      'عندي بعد الظهر اجتماع الفريق وشراء المستلزمات، وما زال نصف مراجعة '
      'المتطلبات معلّقًا. كيف أوزّع وقتي؟',
      timestamp: _at(12, 40),
    ));

    await db.insertChatMessage(ChatMessage.assistant(
      'خطة واقعية لبقية يومك:\n'
      '\n'
      '1. **14:00 — اجتماع فريق التطوير:** اطرح الأسئلة المفتوحة من '
      'مراجعة المتطلبات، فهي ما أوقفك صباحًا.\n'
      '2. **15:00 — جلسة تركيز (60 دقيقة):** أنهِ القسم الثاني من '
      'المتطلبات مباشرة بعد الاجتماع والإجابات حاضرة في ذهنك.\n'
      '3. **18:30 — شراء المستلزمات:** جهّز القائمة الآن حتى لا تتجاوز '
      'نصف ساعة.\n'
      '\n'
      'هل أضيف جلسة التركيز إلى جدولك؟',
      timestamp: _at(12, 41),
    ));

    await db.insertChatMessage(ChatMessage.user(
      'نعم، أضفها من فضلك',
      timestamp: _at(12, 42),
    ));

    await db.insertChatMessage(ChatMessage.assistant(
      'تم — جلسة التركيز محجوزة الساعة 15:00 اليوم.\n'
      '```task_action\n'
      '{"title": "جلسة تركيز: إنهاء مراجعة المتطلبات", "date": "2026-09-15", '
      '"time": "15:00", "recurrence": "none"}\n'
      '```',
      timestamp: _at(12, 42),
    ));
  });
}

String _report() {
  // Matches the seeded day: 7 tasks, 3 completed and 1 partial of the 4
  // actioned (75%), 3 still open.
  return '### ${DebriefService.summaryMark} خلاصة الإنجاز\n'
      'أنجزت **3 من 7 مهام** بنسبة إتمام **75%** مما تعاملت معه. الصباح '
      'كان منضبطًا، والتراجع بدأ بعد الظهر.\n'
      '\n'
      '### ${DebriefService.obstaclesMark} نقاط التعثر والخلل\n'
      '- **مراجعة المتطلبات** توقفت لأنها تنتظر مخرجات اجتماع الفريق.\n'
      '- كل المهام المعلّقة بعد الساعة الثانية، حيث تقل إنتاجيتك.\n'
      '\n'
      '### ${DebriefService.planMark} خطة الضبط لليوم القادم\n'
      '- ضع **الاجتماعات قبل** المهام التي تعتمد عليها.\n'
      '- احجز **جلسة تركيز 15:00** لإنهاء المتطلبات.\n'
      '- اجمع المشاوير في **نافذة واحدة من 30 دقيقة**.\n';
}

// --- Harness ----------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.debugDatabaseName = 'store_screenshots.db';
    await initializeDateFormatting();
    NotificationService.configureLocalTimeZone();
    await _loadFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'language_code': 'ar',
      'api_key': 'AIzaSyD4-sample-key-for-store-screens',
      'base_url': SettingsService.defaultBaseUrl,
      'model_name': SettingsService.defaultModelName,
    });
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();

    final Database db = await DatabaseService.instance.database;
    for (final String table in <String>[
      DatabaseService.tasksTable,
      DatabaseService.completionsTable,
      DatabaseService.reportsTable,
      DatabaseService.chatMessagesTable,
    ]) {
      await db.delete(table);
    }

    // Permissions granted, alarms accepted: no banner on the home screen.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notifications, (MethodCall call) async {
      switch (call.method) {
        case 'initialize':
        case 'requestNotificationsPermission':
        case 'canScheduleExactNotifications':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notifications, null);
  });

  Future<void> prepareView(WidgetTester tester) async {
    tester.view.physicalSize = kPhysicalSize;
    tester.view.devicePixelRatio = kPixelRatio;
    addTearDown(tester.view.reset);
    // Real elevation, not the flat test rendering. Restored in _capture:
    // the framework checks it before tear-downs run.
    debugDisableShadows = false;
  }

  http.Client okClient(String content) => MockClient(
        (http.Request request) async => http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'finish_reason': 'stop',
                'message': <String, String>{'content': content},
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        ),
      );

  testWidgets('1 home', (WidgetTester tester) async {
    await prepareView(tester);
    await _seedTasks(tester);

    await tester.pumpWidget(_app(HomeScreen(day: kDay)));
    await _capture(tester, '1_home_tasks');
  });

  testWidgets('2 assistant', (WidgetTester tester) async {
    await prepareView(tester);
    await _seedTasks(tester);
    await _seedConversation(tester);

    await tester.pumpWidget(_app(ChatCoachScreen(
      day: kDay,
      today: kDay,
      client: okClient('.'),
    )));
    await _capture(tester, '2_assistant_chat');
  });

  testWidgets('3 report', (WidgetTester tester) async {
    await prepareView(tester);
    await _seedTasks(tester);
    await _onDb(
      tester,
      () => DatabaseService.instance.insertReport(SavedReport.forRange(
        ReportRange.today,
        contentMarkdown: _report(),
        createdAt: DateTime(2026, 9, 15, 21, 12),
      )),
    );

    await tester.pumpWidget(_app(ReportScreen(
      now: kNow,
      client: okClient(_report()),
    )));
    await _capture(tester, '3_productivity_report');
  });

  testWidgets('4 settings', (WidgetTester tester) async {
    await prepareView(tester);

    await tester.pumpWidget(_app(SettingsScreen(client: okClient('pong'))));
    await _settle(tester);

    final Finder test = find.byKey(SettingsScreen.testButtonKey);
    await tester.ensureVisible(test);
    await tester.pumpAndSettle();
    await tester.tap(test);
    await _settle(tester);

    await _capture(tester, '4_settings_gemini');
  });
}
