/// The four states a task can occupy.
///
/// A task starts as [pending] and moves to exactly one terminal state.
class TaskStatus {
  static const String pending = 'pending';
  static const String completed = 'completed';
  static const String partial = 'partial';
  static const String skipped = 'skipped';

  /// Every valid status value, in the order they are surfaced in the UI.
  static const List<String> values = <String>[
    pending,
    completed,
    partial,
    skipped,
  ];

  static bool isValid(String status) => values.contains(status);

  const TaskStatus._();
}

/// How often a task repeats.
class RecurrenceType {
  /// Fires once, on its scheduled date.
  static const String none = 'none';

  /// Every day from its scheduled date onwards.
  static const String daily = 'daily';

  /// On the weekdays listed in [Task.repeatDays].
  static const String weeklyDays = 'weekly_days';

  static const List<String> values = <String>[none, daily, weeklyDays];

  static bool isValid(String value) => values.contains(value);

  const RecurrenceType._();
}

/// A single scheduled to-do item.
///
/// Persisted in the `tasks` table. [id] is null until the row is inserted,
/// after which SQLite assigns the autoincrement primary key.
class Task {
  final int? id;
  final String title;
  final DateTime scheduledTime;
  final String status;
  final DateTime createdAt;

  /// Why the task ended up partial or skipped, in the user's words.
  ///
  /// Optional and null for most tasks. It is the only place the app records
  /// *why* something did not get finished, so it is what gives the AI
  /// debrief and coach something real to reason about.
  final String? note;

  /// One of [RecurrenceType]. A recurring task is a single row that surfaces
  /// on every matching day rather than a row per occurrence.
  final String recurrenceType;

  /// Weekdays this task repeats on, 1 (Monday) to 7 (Sunday). Only meaningful
  /// for [RecurrenceType.weeklyDays]; null otherwise.
  final List<int>? repeatDays;

  /// The day [status] and [note] were recorded for.
  ///
  /// A recurring task carries one status field, so without this a task marked
  /// done today would still read as done tomorrow. Occurrences on other days
  /// fall back to pending.
  final DateTime? statusDate;

  Task({
    this.id,
    required this.title,
    required this.scheduledTime,
    this.status = TaskStatus.pending,
    DateTime? createdAt,
    this.note,
    this.recurrenceType = RecurrenceType.none,
    this.repeatDays,
    this.statusDate,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Serialises to the column layout of the `tasks` table.
  ///
  /// Dates are stored as millisecond epochs so range queries stay numeric.
  /// [id] is omitted when null so SQLite can assign one on insert.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      if (id != null) 'id': id,
      'title': title,
      'scheduled_time': scheduledTime.millisecondsSinceEpoch,
      'status': status,
      'created_at': createdAt.millisecondsSinceEpoch,
      'note': note,
      'recurrence_type': recurrenceType,
      'repeat_days': encodeRepeatDays(repeatDays),
      'status_date': statusDate == null
          ? null
          : dayStart(statusDate!).millisecondsSinceEpoch,
    };
  }

  factory Task.fromMap(Map<String, Object?> map) {
    return Task(
      id: map['id'] as int?,
      title: map['title'] as String,
      scheduledTime: DateTime.fromMillisecondsSinceEpoch(
        map['scheduled_time'] as int,
      ),
      status: map['status'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      note: map['note'] as String?,
      recurrenceType:
          (map['recurrence_type'] as String?) ?? RecurrenceType.none,
      repeatDays: decodeRepeatDays(map['repeat_days'] as String?),
      statusDate: map['status_date'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['status_date'] as int),
    );
  }

  /// Pass [clearNote] to drop an existing note; passing `note: null` alone
  /// keeps it, so callers cannot erase one by omission.
  Task copyWith({
    int? id,
    String? title,
    DateTime? scheduledTime,
    String? status,
    DateTime? createdAt,
    String? note,
    bool clearNote = false,
    String? recurrenceType,
    List<int>? repeatDays,
    bool clearRepeatDays = false,
    DateTime? statusDate,
    bool clearStatusDate = false,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      note: clearNote ? null : (note ?? this.note),
      recurrenceType: recurrenceType ?? this.recurrenceType,
      repeatDays:
          clearRepeatDays ? null : (repeatDays ?? this.repeatDays),
      statusDate:
          clearStatusDate ? null : (statusDate ?? this.statusDate),
    );
  }

  // --- Recurrence ---------------------------------------------------------

  bool get isRecurring => recurrenceType != RecurrenceType.none;

  bool get isDaily => recurrenceType == RecurrenceType.daily;

  bool get isWeekly => recurrenceType == RecurrenceType.weeklyDays;

  /// The first day this task can appear on.
  DateTime get startDay => dayStart(scheduledTime);

  /// Whether this task belongs on [day].
  ///
  /// A one-off matches only its own date. A recurring task matches every day
  /// from its start date onwards that fits its pattern — never before, so
  /// adding a weekly task does not retroactively fill in past weeks.
  bool occursOn(DateTime day) {
    final DateTime target = dayStart(day);
    if (target.isBefore(startDay)) return false;

    switch (recurrenceType) {
      case RecurrenceType.daily:
        return true;
      case RecurrenceType.weeklyDays:
        final List<int> days = repeatDays ?? const <int>[];
        return days.contains(target.weekday);
      default:
        return target == startDay;
    }
  }

  /// The scheduled instant for this task's occurrence on [day].
  DateTime occurrenceOn(DateTime day) {
    final DateTime target = dayStart(day);
    return DateTime(
      target.year,
      target.month,
      target.day,
      scheduledTime.hour,
      scheduledTime.minute,
    );
  }

  /// The status this task shows on [day].
  ///
  /// Stored status only counts for the day it was recorded against; every
  /// other occurrence of a recurring task reads as pending.
  String statusOn(DateTime day) {
    if (!isRecurring) return status;
    if (statusDate == null) return TaskStatus.pending;
    return dayStart(statusDate!) == dayStart(day)
        ? status
        : TaskStatus.pending;
  }

  /// The note recorded for [day], if the stored one belongs to it.
  String? noteOn(DateTime day) {
    if (!isRecurring) return note;
    if (statusDate == null) return null;
    return dayStart(statusDate!) == dayStart(day) ? note : null;
  }

  // --- Serialisation helpers ---------------------------------------------

  static DateTime dayStart(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// Weekdays as a sorted, deduplicated `"1,3,5"` string, or null when empty.
  static String? encodeRepeatDays(List<int>? days) {
    if (days == null || days.isEmpty) return null;
    final List<int> valid =
        days.where((int d) => d >= 1 && d <= 7).toSet().toList()..sort();
    if (valid.isEmpty) return null;
    return valid.join(',');
  }

  /// Parses `"1,3,5"`. Unparseable or out-of-range entries are dropped rather
  /// than thrown, so a corrupt row degrades to a non-repeating task.
  static List<int>? decodeRepeatDays(String? encoded) {
    if (encoded == null || encoded.trim().isEmpty) return null;
    final List<int> days = <int>[];
    for (final String part in encoded.split(',')) {
      final int? value = int.tryParse(part.trim());
      if (value != null && value >= 1 && value <= 7) days.add(value);
    }
    if (days.isEmpty) return null;
    final List<int> unique = days.toSet().toList()..sort();
    return unique;
  }

  bool get isPending => status == TaskStatus.pending;

  /// True when the user recorded a reason worth showing.
  bool get hasNote => note != null && note!.trim().isNotEmpty;

  @override
  String toString() =>
      'Task(id: $id, title: $title, scheduledTime: $scheduledTime, '
      'status: $status, createdAt: $createdAt, note: $note, '
      'recurrence: $recurrenceType, repeatDays: $repeatDays)';
}
