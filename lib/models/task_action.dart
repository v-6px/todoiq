import 'dart:convert';

import 'task_model.dart';

/// A task the coach proposed, parsed out of its reply.
///
/// The model is asked to append a fenced ```task_action block holding JSON
/// whenever the user asks for something to be scheduled. This is the
/// validated form of that block: anything the model got wrong — an unknown
/// recurrence, a weekly repeat with no days, a missing time — is corrected
/// here rather than surfaced, so a sloppy block still lands as a sensible
/// task instead of an error the user has to decode.
class TaskAction {
  final String title;
  final DateTime scheduledTime;
  final String recurrenceType;
  final List<int>? repeatDays;

  const TaskAction({
    required this.title,
    required this.scheduledTime,
    this.recurrenceType = RecurrenceType.none,
    this.repeatDays,
  });

  bool get isRecurring => recurrenceType != RecurrenceType.none;

  /// The row to insert. No id — SQLite assigns one.
  Task toTask() => Task(
        title: title,
        scheduledTime: scheduledTime,
        recurrenceType: recurrenceType,
        repeatDays: recurrenceType == RecurrenceType.weeklyDays
            ? repeatDays
            : null,
      );

  /// Reads one action block's JSON body.
  ///
  /// Returns null only when there is no usable title — everything else has a
  /// defensible fallback, because half a task the user can see and confirm
  /// beats silently dropping the request.
  static TaskAction? tryParse(String source, {DateTime? now}) {
    final Map<String, Object?>? json = _decodeObject(source);
    if (json == null) return null;

    final String title = json['title']?.toString().trim() ?? '';
    if (title.isEmpty) return null;

    final DateTime today = now ?? DateTime.now();
    final DateTime day = _parseDate(json['date'], today);
    final List<int> clock = _parseTime(json['time']);
    final DateTime scheduled =
        DateTime(day.year, day.month, day.day, clock[0], clock[1]);

    final String recurrence = _parseRecurrence(json['recurrence']);
    List<int>? days;
    if (recurrence == RecurrenceType.weeklyDays) {
      days = _parseDays(json['days']);
      // A weekly repeat with no days would never fire; anchor it to the day
      // the model picked, which is the one it clearly had in mind.
      days ??= <int>[scheduled.weekday];
    }

    return TaskAction(
      title: title,
      scheduledTime: scheduled,
      recurrenceType: recurrence,
      repeatDays: days,
    );
  }

  /// Decodes the first `{...}` in [source].
  ///
  /// Sliced rather than decoded whole because models like to wrap the object
  /// in a stray sentence or a second fence.
  static Map<String, Object?>? _decodeObject(String source) {
    final int start = source.indexOf('{');
    final int end = source.lastIndexOf('}');
    if (start == -1 || end <= start) return null;
    try {
      final Object? decoded = jsonDecode(source.substring(start, end + 1));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static DateTime _parseDate(Object? value, DateTime fallback) {
    final String text = value?.toString().trim() ?? '';
    final DateTime? parsed = DateTime.tryParse(text);
    if (parsed == null) return Task.dayStart(fallback);
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// `"HH:mm"` as `[hour, minute]`, defaulting to 09:00.
  static List<int> _parseTime(Object? value) {
    final String text = value?.toString().trim() ?? '';
    final List<String> parts = text.split(':');
    if (parts.length < 2) return const <int>[9, 0];
    final int? hour = int.tryParse(parts[0].trim());
    final int? minute = int.tryParse(parts[1].trim());
    if (hour == null || minute == null) return const <int>[9, 0];
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return const <int>[9, 0];
    }
    return <int>[hour, minute];
  }

  static String _parseRecurrence(Object? value) {
    switch (value?.toString().trim().toLowerCase()) {
      case 'daily':
        return RecurrenceType.daily;
      case 'weekly':
      case 'weekly_days':
        return RecurrenceType.weeklyDays;
      default:
        return RecurrenceType.none;
    }
  }

  static List<int>? _parseDays(Object? value) {
    if (value is! List) return null;
    final List<int> days = <int>[];
    for (final Object? entry in value) {
      final int? day =
          entry is int ? entry : int.tryParse(entry?.toString().trim() ?? '');
      if (day != null && day >= 1 && day <= 7) days.add(day);
    }
    if (days.isEmpty) return null;
    return days.toSet().toList()..sort();
  }

  @override
  String toString() => 'TaskAction($title, $scheduledTime, $recurrenceType, '
      '$repeatDays)';
}

/// An assistant reply split into the prose the user reads and the action the
/// coach attached to it.
class CoachReply {
  /// The reply with the action block removed. This is what gets rendered.
  final String text;

  final TaskAction? action;

  const CoachReply({required this.text, this.action});

  bool get hasAction => action != null;

  /// Matches the fenced block. The closing fence is optional so a reply the
  /// provider truncated mid-block still gets stripped rather than shown raw.
  static final RegExp _blockPattern = RegExp(
    r'```[ \t]*task_action[ \t]*\r?\n?(.*?)(?:```|$)',
    dotAll: true,
    caseSensitive: false,
  );

  static CoachReply parse(String content, {DateTime? now}) {
    final RegExpMatch? match = _blockPattern.firstMatch(content);
    if (match == null) return CoachReply(text: content);

    final String stripped =
        content.replaceRange(match.start, match.end, '').trim();

    return CoachReply(
      // May be empty when the model replied with nothing but the block; the
      // bubble then shows the card alone rather than the raw JSON.
      text: stripped,
      action: TaskAction.tryParse(match.group(1) ?? '', now: now),
    );
  }
}
