import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/l10n/app_strings.dart';
import 'package:todo_list/models/report_range.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/screens/chat_coach_screen.dart';
import 'package:todo_list/screens/home_screen.dart';
import 'package:todo_list/screens/report_screen.dart';
import 'package:todo_list/screens/settings_screen.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/locale_controller.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';
import 'package:todo_list/widgets/note_sheet.dart';
import 'package:todo_list/widgets/task_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.debugDatabaseName = 'phase7_test.db';
    initializeDateFormatting();
  });

  void useStoredSettings([
    Map<String, Object> values = const <String, Object>{},
  ]) {
    SharedPreferences.setMockInitialValues(values);
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();
  }

  setUp(() async {
    useStoredSettings();
    LocaleController.instance.setForTesting('en');
    final Database database = await DatabaseService.instance.database;
    await database.delete(DatabaseService.tasksTable);
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Widget wrap(Widget child, String language) {
    return MaterialApp(
      theme: AppTheme.forLocale(Locale(language)),
      locale: Locale(language),
      supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );
  }

  // ---- Strings ----------------------------------------------------------

  group('AppStrings', () {
    test('resolves by language code and locale', () {
      expect(AppStrings.forLanguage('en').languageCode, 'en');
      expect(AppStrings.forLanguage('ar').languageCode, 'ar');
      expect(AppStrings.forLocale(const Locale('ar')).languageCode, 'ar');
      // An unsupported language falls back rather than throwing.
      expect(AppStrings.forLanguage('fr').languageCode, 'en');
    });

    test('reports the right text direction', () {
      expect(AppStrings.en.textDirection, TextDirection.ltr);
      expect(AppStrings.ar.textDirection, TextDirection.rtl);
    });

    test('Arabic differs from English on every visible string', () {
      // Guards against a missed translation silently shipping English.
      final List<String Function(AppStrings)> readers =
          <String Function(AppStrings)>[
        (AppStrings s) => s.nothingScheduledToday,
        (AppStrings s) => s.nothingScheduledThisDay,
        (AppStrings s) => s.emptyStateHint,
        (AppStrings s) => s.newTask,
        (AppStrings s) => s.previousDay,
        (AppStrings s) => s.nextDay,
        (AppStrings s) => s.today,
        (AppStrings s) => s.aiReports,
        (AppStrings s) => s.aiCoach,
        (AppStrings s) => s.settings,
        (AppStrings s) => s.back,
        (AppStrings s) => s.statusDone,
        (AppStrings s) => s.statusPartial,
        (AppStrings s) => s.statusSkipped,
        (AppStrings s) => s.statusPending,
        (AppStrings s) => s.actionComplete,
        (AppStrings s) => s.actionPartial,
        (AppStrings s) => s.actionSkip,
        (AppStrings s) => s.addTaskTitle,
        (AppStrings s) => s.addTaskHint,
        (AppStrings s) => s.addTaskEmptyError,
        (AppStrings s) => s.addTaskButton,
        (AppStrings s) => s.changeTime,
        (AppStrings s) => s.timeHasPassedNotice,
        (AppStrings s) => s.notePromptPartial,
        (AppStrings s) => s.notePromptSkipped,
        (AppStrings s) => s.noteHint,
        (AppStrings s) => s.noteSave,
        (AppStrings s) => s.noteSkip,
        (AppStrings s) => s.settingsProvider,
        (AppStrings s) => s.settingsCredentials,
        (AppStrings s) => s.settingsLanguage,
        (AppStrings s) => s.settingsApiKey,
        (AppStrings s) => s.settingsBaseUrl,
        (AppStrings s) => s.settingsModel,
        (AppStrings s) => s.settingsTestConnection,
        (AppStrings s) => s.settingsSave,
        (AppStrings s) => s.settingsSaved,
        (AppStrings s) => s.settingsPrivacyNote,
        (AppStrings s) => s.enterApiKeyFirst,
        (AppStrings s) => s.reportTitle,
        (AppStrings s) => s.rangeToday,
        (AppStrings s) => s.rangeLastThreeDays,
        (AppStrings s) => s.rangeThisWeek,
        (AppStrings s) => s.statCompleted,
        (AppStrings s) => s.generateDebrief,
        (AppStrings s) => s.noTasksInRange,
        (AppStrings s) => s.openSettings,
        (AppStrings s) => s.coachTitle,
        (AppStrings s) => s.coachEmptyTitle,
        (AppStrings s) => s.coachInputHint,
        (AppStrings s) => s.taskSavedReminderFailed,
        (AppStrings s) => s.exactAlarmBannerTitle,
        (AppStrings s) => s.exactAlarmBannerBody,
        (AppStrings s) => s.exactAlarmBannerAction,
        (AppStrings s) => s.exactAlarmBannerDismiss,
        (AppStrings s) => s.editTaskTitle,
        (AppStrings s) => s.editTaskButton,
        (AppStrings s) => s.deleteTask,
        (AppStrings s) => s.taskDeleted,
        (AppStrings s) => s.undo,
        (AppStrings s) => s.regenerateDebrief,
        (AppStrings s) => s.reportHeadingSummary,
        (AppStrings s) => s.reportHeadingBottlenecks,
        (AppStrings s) => s.reportHeadingTips,
        (AppStrings s) => s.coachThinking,
        (AppStrings s) => s.coachAddTaskButton,
        (AppStrings s) => s.coachAddingTask,
        (AppStrings s) => s.coachTaskAdded,
        (AppStrings s) => s.coachTaskAddFailed,
        (AppStrings s) => s.coachProposedTask,
        (AppStrings s) => s.send,
        (AppStrings s) => s.replyLanguageInstruction,
      ];

      for (int i = 0; i < readers.length; i++) {
        final String english = readers[i](AppStrings.en);
        final String arabic = readers[i](AppStrings.ar);
        expect(english, isNotEmpty, reason: 'English string $i is empty');
        expect(arabic, isNotEmpty, reason: 'Arabic string $i is empty');
        expect(
          arabic,
          isNot(english),
          reason: 'string $i was never translated: "$english"',
        );
      }
    });

    test('the product name is the same in both languages', () {
      // Deliberately exempt from the "every string is translated" rule
      // above: ToDoIQ is a brand, and the launcher shows one name.
      expect(AppStrings.en.appTitle, 'ToDoIQ');
      expect(AppStrings.ar.appTitle, 'ToDoIQ');
    });

    test('Arabic strings actually contain Arabic script', () {
      final RegExp arabicScript = RegExp(r'[؀-ۿ]');
      for (final String value in <String>[
        AppStrings.ar.nothingScheduledToday,
        AppStrings.ar.notePromptSkipped,
        AppStrings.ar.settingsTestConnection,
        AppStrings.ar.coachEmptyTitle,
        AppStrings.ar.reportTitle,
      ]) {
        expect(arabicScript.hasMatch(value), isTrue, reason: value);
      }
    });

    test('the Arabic note prompt matches the requested wording', () {
      expect(AppStrings.ar.notePromptSkipped, 'ما الذي عطّلك؟ (اختياري)');
    });

    test('interpolated summaries put the numbers in', () {
      expect(AppStrings.en.summaryRemaining(3, 5), contains('3'));
      expect(AppStrings.ar.summaryRemaining(3, 5), contains('3'));
      expect(AppStrings.ar.summaryAllDone(4), contains('4'));
    });
  });

  // ---- Font -------------------------------------------------------------

  group('Thmanyah font', () {
    test('is used for Arabic and left to the platform for English', () {
      expect(AppTheme.fontFamilyForLanguage('ar'), 'Thmanyah');
      expect(AppTheme.fontFamilyForLanguage('en'), isNull);
      expect(
        AppTheme.fontFamilyForLocale(const Locale('ar')),
        AppTheme.arabicFontFamily,
      );
    });

    test('the Arabic theme carries the family across the text theme', () {
      final ThemeData arabic = AppTheme.forLocale(const Locale('ar'));
      expect(arabic.textTheme.bodyLarge!.fontFamily, 'Thmanyah');
      expect(arabic.textTheme.displayMedium!.fontFamily, 'Thmanyah');

      // English keeps whatever Flutter's default typography supplies (Roboto
      // on this platform) — the point is only that it is not the Arabic face.
      final ThemeData english = AppTheme.forLocale(const Locale('en'));
      expect(
        english.textTheme.bodyLarge!.fontFamily,
        isNot(AppTheme.arabicFontFamily),
      );
    });

    testWidgets('rendered Arabic text resolves to Thmanyah', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(
        Scaffold(
          body: TaskCard(
            task: Task(
              title: 'مراجعة التقرير',
              scheduledTime: DateTime(2026, 9, 9, 14),
            ),
            onStatusChanged: (_) {},
          ),
        ),
        'ar',
      ));

      final Text title = tester.widget<Text>(find.text('مراجعة التقرير'));
      final TextStyle effective = DefaultTextStyle.of(
        tester.element(find.text('مراجعة التقرير')),
      ).style.merge(title.style);

      expect(effective.fontFamily, 'Thmanyah');
    });
  });

  // ---- Persistence ------------------------------------------------------

  group('Language preference', () {
    test('falls back to Arabic for an unsupported device locale', () {
      expect(
        SettingsService.resolveDeviceLanguage(const Locale('fr')),
        'ar',
      );
      expect(
        SettingsService.resolveDeviceLanguage(const Locale('en')),
        'en',
      );
      expect(
        SettingsService.resolveDeviceLanguage(const Locale('ar')),
        'ar',
      );
    });

    test('an explicit choice is stored and read back', () async {
      expect(await SettingsService.instance.hasLanguagePreference(), isFalse);

      await SettingsService.instance.setLanguageCode('ar');

      expect(await SettingsService.instance.getLanguageCode(), 'ar');
      expect(await SettingsService.instance.hasLanguagePreference(), isTrue);
    });

    test('clearing the preference returns to the device locale', () async {
      await SettingsService.instance.setLanguageCode('en');
      await SettingsService.instance.clearLanguagePreference();

      expect(await SettingsService.instance.hasLanguagePreference(), isFalse);
    });

    test('a stored junk value is ignored', () async {
      useStoredSettings(<String, Object>{'language_code': 'klingon'});
      // Falls back rather than surfacing an unsupported language.
      expect(
        SettingsService.supportedLanguageCodes
            .contains(await SettingsService.instance.getLanguageCode()),
        isTrue,
      );
    });

    test('the controller persists what it switches to', () async {
      await LocaleController.instance.setLanguage('ar');

      expect(LocaleController.instance.value, const Locale('ar'));
      expect(LocaleController.instance.isArabic, isTrue);
      expect(await SettingsService.instance.getLanguageCode(), 'ar');
    });

    test('the controller notifies listeners on change', () async {
      LocaleController.instance.setForTesting('en');
      int notifications = 0;
      void listener() => notifications++;
      LocaleController.instance.addListener(listener);

      await LocaleController.instance.setLanguage('ar');
      expect(notifications, 1);

      // An unsupported code changes nothing.
      await LocaleController.instance.setLanguage('fr');
      expect(notifications, 1);

      LocaleController.instance.removeListener(listener);
    });

    test('load() reads the stored language into the notifier', () async {
      useStoredSettings(<String, Object>{'language_code': 'ar'});
      LocaleController.instance.setForTesting('en');

      await LocaleController.instance.load();

      expect(LocaleController.instance.languageCode, 'ar');
    });
  });

  // ---- RTL and translated screens ---------------------------------------

  group('Arabic UI', () {
    testWidgets('the home screen renders RTL with Arabic chrome', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrap(HomeScreen(day: DateTime(2026, 9, 9)), 'ar'),
      );
      await settle(tester);

      expect(
        Directionality.of(tester.element(find.byType(HomeScreen))),
        TextDirection.rtl,
      );
      expect(find.text(AppStrings.ar.nothingScheduledToday), findsOneWidget);
      expect(find.text(AppStrings.ar.newTask), findsOneWidget);
      // The weekday comes from intl's Arabic data, not a hand-rolled map.
      expect(find.text('الأربعاء'), findsOneWidget);
    });

    testWidgets('English keeps LTR', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(HomeScreen(day: DateTime(2026, 9, 9)), 'en'),
      );
      await settle(tester);

      expect(
        Directionality.of(tester.element(find.byType(HomeScreen))),
        TextDirection.ltr,
      );
      expect(find.text('Wednesday'), findsOneWidget);
    });

    testWidgets('task card statuses are translated', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(
        Scaffold(
          body: TaskCard(
            task: Task(
              title: 'مهمة',
              scheduledTime: DateTime(2026, 9, 9, 14),
              status: TaskStatus.partial,
            ),
            onStatusChanged: (_) {},
          ),
        ),
        'ar',
      ));

      expect(find.text(AppStrings.ar.statusPartial), findsOneWidget);
    });

    testWidgets('the note sheet asks in Arabic', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(
        const Scaffold(
          body: NoteSheet(taskTitle: 'مهمة', status: TaskStatus.skipped),
        ),
        'ar',
      ));
      await tester.pumpAndSettle();

      expect(find.text('ما الذي عطّلك؟ (اختياري)'), findsOneWidget);
      expect(find.text(AppStrings.ar.noteSkip), findsOneWidget);
      expect(find.text(AppStrings.ar.noteSave), findsOneWidget);
    });

    testWidgets('settings is translated and offers both languages', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(const SettingsScreen(), 'ar'));
      await tester.pumpAndSettle();

      expect(find.text(AppStrings.ar.settings), findsOneWidget);
      expect(find.text(AppStrings.ar.settingsLanguage), findsOneWidget);
      expect(find.text(AppStrings.ar.settingsTestConnection), findsOneWidget);
      expect(find.byKey(SettingsScreen.languageKey('en')), findsOneWidget);
      expect(find.byKey(SettingsScreen.languageKey('ar')), findsOneWidget);
    });

    testWidgets('the report screen is translated', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrap(ReportScreen(now: DateTime(2026, 9, 9)), 'ar'),
      );
      await settle(tester);

      expect(find.text(AppStrings.ar.reportTitle), findsOneWidget);
      expect(find.text(AppStrings.ar.rangeToday), findsOneWidget);
      expect(find.text(AppStrings.ar.rangeLastThreeDays), findsOneWidget);
      expect(find.text(AppStrings.ar.statCompleted), findsOneWidget);
    });

    testWidgets('the coach screen is translated', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(ChatCoachScreen(day: DateTime(2026, 9, 9)), 'ar'),
      );
      await settle(tester);

      expect(find.text(AppStrings.ar.coachTitle), findsOneWidget);
      expect(find.text(AppStrings.ar.coachEmptyTitle), findsOneWidget);
    });

    testWidgets('selecting a language switches without a restart', (
      WidgetTester tester,
    ) async {
      // Mirrors main(): the app listens to the controller and rebuilds.
      await tester.pumpWidget(
        ValueListenableBuilder<Locale>(
          valueListenable: LocaleController.instance,
          builder: (BuildContext context, Locale locale, _) {
            return wrap(const SettingsScreen(), locale.languageCode);
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(AppStrings.en.settings), findsOneWidget);

      await tester.tap(find.byKey(SettingsScreen.languageKey('ar')));
      await tester.pumpAndSettle();

      expect(find.text(AppStrings.ar.settings), findsOneWidget);
      expect(find.text(AppStrings.en.settingsTestConnection), findsNothing);
      expect(await SettingsService.instance.getLanguageCode(), 'ar');
    });
  });

  // ---- Prompts ----------------------------------------------------------

  group('AI prompts follow the language', () {
    test('the debrief asks for Arabic when Arabic is active', () {
      expect(
        ReportScreen.systemPrompt(AppStrings.ar),
        contains(AppStrings.ar.replyLanguageInstruction),
      );
      expect(
        ReportScreen.systemPrompt(AppStrings.en),
        contains('Reply in English.'),
      );
    });

    test('the coach asks for Arabic when Arabic is active', () {
      final String prompt = ChatCoachScreen.buildSystemPrompt(
        <Task>[],
        DateTime(2026, 9, 9),
        strings: AppStrings.ar,
      );
      expect(prompt, contains(AppStrings.ar.replyLanguageInstruction));
    });

    test('the task log itself stays in English for a stable format', () {
      final String prompt = ChatCoachScreen.buildSystemPrompt(
        <Task>[
          Task(
            title: 'مراجعة',
            scheduledTime: DateTime(2026, 9, 9, 14),
            status: TaskStatus.partial,
            note: 'لم يتّسع الوقت',
          ),
        ],
        DateTime(2026, 9, 9),
        strings: AppStrings.ar,
      );

      // Structure in English, user content untouched.
      expect(prompt, contains('partially done, not finished'));
      expect(prompt, contains('Wednesday 9 September'));
      expect(prompt, contains('"مراجعة"'));
      expect(prompt, contains('their reason: "لم يتّسع الوقت"'));
    });

    test('the debrief log keeps English headings under Arabic', () {
      final String prompt = ReportScreen.buildDebriefPrompt(
        ReportRange.today,
        <Task>[
          Task(
            title: 'مهمة',
            scheduledTime: DateTime(2026, 9, 9, 9),
            status: TaskStatus.completed,
          ),
        ],
        DateTime(2026, 9, 9),
        strings: AppStrings.ar,
      );

      expect(prompt, contains('COMPLETED (finished)'));
      expect(prompt, contains('"مهمة"'));
      expect(prompt, contains('Wed 9 Sep'));
    });
  });
}
