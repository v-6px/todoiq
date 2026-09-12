import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/app_strings.dart';
import '../models/task_model.dart';
import 'settings_service.dart';

/// The outcome of asking the OS for the permissions an alarm needs.
///
/// Both fields are null on platforms that do not gate the capability, which is
/// treated as "available" by [isFullyGranted].
class NotificationPermissions {
  final bool? notificationsGranted;
  final bool? exactAlarmsGranted;

  const NotificationPermissions({
    this.notificationsGranted,
    this.exactAlarmsGranted,
  });

  /// True when nothing was explicitly denied.
  bool get isFullyGranted =>
      notificationsGranted != false && exactAlarmsGranted != false;

  @override
  String toString() => 'NotificationPermissions(notifications: '
      '$notificationsGranted, exactAlarms: $exactAlarmsGranted)';
}

/// Schedules and cancels the on-device alarms that back each task.
///
/// Everything here runs against the operating system's alarm manager — there
/// is no server, no push, and no network access. A task's notification always
/// uses the task's own database id, so cancelling is a direct lookup.
class NotificationService {
  /// Android notification channel. Created on first use by the plugin.
  static const String channelId = 'task_reminders';
  static const String channelName = 'Task reminders';
  static const String channelDescription =
      'Alarms for tasks scheduled in ToDoIQ.';

  /// Icon used for the Android status-bar notification. Refers to the
  /// launcher icon the Flutter template already ships.
  static const String androidIcon = '@mipmap/ic_launcher';

  final FlutterLocalNotificationsPlugin _plugin;

  /// Guards against re-running time zone setup and re-initialising the plugin.
  bool _initialized = false;

  NotificationService._internal() : _plugin = FlutterLocalNotificationsPlugin();

  /// Builds a service around a caller-supplied plugin. Tests use this to
  /// inject an instance wired to a mocked method channel.
  @visibleForTesting
  NotificationService.withPlugin(this._plugin);

  static final NotificationService instance = NotificationService._internal();

  bool get isInitialized => _initialized;

  /// Loads the time zone database and initialises the plugin.
  ///
  /// Safe to call more than once; only the first call does work.
  Future<void> init() async {
    if (_initialized) return;

    configureLocalTimeZone();

    const InitializationSettings settings = InitializationSettings(
      android: AndroidInitializationSettings(androidIcon),
      iOS: DarwinInitializationSettings(
        // Permissions are requested explicitly via [requestPermissions] so the
        // prompt appears at a moment the user understands, not at cold start.
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _plugin.initialize(settings);
    _initialized = true;
  }

  /// Points `tz.local` at a zone matching the device's current UTC offset.
  ///
  /// The `timezone` package ships no way to read the device's IANA zone name,
  /// so the offset is matched against the database instead. Task alarms are
  /// one-shot and scheduled from an absolute instant, so an offset match is
  /// sufficient; only recurring rules would need the exact zone for DST.
  @visibleForTesting
  static void configureLocalTimeZone() {
    tz_data.initializeTimeZones();

    final int offsetMillis = DateTime.now().timeZoneOffset.inMilliseconds;
    for (final tz.Location location in tz.timeZoneDatabase.locations.values) {
      if (location.currentTimeZone.offset == offsetMillis) {
        tz.setLocalLocation(location);
        return;
      }
    }

    tz.setLocalLocation(tz.UTC);
  }

  /// Asks the OS for notification permission and reports the alarm situation.
  ///
  /// Safe to call at launch. On Android 13+ this shows the POST_NOTIFICATIONS
  /// dialog, which the user answers without leaving the app; on iOS it asks
  /// for alert, badge and sound. The exact-alarm state is only *read* here —
  /// granting it means being sent out to a system settings screen, which is
  /// [openExactAlarmSettings] and belongs behind a deliberate tap rather than
  /// a cold start. Platforms that gate neither return an empty result, which
  /// reads as granted.
  Future<NotificationPermissions> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final AndroidFlutterLocalNotificationsPlugin? android =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return const NotificationPermissions();

      return NotificationPermissions(
        notificationsGranted: await android.requestNotificationsPermission(),
        exactAlarmsGranted: await android.canScheduleExactNotifications(),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final IOSFlutterLocalNotificationsPlugin? ios =
          _plugin.resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      if (ios == null) return const NotificationPermissions();

      final bool? granted = await ios.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return NotificationPermissions(notificationsGranted: granted);
    }

    return const NotificationPermissions();
  }

  /// Whether the OS will currently let the app arm an exact alarm.
  ///
  /// Null where the question does not apply — iOS, and Android below 12,
  /// where exact alarms need no grant. Reading this never prompts, so it is
  /// the right call to make on resume to find out whether the user granted
  /// the permission while they were away.
  Future<bool?> canScheduleExactAlarms() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.canScheduleExactNotifications();
  }

  /// Opens the system screen that grants exact alarms, and reports the answer.
  ///
  /// This is Android's ACTION_REQUEST_SCHEDULE_EXACT_ALARM: it takes the user
  /// out of the app, so it must only ever run from an explicit tap — never
  /// from a launch path or a background check.
  Future<bool?> openExactAlarmSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestExactAlarmsPermission();
  }

  /// Schedules an exact alarm for [scheduledDate], keyed by [id].
  ///
  /// [id] is the task's database id, so a later [cancelNotification] needs
  /// nothing but the task. Returns false without scheduling when the time has
  /// already passed — the OS would otherwise fire it immediately.
  Future<bool> scheduleNotification(
    int id,
    String title,
    DateTime scheduledDate, {
    String? body,
    String? payload,
  }) async {
    final tz.TZDateTime when = tz.TZDateTime.from(scheduledDate, tz.local);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) {
      return false;
    }

    final AppStrings strings = await resolveStrings();

    await _plugin.zonedSchedule(
      id,
      title,
      body ?? defaultBody(scheduledDate, strings),
      when,
      _details(),
      // alarmClock survives Doze and is the mode intended for user-visible
      // alarms; it is what makes the reminder land on the minute.
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload ?? id.toString(),
    );
    return true;
  }

  /// Schedules whatever [task] needs: one alarm, a daily repeat, or one
  /// weekly repeat per selected day.
  ///
  /// Returns the number of alarms actually armed, so a caller can tell that a
  /// task in the past armed nothing.
  Future<int> scheduleForTask(Task task, {String? body}) async {
    final int? id = task.id;
    if (id == null) return 0;

    await cancelNotification(id);

    // Resolved per call rather than cached, so a task scheduled after a
    // language switch is worded in the language now in use.
    final AppStrings strings = await resolveStrings();
    final String text = body ?? defaultBody(task.scheduledTime, strings);

    switch (task.recurrenceType) {
      case RecurrenceType.daily:
        await _scheduleRepeating(
          id: id,
          title: task.title,
          body: text,
          when: _nextDailyOccurrence(task.scheduledTime),
          match: DateTimeComponents.time,
          payload: id.toString(),
        );
        return 1;

      case RecurrenceType.weeklyDays:
        final List<int> days = task.repeatDays ?? const <int>[];
        int armed = 0;
        for (final int weekday in days) {
          await _scheduleRepeating(
            id: weeklyNotificationId(id, weekday),
            title: task.title,
            body: text,
            when: _nextWeekdayOccurrence(task.scheduledTime, weekday),
            match: DateTimeComponents.dayOfWeekAndTime,
            payload: id.toString(),
          );
          armed++;
        }
        return armed;

      default:
        final bool scheduled = await scheduleNotification(
          id,
          task.title,
          task.scheduledTime,
          body: text,
        );
        return scheduled ? 1 : 0;
    }
  }

  /// [scheduleForTask], with failures logged instead of thrown.
  ///
  /// Returns the number of alarms armed, or null when the OS refused. Arming
  /// an alarm depends on permissions the user can revoke at any time, so it
  /// must never be able to fail the database write it belongs to — a task the
  /// app has saved but cannot remind about is still a task the user has.
  Future<int?> trySchedule(Task task, {String? body}) async {
    try {
      return await scheduleForTask(task, body: body);
    } catch (error, stack) {
      debugPrint('NotificationService: could not arm alarms for task '
          '${task.id} ("${task.title}") with ${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'NotificationService');
      return null;
    }
  }

  /// Notification id for one weekday of a weekly task.
  ///
  /// Offset into a high range so these can never collide with the plain
  /// task-id namespace used by one-off alarms.
  static int weeklyNotificationId(int taskId, int weekday) =>
      _weeklyIdBase + taskId * 8 + weekday;

  static const int _weeklyIdBase = 1000000;

  Future<void> _scheduleRepeating({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime when,
    required DateTimeComponents match,
    required String payload,
  }) {
    return _plugin.zonedSchedule(
      id,
      title,
      body,
      when,
      _details(),
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: match,
      payload: payload,
    );
  }

  /// Today at the task's time, or tomorrow if that moment has passed.
  static tz.TZDateTime _nextDailyOccurrence(DateTime scheduledTime) {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime candidate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      scheduledTime.hour,
      scheduledTime.minute,
    );
    if (!candidate.isAfter(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  /// The next occurrence of [weekday] at the task's time.
  static tz.TZDateTime _nextWeekdayOccurrence(
    DateTime scheduledTime,
    int weekday,
  ) {
    tz.TZDateTime candidate = _nextDailyOccurrence(scheduledTime);
    // At most seven hops to land on the requested weekday.
    while (candidate.weekday != weekday) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  /// Cancels every alarm belonging to task [id].
  ///
  /// Called when a task is completed, marked partial, skipped, or deleted.
  /// A weekly task owns one alarm per weekday, so all seven slots are cleared
  /// alongside the plain id. Cancelling an id with no pending alarm is a
  /// no-op, so callers do not need to check first.
  Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id);
    for (int weekday = 1; weekday <= 7; weekday++) {
      await _plugin.cancel(weeklyNotificationId(id, weekday));
    }
  }

  /// Cancels every pending alarm. Used when clearing all data.
  Future<void> cancelAll() => _plugin.cancelAll();

  /// The alarms the OS still holds, for diagnostics and tests.
  Future<List<PendingNotificationRequest>> pendingNotifications() =>
      _plugin.pendingNotificationRequests();

  NotificationDetails _details() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        playSound: true,
        enableVibration: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  /// Body text shown under the task title, in the user's language.
  ///
  /// The clock is written in plain 24-hour digits rather than through intl,
  /// because this string is baked into an alarm the OS may show days later,
  /// long after the app process is gone.
  @visibleForTesting
  static String defaultBody(DateTime scheduledDate, AppStrings strings) {
    final String hour = scheduledDate.hour.toString().padLeft(2, '0');
    final String minute = scheduledDate.minute.toString().padLeft(2, '0');
    return strings.notificationBody('$hour:$minute');
  }

  /// The strings for the language the user has selected.
  ///
  /// Read from [SettingsService] at schedule time — notification text is
  /// written once and then lives in the OS, so it has to be correct at the
  /// moment the alarm is armed.
  @visibleForTesting
  Future<AppStrings> resolveStrings() async {
    final String language = await SettingsService.instance.getLanguageCode();
    return AppStrings.forLanguage(language);
  }

  /// Re-arms every alarm for [tasks] so their text follows a language change.
  ///
  /// Pending alarms keep whatever wording they were created with, so without
  /// this a user who switches to Arabic would keep getting English reminders
  /// until each task happened to be rescheduled.
  Future<int> rescheduleAll(List<Task> tasks) async {
    int armed = 0;
    for (final Task task in tasks) {
      armed += await scheduleForTask(task);
    }
    return armed;
  }

  /// [rescheduleAll], with a refusal logged instead of thrown.
  ///
  /// Returns the number armed, or null if the OS refused partway through.
  Future<int?> tryRescheduleAll(List<Task> tasks) async {
    try {
      return await rescheduleAll(tasks);
    } catch (error, stack) {
      debugPrint('NotificationService: could not re-arm ${tasks.length} '
          'task(s) with ${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'NotificationService');
      return null;
    }
  }

  /// Resets the initialised flag. Tests only.
  @visibleForTesting
  void resetForTesting() {
    _initialized = false;
  }
}
