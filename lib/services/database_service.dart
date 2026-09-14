import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/chat_message_model.dart';
import '../models/saved_report.dart';
import '../models/task_model.dart';

/// Owns the on-device SQLite database.
///
/// Everything here is local-first: no network access, no sync. The singleton
/// holds one lazily-opened [Database] handle for the life of the process.
class DatabaseService {
  static const String _databaseName = 'task_master.db';
  static const int _databaseVersion = 7;

  static const String tasksTable = 'tasks';
  static const String completionsTable = 'task_completions';
  static const String reportsTable = 'reports';
  static const String chatMessagesTable = 'chat_messages';

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
    await _createChatMessagesTable(db);
    await _createCompletionsTable(db);
  }

  /// One row per recurring task per day it was actioned.
  ///
  /// The primary key is what makes recording a status an upsert: tapping the
  /// checkmark twice on the same day rewrites one row rather than piling up
  /// history the day view then has to choose between.
  Future<void> _createCompletionsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $completionsTable (
        task_id INTEGER NOT NULL,
        day INTEGER NOT NULL,
        status TEXT NOT NULL,
        note TEXT,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (task_id, day)
      )
    ''');
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

  /// The assistant conversation, so closing the screen does not lose it.
  ///
  /// Assistant turns are stored exactly as the model wrote them, task_action
  /// block included, so reopening the screen restores the confirmation cards
  /// along with the text.
  Future<void> _createChatMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE $chatMessagesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        action_added INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Read in written order, every time.
    await db.execute(
      'CREATE INDEX idx_chat_created ON $chatMessagesTable (created_at)',
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
    if (oldVersion < 5) {
      // Creates the table at its current shape, action_added included — so
      // the v6 step below must not also run, or it adds a column that is
      // already there and takes the whole upgrade down with it. The `else`
      // is load-bearing.
      await _createChatMessagesTable(db);
    } else if (oldVersion < 6) {
      // A conversation stored before this column existed has no record of
      // which proposals were accepted; defaulting to 0 offers them again,
      // which is the safe direction to be wrong in.
      await db.execute(
        'ALTER TABLE $chatMessagesTable ADD COLUMN action_added '
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 7) {
      await _createCompletionsTable(db);
      await _moveRecurringStatusIntoHistory(db);
    }
  }

  /// Carries the one day a recurring row could remember into the history
  /// table, then clears it off the row so there is a single source of truth.
  Future<void> _moveRecurringStatusIntoHistory(Database db) async {
    final List<Map<String, Object?>> rows = await db.query(
      tasksTable,
      where: 'recurrence_type != ? AND status_date IS NOT NULL',
      whereArgs: <Object?>[RecurrenceType.none],
    );

    final Batch batch = db.batch();
    for (final Map<String, Object?> row in rows) {
      final String status = row['status'] as String;
      final String? note = row['note'] as String?;
      if (status == TaskStatus.pending && note == null) continue;

      batch.insert(
        completionsTable,
        TaskCompletion(
          taskId: row['id'] as int,
          day: Task.dayKey(
            DateTime.fromMillisecondsSinceEpoch(row['status_date'] as int),
          ),
          status: status,
          note: note,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    batch.update(
      tasksTable,
      <String, Object?>{
        'status': TaskStatus.pending,
        'note': null,
        'status_date': null,
      },
      where: 'recurrence_type != ?',
      whereArgs: <Object?>[RecurrenceType.none],
    );
    await batch.commit(noResult: true);
  }

  // --- CRUD ---------------------------------------------------------------

  /// Inserts [task] and returns the row id SQLite assigned.
  Future<int> insertTask(Task task) async {
    final Database db = await database;
    return db.insert(tasksTable, _rowFor(task));
  }

  /// The stored shape of [task].
  ///
  /// A recurring task loaded for a day carries that day's status on the
  /// object, which is right for display and wrong for the row: written back
  /// by an edit or an undo it would stamp one day's outcome onto the whole
  /// series. Per-day outcomes belong to [completionsTable] only.
  static Map<String, Object?> _rowFor(Task task) {
    final Map<String, Object?> row = task.toMap();
    if (task.isRecurring) {
      row['status'] = TaskStatus.pending;
      row['note'] = null;
      row['status_date'] = null;
    }
    return row;
  }

  /// Everything that belongs on the calendar day containing [date].
  ///
  /// That is one-off tasks dated that day, plus every recurring task whose
  /// pattern matches it. Recurring rows are matched in Dart rather than SQL:
  /// there are few of them, and weekday-set matching in SQL would mean string
  /// tricks on `repeat_days`.
  Future<List<Task>> getTasksForDate(DateTime date) async {
    final DateTime start = Task.dayStart(date);
    final DateTime end = Task.addDays(start, 1);
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

    final List<Task> todays =
        recurring.map(Task.fromMap).where((Task t) => t.occursOn(start)).toList();

    final List<Task> tasks = <Task>[
      ...oneOff.map(Task.fromMap),
      ...await _withStatusOn(db, todays, start),
    ];

    tasks.sort((Task a, Task b) => compareForDay(a, b, start));
    return tasks;
  }

  /// [recurring] as they stand on [day]: each carries that day's recorded
  /// status and note, or pending with no note if nothing was recorded.
  Future<List<Task>> _withStatusOn(
    DatabaseExecutor db,
    List<Task> recurring,
    DateTime day,
  ) async {
    if (recurring.isEmpty) return recurring;

    final List<int> ids = <int>[for (final Task t in recurring) t.id!];
    final List<Map<String, Object?>> rows = await db.query(
      completionsTable,
      where: 'day = ? AND task_id IN (${List<String>.filled(ids.length, '?').join(',')})',
      whereArgs: <Object?>[Task.dayKey(day), ...ids],
    );
    final Map<int, TaskCompletion> byTask = <int, TaskCompletion>{
      for (final Map<String, Object?> row in rows)
        row['task_id'] as int: TaskCompletion.fromMap(row),
    };

    return <Task>[
      for (final Task task in recurring)
        task.copyWith(
          status: byTask[task.id]?.status ?? TaskStatus.pending,
          note: byTask[task.id]?.note,
          clearNote: byTask[task.id]?.note == null,
          statusDate: Task.dayStart(day),
        ),
    ];
  }

  /// Task [id] as it stands on [day], or null if there is no such task.
  ///
  /// For a recurring task this carries that day's recorded status, which is
  /// what alarm scheduling needs to know whether today's instance is done.
  Future<Task?> getTaskOnDate(int id, DateTime day) async {
    final Task? task = await getTaskById(id);
    if (task == null || !task.isRecurring) return task;
    final Database db = await database;
    return (await _withStatusOn(db, <Task>[task], day)).single;
  }

  /// The order tasks appear in for [day].
  ///
  /// Finished work sinks; everything still open stays at the top where it can
  /// be acted on. Within each group the order is time of day, so a recurring
  /// task sits where it belongs in the timeline rather than by its original
  /// start date. Only *completed* drops — partial and skipped are still worth
  /// seeing in place, because they are what the day went wrong on and what
  /// the debrief asks about.
  ///
  /// Public because the home screen re-sorts its own list the instant a
  /// checkmark is tapped, and the two orders have to be the same one.
  static int compareForDay(Task a, Task b, DateTime day) {
    final bool aDone = a.statusOn(day) == TaskStatus.completed;
    final bool bDone = b.statusOn(day) == TaskStatus.completed;
    if (aDone != bDone) return aDone ? 1 : -1;

    final int byTime = _minutesOfDay(a).compareTo(_minutesOfDay(b));
    if (byTime != 0) return byTime;
    return (a.id ?? 0).compareTo(b.id ?? 0);
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
    DateTime day = Task.dayStart(start);
    final DateTime last = Task.dayStart(end);

    for (; day.isBefore(last); day = Task.addDays(day, 1)) {
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

    final List<Map<String, Object?>> found = await db.query(
      tasksTable,
      columns: <String>['recurrence_type'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (found.isEmpty) return 0;

    // A recurring task's outcome is recorded against the one day it belongs
    // to, in the history table. The series row is left alone, so nothing
    // that later reloads, edits or re-arms the task can undo the checkmark.
    if (found.single['recurrence_type'] != RecurrenceType.none) {
      final int day = Task.dayKey(forDate ?? DateTime.now());
      if (status == TaskStatus.pending && trimmed == null) {
        await db.delete(
          completionsTable,
          where: 'task_id = ? AND day = ?',
          whereArgs: <Object?>[id, day],
        );
      } else {
        await db.insert(
          completionsTable,
          TaskCompletion(
            taskId: id,
            day: day,
            status: status,
            note: trimmed,
          ).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      return 1;
    }

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
      _rowFor(task),
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Removes task [id] and its per-day history. Returns the task rows removed.
  ///
  /// One atomic batch — a single trip to the database, run as a transaction —
  /// so a task can never survive with its history gone or the other way round.
  Future<int> deleteTask(int id) async {
    final Database db = await database;
    final Batch batch = db.batch()
      ..rawDelete(
        'DELETE FROM $completionsTable WHERE task_id = ?',
        <Object?>[id],
      )
      ..rawDelete('DELETE FROM $tasksTable WHERE id = ?', <Object?>[id]);
    final List<Object?> results = await batch.commit();
    return results.last! as int;
  }

  /// Every day's recorded outcome for task [id].
  ///
  /// Read before a delete so an undo can put the history back as well.
  Future<List<TaskCompletion>> getCompletionsForTask(int id) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      completionsTable,
      where: 'task_id = ?',
      whereArgs: <Object?>[id],
    );
    return rows.map(TaskCompletion.fromMap).toList();
  }

  /// Puts a deleted [task] back under its original id, with [completions].
  Future<void> restoreTask(
    Task task, {
    List<TaskCompletion> completions = const <TaskCompletion>[],
  }) async {
    final Database db = await database;
    await db.transaction((Transaction txn) async {
      await txn.insert(
        tasksTable,
        _rowFor(task),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final TaskCompletion completion in completions) {
        await txn.insert(
          completionsTable,
          completion.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
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
    final List<Task> tasks = rows.map(Task.fromMap).toList();

    // Recurring tasks carry today's outcome, so re-arming after a language
    // switch does not bring back an alarm for an instance already finished.
    final List<Task> recurring = await _withStatusOn(
      db,
      tasks.where((Task t) => t.isRecurring).toList(),
      DateTime.now(),
    );
    return <Task>[
      ...tasks.where((Task t) => !t.isRecurring),
      ...recurring,
    ];
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

  // --- Assistant conversation ---------------------------------------------

  /// Appends one turn. Returns the row id SQLite assigned.
  Future<int> insertChatMessage(ChatMessage message) async {
    final Database db = await database;
    return db.insert(chatMessagesTable, message.toMap());
  }

  /// The whole conversation, oldest first — the order it is rendered in.
  Future<List<ChatMessage>> getChatMessages() async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      chatMessagesTable,
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// Records that the task turn [id] proposed has been added.
  ///
  /// What stops a restored proposal card creating the same task on every
  /// visit to the screen.
  Future<int> markChatActionAdded(int id) async {
    final Database db = await database;
    return db.update(
      chatMessagesTable,
      <String, Object?>{'action_added': 1},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Deletes the conversation. Returns how many turns went.
  Future<int> clearChatMessages() async {
    final Database db = await database;
    return db.delete(chatMessagesTable);
  }

  /// Closes the handle so the next access reopens it. Mainly for tests.
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
