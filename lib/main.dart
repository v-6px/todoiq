import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'l10n/app_strings.dart';
import 'screens/home_screen.dart';
import 'services/locale_controller.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Warm the preferences cache before the first frame.
  await SettingsService.instance.init();

  // Load the stored language (or the device's) before anything renders, so
  // the first frame is already in the right language and direction.
  await LocaleController.instance.load();

  // Arabic month and weekday names come from intl's locale data, which has to
  // be loaded explicitly for anything but the default locale.
  await initializeDateFormatting();

  // Load the time zone database and the alarm plugin. Permissions are asked
  // for later, when the user first schedules a task.
  await NotificationService.instance.init();

  runApp(const TaskMasterApp());
}

class TaskMasterApp extends StatelessWidget {
  const TaskMasterApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuilds the whole app when the language changes, so switching takes
    // effect immediately rather than on next launch.
    return ValueListenableBuilder<Locale>(
      valueListenable: LocaleController.instance,
      builder: (BuildContext context, Locale locale, _) {
        return MaterialApp(
          onGenerateTitle: (BuildContext context) =>
              AppStrings.of(context).appTitle,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.forLocale(locale),
          locale: locale,
          supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
          // Supplies Material/Cupertino strings and, for Arabic, the
          // right-to-left text direction every screen inherits.
          localizationsDelegates: const <LocalizationsDelegate<Object>>[
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const HomeScreen(),
        );
      },
    );
  }
}
