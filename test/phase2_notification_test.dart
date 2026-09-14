import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/services/notification_service.dart';
import 'package:todo_list/services/settings_service.dart';

/// The channel flutter_local_notifications talks to. Mocking it lets the real
/// plugin code run end to end while the "OS" side is captured in memory.
const MethodChannel _channel =
    MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every call the service made, in order.
  final List<MethodCall> calls = <MethodCall>[];

  /// Values the fake OS returns from the permission requests.
  bool? notificationsPermissionResult;
  bool? exactAlarmsPermissionResult;

  /// Alarms the fake OS is currently holding, keyed by notification id.
  final Map<int, Map<Object?, Object?>> pending =
      <int, Map<Object?, Object?>>{};

  late NotificationService service;

  /// Makes the fake OS refuse anything but an inexact alarm at arming time,
  /// the way a device does when the permission was revoked after the check.
  bool refuseExactAlarmOnSchedule = false;

  setUp(() {
    calls.clear();
    pending.clear();
    refuseExactAlarmOnSchedule = false;

    // Scheduling reads the UI language to word the notification body, so a
    // preference store has to exist. Pinned to English so the body assertions
    // below do not depend on the host's locale.
    SharedPreferences.setMockInitialValues(
      <String, Object>{'language_code': 'en'},
    );
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();
    notificationsPermissionResult = true;
    exactAlarmsPermissionResult = true;

    // The plugin dispatches on defaultTargetPlatform, so tests must declare
    // which platform they are standing in for.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'requestNotificationsPermission':
          return notificationsPermissionResult;
        case 'requestExactAlarmsPermission':
          return exactAlarmsPermissionResult;
        case 'canScheduleExactNotifications':
          return exactAlarmsPermissionResult;
        case 'requestPermissions': // iOS
          return notificationsPermissionResult;
        case 'zonedSchedule':
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          final Map<Object?, Object?> specifics =
              (args['platformSpecifics'] ?? <Object?, Object?>{})
                  as Map<Object?, Object?>;
          if (refuseExactAlarmOnSchedule &&
              specifics['scheduleMode'] != AndroidScheduleMode.inexact.name) {
            throw PlatformException(
              code: 'exact_alarms_not_permitted',
              message: 'Exact alarms are not permitted',
            );
          }
          pending[args['id']! as int] = args;
          return null;
        case 'cancel':
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          pending.remove(args['id']);
          return null;
        case 'cancelAll':
          pending.clear();
          return null;
        case 'pendingNotificationRequests':
          return pending.values
              .map((Map<Object?, Object?> a) => <String, Object?>{
                    'id': a['id'],
                    'title': a['title'],
                    'body': a['body'],
                    'payload': a['payload'],
                  })
              .toList();
        default:
          return null;
      }
    });

    service = NotificationService.withPlugin(FlutterLocalNotificationsPlugin());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  /// Method names seen so far, for order-independent assertions.
  List<String> methodNames() =>
      calls.map((MethodCall c) => c.method).toList(growable: false);

  group('Time zone setup', () {
    test('initializes the database and picks a zone for the device offset', () {
      NotificationService.configureLocalTimeZone();

      // A non-empty database proves initializeTimeZones ran.
      expect(tz.timeZoneDatabase.locations, isNotEmpty);
      expect(
        tz.local.currentTimeZone.offset,
        DateTime.now().timeZoneOffset.inMilliseconds,
      );
    });

    test('TZDateTime.from preserves the absolute instant', () {
      NotificationService.configureLocalTimeZone();

      final DateTime local = DateTime.now().add(const Duration(hours: 3));
      final tz.TZDateTime converted = tz.TZDateTime.from(local, tz.local);

      expect(
        converted.millisecondsSinceEpoch,
        local.millisecondsSinceEpoch,
      );
    });
  });

  group('init', () {
    test('initializes the plugin exactly once', () async {
      expect(service.isInitialized, isFalse);

      await service.init();
      expect(service.isInitialized, isTrue);
      expect(methodNames(), contains('initialize'));

      final int callsAfterFirst = calls.length;
      await service.init();

      expect(calls.length, callsAfterFirst,
          reason: 'a second init() should do no work');
    });
  });

  /// The mode the fake OS was handed for alarm [id].
  String? scheduleModeOf(int id) {
    final Map<Object?, Object?> specifics =
        pending[id]!['platformSpecifics']! as Map<Object?, Object?>;
    return specifics['scheduleMode'] as String?;
  }

  group('Exact alarm fallback', () {
    test('the precise mode is used when the OS allows it', () async {
      exactAlarmsPermissionResult = true;

      expect(
        await service.resolveScheduleMode(),
        AndroidScheduleMode.alarmClock,
      );
    });

    test('a refusal drops to inexact rather than failing', () async {
      // The alternative is an exception and no reminder at all. A few minutes
      // late beats never.
      exactAlarmsPermissionResult = false;

      expect(
        await service.resolveScheduleMode(),
        AndroidScheduleMode.inexact,
      );
    });

    test('an unknown answer keeps the precise mode', () async {
      // Android below 12 answers null: exact alarms need no grant there, so
      // an unknown must never be read as a refusal.
      exactAlarmsPermissionResult = null;

      expect(
        await service.resolveScheduleMode(),
        AndroidScheduleMode.alarmClock,
      );
    });

    test('a task scheduled without the permission still arms an alarm',
        () async {
      exactAlarmsPermissionResult = false;

      final int armed = await service.scheduleForTask(Task(
        id: 31,
        title: 'Dentist',
        scheduledTime: DateTime.now().add(const Duration(days: 1)),
      ));

      expect(armed, 1, reason: 'the reminder is still set');
      expect(pending, hasLength(1));
      expect(scheduleModeOf(31), AndroidScheduleMode.inexact.name);
    });

    test('an OS that refuses at the last moment is retried inexactly',
        () async {
      // The permission can be revoked between the check and the call, and
      // some ROMs refuse whatever the check said.
      exactAlarmsPermissionResult = true;
      refuseExactAlarmOnSchedule = true;

      final int armed = await service.scheduleForTask(Task(
        id: 32,
        title: 'Dentist',
        scheduledTime: DateTime.now().add(const Duration(days: 1)),
      ));

      expect(armed, 1);
      expect(
        scheduleModeOf(32),
        AndroidScheduleMode.inexact.name,
        reason: 'the retry is what stops this surfacing as a failed save',
      );
    });

    test('every weekday of a weekly task falls back together', () async {
      exactAlarmsPermissionResult = false;

      final int armed = await service.scheduleForTask(Task(
        id: 33,
        title: 'Gym',
        scheduledTime: DateTime.now().add(const Duration(days: 1)),
        recurrenceType: RecurrenceType.weeklyDays,
        repeatDays: <int>[1, 3, 5],
      ));

      expect(armed, 3);
      for (final int id in pending.keys) {
        expect(scheduleModeOf(id), AndroidScheduleMode.inexact.name);
      }
    });
  });

  group('Notification channel', () {
    test('alarms are configured to interrupt, not to sit in the shade',
        () async {
      await service.scheduleNotification(
        41,
        'Dentist',
        DateTime.now().add(const Duration(days: 1)),
      );

      final Map<Object?, Object?> details =
          pending[41]!['platformSpecifics']! as Map<Object?, Object?>;

      // Importance fixes the channel's ceiling at creation and cannot be
      // raised later; priority decides how this notification shows within it.
      // Anything less and a task alarm arrives silently.
      expect(details['importance'], Importance.max.value);
      expect(details['priority'], Priority.high.value);
      expect(details['channelId'], NotificationService.channelId);
    });
  });

  group('requestPermissions', () {
    test('prompts for notifications but only reads the alarm state', () async {
      final NotificationPermissions result = await service.requestPermissions();

      expect(methodNames(), containsAll(<String>[
        'requestNotificationsPermission',
        'canScheduleExactNotifications',
      ]));

      // Asking for exact alarms navigates out to a settings screen. Doing
      // that at launch would throw the user out of the app before they have
      // seen it, so the launch path must only ever check.
      expect(
        methodNames(),
        isNot(contains('requestExactAlarmsPermission')),
      );

      expect(result.notificationsGranted, isTrue);
      expect(result.exactAlarmsGranted, isTrue);
      expect(result.isFullyGranted, isTrue);
    });

    test('the alarm check is readable on its own and never prompts', () async {
      exactAlarmsPermissionResult = false;

      expect(await service.canScheduleExactAlarms(), isFalse);
      expect(
        methodNames(),
        isNot(contains('requestExactAlarmsPermission')),
      );
    });

    test('opening the settings screen is what asks for exact alarms', () async {
      expect(await service.openExactAlarmSettings(), isTrue);
      expect(methodNames(), contains('requestExactAlarmsPermission'));
    });

    test('neither alarm call reaches a non-Android platform', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      final NotificationService ios =
          NotificationService.withPlugin(FlutterLocalNotificationsPlugin());

      expect(await ios.canScheduleExactAlarms(), isNull);
      expect(await ios.openExactAlarmSettings(), isNull);
      expect(
        methodNames(),
        isNot(contains('requestExactAlarmsPermission')),
      );
    });

    test('reports a denied notification permission', () async {
      notificationsPermissionResult = false;

      final NotificationPermissions result = await service.requestPermissions();

      expect(result.notificationsGranted, isFalse);
      expect(result.isFullyGranted, isFalse);
    });

    test('reports denied exact alarms separately', () async {
      exactAlarmsPermissionResult = false;

      final NotificationPermissions result = await service.requestPermissions();

      expect(result.notificationsGranted, isTrue);
      expect(result.exactAlarmsGranted, isFalse);
      expect(result.isFullyGranted, isFalse);
    });

    test('an unknown result is not treated as a denial', () {
      const NotificationPermissions unknown = NotificationPermissions();
      expect(unknown.isFullyGranted, isTrue);
    });

    test('asks iOS for alert, badge and sound in one prompt', () async {
      // iOS has no separate exact-alarm permission, so the service must ask
      // once and leave exactAlarmsGranted unknown rather than false.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      final NotificationService iosService =
          NotificationService.withPlugin(FlutterLocalNotificationsPlugin());

      final NotificationPermissions result =
          await iosService.requestPermissions();

      final MethodCall request = calls.singleWhere(
          (MethodCall c) => c.method == 'requestPermissions');
      final Map<Object?, Object?> args =
          request.arguments as Map<Object?, Object?>;
      expect(args['alert'], isTrue);
      expect(args['badge'], isTrue);
      expect(args['sound'], isTrue);

      expect(result.notificationsGranted, isTrue);
      expect(result.exactAlarmsGranted, isNull);
      expect(result.isFullyGranted, isTrue);
    });
  });

  group('scheduleNotification', () {
    setUp(() async {
      await service.init();
      calls.clear();
    });

    test('schedules a future alarm and reports success', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 2));

      final bool scheduled =
          await service.scheduleNotification(42, 'Write the report', when);

      expect(scheduled, isTrue);
      expect(methodNames(), contains('zonedSchedule'));
      expect(pending.keys, <int>[42]);
      expect(pending[42]!['title'], 'Write the report');
    });

    test('keys the alarm by the task id so cancelling needs only the id',
        () async {
      final DateTime when = DateTime.now().add(const Duration(minutes: 30));

      await service.scheduleNotification(7, 'Task seven', when);

      expect(pending[7]!['id'], 7);
      expect(pending[7]!['payload'], '7');
    });

    test('refuses a time in the past without calling the platform', () async {
      final DateTime past = DateTime.now().subtract(const Duration(minutes: 1));

      final bool scheduled =
          await service.scheduleNotification(1, 'Already missed', past);

      expect(scheduled, isFalse);
      expect(methodNames(), isNot(contains('zonedSchedule')));
      expect(pending, isEmpty);
    });

    test('refuses the current instant', () async {
      final bool scheduled =
          await service.scheduleNotification(2, 'Right now', DateTime.now());

      expect(scheduled, isFalse);
      expect(pending, isEmpty);
    });

    test('schedules at the exact requested instant', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 5));

      await service.scheduleNotification(3, 'Precise', when);

      // The plugin sends the instant as ISO-8601 plus the zone name; parsing
      // it back must land on the same moment the caller asked for.
      final String iso = pending[3]!['scheduledDateTimeISO8601']! as String;
      expect(
        DateTime.parse(iso).millisecondsSinceEpoch,
        when.millisecondsSinceEpoch,
      );
      expect(pending[3]!['timeZoneName'], tz.local.name);
    });

    test('uses alarmClock mode so Doze cannot defer the reminder', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 1));

      await service.scheduleNotification(4, 'Exact', when);

      final Map<Object?, Object?> specifics =
          pending[4]!['platformSpecifics']! as Map<Object?, Object?>;
      expect(specifics['scheduleMode'], AndroidScheduleMode.alarmClock.name);
    });

    test('requests a max-importance alarm-category notification', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 1));

      await service.scheduleNotification(8, 'Loud', when);

      final Map<Object?, Object?> specifics =
          pending[8]!['platformSpecifics']! as Map<Object?, Object?>;
      expect(specifics['channelId'], NotificationService.channelId);
      expect(specifics['importance'], Importance.max.value);
      expect(specifics['priority'], Priority.high.value);
      expect(specifics['category'], AndroidNotificationCategory.alarm.name);
    });

    test('derives a body from the scheduled time when none is given', () async {
      final DateTime when = DateTime.now().add(const Duration(days: 1));
      final String expected = 'Scheduled for '
          '${when.hour.toString().padLeft(2, '0')}:'
          '${when.minute.toString().padLeft(2, '0')}';

      await service.scheduleNotification(5, 'Auto body', when);

      expect(pending[5]!['body'], expected);
    });

    test('honours an explicit body and payload', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 4));

      await service.scheduleNotification(
        6,
        'Custom',
        when,
        body: 'Bring the slides',
        payload: 'task:6',
      );

      expect(pending[6]!['body'], 'Bring the slides');
      expect(pending[6]!['payload'], 'task:6');
    });

    test('rescheduling the same id replaces the pending alarm', () async {
      final DateTime first = DateTime.now().add(const Duration(hours: 1));
      final DateTime second = DateTime.now().add(const Duration(hours: 6));

      await service.scheduleNotification(9, 'Original', first);
      await service.scheduleNotification(9, 'Moved', second);

      expect(pending, hasLength(1));
      expect(pending[9]!['title'], 'Moved');
    });
  });

  group('cancelNotification', () {
    setUp(() async {
      await service.init();
      calls.clear();
    });

    test('cancels the alarm for one task and leaves the others', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 3));
      await service.scheduleNotification(10, 'Keep', when);
      await service.scheduleNotification(11, 'Drop', when);

      await service.cancelNotification(11);

      expect(pending.keys, <int>[10]);
      expect(methodNames(), contains('cancel'));
    });

    test('cancelling an unknown id is a harmless no-op', () async {
      await service.cancelNotification(999);

      expect(pending, isEmpty);
      expect(methodNames(), contains('cancel'));
    });

    test('covers the whole done/partial/skipped path', () async {
      // Each terminal status cancels the alarm the same way; this is the
      // contract the task card relies on in Phase 3.
      final DateTime when = DateTime.now().add(const Duration(hours: 2));
      for (final int id in <int>[21, 22, 23]) {
        await service.scheduleNotification(id, 'Task $id', when);
      }
      expect(pending, hasLength(3));

      for (final int id in <int>[21, 22, 23]) {
        await service.cancelNotification(id);
      }

      expect(pending, isEmpty);
    });

    test('cancelAll clears every pending alarm', () async {
      final DateTime when = DateTime.now().add(const Duration(hours: 2));
      await service.scheduleNotification(31, 'One', when);
      await service.scheduleNotification(32, 'Two', when);

      await service.cancelAll();

      expect(pending, isEmpty);
      expect(methodNames(), contains('cancelAll'));
    });
  });

  group('pendingNotifications', () {
    test('reads back what was scheduled', () async {
      await service.init();
      final DateTime when = DateTime.now().add(const Duration(hours: 2));
      await service.scheduleNotification(51, 'Pending one', when);
      await service.scheduleNotification(52, 'Pending two', when);

      final List<PendingNotificationRequest> requests =
          await service.pendingNotifications();

      expect(requests.map((PendingNotificationRequest r) => r.id), <int>[51, 52]);
      expect(requests.first.title, 'Pending one');
    });
  });
}
