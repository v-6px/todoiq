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

  // The time zone database has to be loaded, and tz.local pointed at the
  // device's zone, before anything builds a TZDateTime — otherwise every
  // alarm is computed in UTC. Done here explicitly rather than trusted to the
  // plugin setup below, which may fail on its own without taking this with it.
  NotificationService.configureLocalTimeZone();

  // The alarm plugin and its Android channel. Permissions are asked for on
  // the home screen.
  try {
    await NotificationService.instance.init();
  } catch (error, stack) {
    // A broken plugin must not stop the app from opening; the tasks are still
    // there, only the reminders are affected.
    debugPrint('main: notification setup failed with '
        '${error.runtimeType}: $error');
    debugPrintStack(stackTrace: stack, label: 'main');
  }

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
          supportedLocales: const <Locale>[
            Locale('en'),
            Locale('ar'),
            Locale('fr'),
          ],
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
