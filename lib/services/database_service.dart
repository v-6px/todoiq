import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/saved_report.dart';
import '../models/task_model.dart';

/// Owns the on-device SQLite database.
///
/// Everything here is local-first: no network access, no sync. The singleton
/// holds one lazily-opened [Database] handle for the life of the process.
class DatabaseService {
  static const String _databaseName = 'task_master.db';
  static const int _databaseVersion = 4;

  static const String tasksTable = 'tasks';
  static const String reportsTable = 'reports';

  /// How many debriefs to keep per range.
  ///
  /// Only the newest is ever shown, but a handful of older ones cost almost
  /// nothing and leave room for a history view later. The cap is what stops
  /// the table growing without bound on a heavily used install.
  static const int reportsKeptPerPeriod = 5;

  /// Overrides the database file name.
  ///
  /// Tests only. `flutter test` runs each file in its own isolate, in
  /// parallel, so two files sharing one SQLite file deadlock with
  /// "database is locked". Each test file claims its own name instead.
  @visibleForTesting
  static String? debugDatabaseName;

  DatabaseService._internal();

  static final DatabaseService instance = DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    return _database ??= await _open();
  }

  Future<Database> _open() async {
    final String databasesPath = await getDatabasesPath();
    final String path =
        p.join(databasesPath, debugDatabaseName ?? _databaseName);

    return openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tasksTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        scheduled_time INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT '${TaskStatus.pending}',
        created_at INTEGER NOT NULL,
        note TEXT,
        recurrence_type TEXT NOT NULL DEFAULT '${RecurrenceType.none}',
        repeat_days TEXT,
        status_date INTEGER
      )
    ''');

    // Every read path either filters or orders by scheduled_time.
    await db.execute(
      'CREATE INDEX idx_tasks_scheduled_time ON $tasksTable (scheduled_time)',
    );

    await _createReportsTable(db);
  }

  /// Saved debriefs. Separate from tasks: a report is a snapshot of what the
  /// model said at a moment, and must not change when a task later does.
  Future<void> _createReportsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $reportsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        period_type TEXT NOT NULL,
        content_markdown TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    // The only query is "newest for this period".
    await db.execute(
      'CREATE INDEX idx_reports_period ON $reportsTable '
      '(period_type, created_at DESC)',
    );
  }

  /// Migrates an existing install forward.
  ///
  /// Each step is additive and nullable, so an upgrade never touches the rows
  /// already on the device — existing tasks simply gain a null note.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE $tasksTable ADD COLUMN note TEXT');
    }
    if (oldVersion < 3) {
      // Existing rows become one-off tasks, which is exactly what they were.
      await db.execute(
        'ALTER TABLE $tasksTable ADD COLUMN recurrence_type TEXT '
        "NOT NULL DEFAULT '${RecurrenceType.none}'",
      );
      await db.execute(
        'ALTER TABLE $tasksTable ADD COLUMN repeat_days TEXT',
      );
      await db.execute(
        'ALTER TABLE $tasksTable ADD COLUMN status_date INTEGER',
      );
    }
    if (oldVersion < 4) {
      // Purely additive: existing installs gain an empty report history.
      await _createReportsTable(db);
    }
  }

  // --- CRUD ---------------------------------------------------------------

  /// Inserts [task] and returns the row id SQLite assigned.
  Future<int> insertTask(Task task) async {
    final Database db = await database;
    return db.insert(tasksTable, task.toMap());
  }

  /// Everything that belongs on the calendar day containing [date].
  ///
  /// That is one-off tasks dated that day, plus every recurring task whose
  /// pattern matches it. Recurring rows are matched in Dart rather than SQL:
  /// there are few of them, and weekday-set matching in SQL would mean string
  /// tricks on `repeat_days`.
  Future<List<Task>> getTasksForDate(DateTime date) async {
    final DateTime start = DateTime(date.year, date.month, date.day);
    final DateTime end = start.add(const Duration(days: 1));
    final Database db = await database;

    final List<Map<String, Object?>> oneOff = await db.query(
      tasksTable,
      where: 'recurrence_type = ? AND scheduled_time >= ? '
          'AND scheduled_time < ?',
      whereArgs: <Object?>[
        RecurrenceType.none,
        start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch,
      ],
    );

    final List<Map<String, Object?>> recurring = await db.query(
      tasksTable,
      where: 'recurrence_type != ? AND scheduled_time < ?',
      whereArgs: <Object?>[
        RecurrenceType.none,
        end.millisecondsSinceEpoch,
      ],
    );

    final List<Task> tasks = <Task>[
      ...oneOff.map(Task.fromMap),
      ...recurring.map(Task.fromMap).where((Task t) => t.occursOn(start)),
    ];

    // Order by time of day, so a recurring task sits where it belongs in the
    // timeline rather than by its original start date.
    tasks.sort((Task a, Task b) {
      final int byTime = _minutesOfDay(a).compareTo(_minutesOfDay(b));
      if (byTime != 0) return byTime;
      return (a.id ?? 0).compareTo(b.id ?? 0);
    });
    return tasks;
  }

  static int _minutesOfDay(Task task) =>
      task.scheduledTime.hour * 60 + task.scheduledTime.minute;

  /// Every task that belongs on any day in `[start, end)`, occurrence by
  /// occurrence, ordered chronologically.
  ///
  /// A recurring task appears once per matching day, each carrying that day's
  /// own status — which is what the debrief needs to reason about.
  Future<List<Task>> getOccurrencesBetween(
    DateTime start,
    DateTime end,
  ) async {
    final List<Task> occurrences = <Task>[];
    DateTime day = DateTime(start.year, start.month, start.day);
    final DateTime last = DateTime(end.year, end.month, end.day);

    while (day.isBefore(last)) {
      for (final Task task in await getTasksForDate(day)) {
        occurrences.add(
          task.copyWith(
            scheduledTime: task.occurrenceOn(day),
            status: task.statusOn(day),
            note: task.noteOn(day),
            clearNote: task.noteOn(day) == null,
          ),
        );
      }
      day = day.add(const Duration(days: 1));
    }
    return occurrences;
  }

  /// All tasks scheduled in `[start, end)`, oldest first.
  Future<List<Task>> getTasksBetween(DateTime start, DateTime end) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      tasksTable,
      where: 'scheduled_time >= ? AND scheduled_time < ?',
      whereArgs: <Object?>[
        start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch,
      ],
      orderBy: 'scheduled_time ASC',
    );
    return rows.map(Task.fromMap).toList();
  }

  Future<Task?> getTaskById(int id) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      tasksTable,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Task.fromMap(rows.first);
  }

  /// Moves task [id] to [status]. Returns the number of rows changed.
  Future<int> updateStatus(int id, String status) async {
    assert(TaskStatus.isValid(status), 'Unknown task status: $status');
    final Database db = await database;
    return db.update(
      tasksTable,
      <String, Object?>{'status': status},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Moves task [id] to [status] and records [note] as the reason.
  ///
  /// A null [note] clears any previous one, which is what returning a task to
  /// pending should do — the old reason no longer applies.
  /// [forDate] records which day the status belongs to, which is what keeps a
  /// recurring task's completion from leaking into tomorrow. Defaults to the
  /// task's own scheduled day for one-off tasks.
  Future<int> updateStatusWithNote(
    int id,
    String status,
    String? note, {
    DateTime? forDate,
  }) async {
    assert(TaskStatus.isValid(status), 'Unknown task status: $status');
    final String? trimmed =
        (note == null || note.trim().isEmpty) ? null : note.trim();

    final Database db = await database;
    final Map<String, Object?> values = <String, Object?>{
      'status': status,
      'note': trimmed,
    };
    if (forDate != null) {
      values['status_date'] =
          Task.dayStart(forDate).millisecondsSinceEpoch;
    }

    return db.update(
      tasksTable,
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Replaces the stored row for [task]. Requires a non-null [Task.id].
  Future<int> updateTask(Task task) async {
    final int? id = task.id;
    if (id == null) {
      throw ArgumentError('Cannot update a task that has no id.');
    }
    final Database db = await database;
    return db.update(
      tasksTable,
      task.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<int> deleteTask(int id) async {
    final Database db = await database;
    return db.delete(tasksTable, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// Tasks that may still have a live alarm: every recurring task, plus
  /// pending one-offs from [from] onwards.
  ///
  /// Used to re-arm alarms after something that changes their text, such as a
  /// language switch.
  Future<List<Task>> getTasksWithLiveAlarms({DateTime? from}) async {
    final DateTime cutoff = from ?? DateTime.now();
    final Database db = await database;

    final List<Map<String, Object?>> rows = await db.query(
      tasksTable,
      where: 'recurrence_type != ? OR (status = ? AND scheduled_time >= ?)',
      whereArgs: <Object?>[
        RecurrenceType.none,
        TaskStatus.pending,
        cutoff.millisecondsSinceEpoch,
      ],
    );
    return rows.map(Task.fromMap).toList();
  }

  /// Counts each status across every occurrence in `[start, end)`.
  ///
  /// Statuses with no rows are present with a count of 0, so callers can read
  /// every badge without null checks.
  Future<Map<String, int>> getStatusCounts(
    DateTime start,
    DateTime end,
  ) async {
    final Map<String, int> counts = <String, int>{
      for (final String status in TaskStatus.values) status: 0,
    };

    for (final Task occurrence in await getOccurrencesBetween(start, end)) {
      counts[occurrence.status] = (counts[occurrence.status] ?? 0) + 1;
    }
    return counts;
  }

  // --- Saved reports ------------------------------------------------------

  /// Stores [report] and prunes that period back to
  /// [reportsKeptPerPeriod] rows.
  Future<int> insertReport(SavedReport report) async {
    final Database db = await database;
    final int id = await db.insert(reportsTable, report.toMap());

    await db.delete(
      reportsTable,
      where: 'period_type = ? AND id NOT IN ('
          'SELECT id FROM $reportsTable WHERE period_type = ? '
          'ORDER BY created_at DESC, id DESC LIMIT ?)',
      whereArgs: <Object?>[
        report.periodType,
        report.periodType,
        reportsKeptPerPeriod,
      ],
    );

    return id;
  }

  /// The most recent debrief written for [periodType], or null if there is
  /// none — which is what the report screen shows before the first generate.
  Future<SavedReport?> getLatestReport(String periodType) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      reportsTable,
      where: 'period_type = ?',
      whereArgs: <Object?>[periodType],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SavedReport.fromMap(rows.first);
  }

  /// Every stored debrief for [periodType], newest first.
  Future<List<SavedReport>> getReports(String periodType) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      reportsTable,
      where: 'period_type = ?',
      whereArgs: <Object?>[periodType],
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(SavedReport.fromMap).toList();
  }

  /// Closes the handle so the next access reopens it. Mainly for tests.
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
