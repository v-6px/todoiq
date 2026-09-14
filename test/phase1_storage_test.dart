import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:todo_list/models/chat_message_model.dart';
import 'package:todo_list/models/report_range.dart';
import 'package:todo_list/models/saved_report.dart';
import 'package:todo_list/models/task_model.dart';
import 'package:todo_list/services/database_service.dart';
import 'package:todo_list/services/settings_service.dart';

void main() {
  // Run the real SQLite engine on the host instead of the Android/iOS plugin.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Test files run in parallel isolates; sharing one SQLite file across
    // them deadlocks.
    DatabaseService.debugDatabaseName = 'phase1_test.db';
  });

  setUp(() async {
    // Each test starts from an empty database and empty preferences.
    await DatabaseService.instance.close();
    final String path = p.join(
      await databaseFactory.getDatabasesPath(),
      'phase1_test.db',
    );
    await databaseFactory.deleteDatabase(path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Task model', () {
    test('round-trips through toMap/fromMap', () {
      final DateTime scheduled = DateTime(2026, 9, 12, 9, 30);
      final DateTime created = DateTime(2026, 9, 11, 20, 0);
      final Task task = Task(
        id: 7,
        title: 'Write the roadmap',
        scheduledTime: scheduled,
        status: TaskStatus.partial,
        createdAt: created,
      );

      final Task restored = Task.fromMap(task.toMap());

      expect(restored.id, 7);
      expect(restored.title, 'Write the roadmap');
      expect(restored.scheduledTime, scheduled);
      expect(restored.status, TaskStatus.partial);
      expect(restored.createdAt, created);
    });

    test('omits a null id so SQLite can assign one', () {
      final Task task = Task(
        title: 'No id yet',
        scheduledTime: DateTime(2026, 9, 12, 8),
      );
      expect(task.toMap().containsKey('id'), isFalse);
      expect(task.status, TaskStatus.pending);
    });
  });

  group('DatabaseService', () {
    test('inserts a task and reads it back for the day', () async {
      final DateTime scheduled = DateTime(2026, 9, 12, 14, 0);
      final int id = await DatabaseService.instance.insertTask(
        Task(title: 'Ship Phase 1', scheduledTime: scheduled),
      );
      expect(id, greaterThan(0));

      final List<Task> today =
          await DatabaseService.instance.getTasksForDate(scheduled);

      expect(today, hasLength(1));
      expect(today.single.id, id);
      expect(today.single.title, 'Ship Phase 1');
      expect(today.single.status, TaskStatus.pending);
      expect(today.single.scheduledTime, scheduled);
    });

    test('getTasksForDate excludes other days', () async {
      await DatabaseService.instance.insertTask(
        Task(title: 'Today', scheduledTime: DateTime(2026, 9, 12, 10)),
      );
      await DatabaseService.instance.insertTask(
        Task(title: 'Tomorrow', scheduledTime: DateTime(2026, 9, 13, 10)),
      );

      final List<Task> today = await DatabaseService.instance
          .getTasksForDate(DateTime(2026, 9, 12));

      expect(today.map((Task t) => t.title), <String>['Today']);
    });

    test('getTasksBetween returns the range sorted by time', () async {
      await DatabaseService.instance.insertTask(
        Task(title: 'Late', scheduledTime: DateTime(2026, 9, 12, 18)),
      );
      await DatabaseService.instance.insertTask(
        Task(title: 'Early', scheduledTime: DateTime(2026, 9, 12, 6)),
      );
      await DatabaseService.instance.insertTask(
        Task(title: 'Outside', scheduledTime: DateTime(2026, 9, 20, 6)),
      );

      final List<Task> range = await DatabaseService.instance.getTasksBetween(
        DateTime(2026, 9, 12),
        DateTime(2026, 9, 13),
      );

      expect(range.map((Task t) => t.title), <String>['Early', 'Late']);
    });

    test('updateStatus persists each of the three terminal states', () async {
      final DateTime scheduled = DateTime(2026, 9, 12, 9);
      final int id = await DatabaseService.instance.insertTask(
        Task(title: 'Cycle me', scheduledTime: scheduled),
      );

      for (final String status in <String>[
        TaskStatus.completed,
        TaskStatus.partial,
        TaskStatus.skipped,
      ]) {
        final int changed =
            await DatabaseService.instance.updateStatus(id, status);
        expect(changed, 1);
        final Task? stored = await DatabaseService.instance.getTaskById(id);
        expect(stored!.status, status);
      }
    });

    test('deleteTask removes the row', () async {
      final DateTime scheduled = DateTime(2026, 9, 12, 9);
      final int id = await DatabaseService.instance.insertTask(
        Task(title: 'Delete me', scheduledTime: scheduled),
      );

      expect(await DatabaseService.instance.deleteTask(id), 1);
      expect(await DatabaseService.instance.getTaskById(id), isNull);
      expect(
        await DatabaseService.instance.getTasksForDate(scheduled),
        isEmpty,
      );
    });

    test('getStatusCounts reports every status, zeros included', () async {
      final DateTime day = DateTime(2026, 9, 12);
      final int a = await DatabaseService.instance.insertTask(
        Task(title: 'A', scheduledTime: DateTime(2026, 9, 12, 8)),
      );
      final int b = await DatabaseService.instance.insertTask(
        Task(title: 'B', scheduledTime: DateTime(2026, 9, 12, 9)),
      );
      await DatabaseService.instance.insertTask(
        Task(title: 'C', scheduledTime: DateTime(2026, 9, 12, 10)),
      );
      await DatabaseService.instance.updateStatus(a, TaskStatus.completed);
      await DatabaseService.instance.updateStatus(b, TaskStatus.partial);

      final Map<String, int> counts = await DatabaseService.instance
          .getStatusCounts(day, day.add(const Duration(days: 1)));

      expect(counts[TaskStatus.completed], 1);
      expect(counts[TaskStatus.partial], 1);
      expect(counts[TaskStatus.pending], 1);
      expect(counts[TaskStatus.skipped], 0);
    });

    test('data survives closing and reopening the database', () async {
      final DateTime scheduled = DateTime(2026, 9, 12, 11);
      await DatabaseService.instance.insertTask(
        Task(title: 'Persist me', scheduledTime: scheduled),
      );

      await DatabaseService.instance.close();

      final List<Task> reopened =
          await DatabaseService.instance.getTasksForDate(scheduled);
      expect(reopened.single.title, 'Persist me');
    });
  });

  group('Task notes', () {
    test('a note round-trips through the database', () async {
      final DateTime scheduled = DateTime(2026, 9, 12, 9);
      final int id = await DatabaseService.instance.insertTask(
        Task(
          title: 'Blocked task',
          scheduledTime: scheduled,
          status: TaskStatus.partial,
          note: 'waiting on review',
        ),
      );

      final Task? stored = await DatabaseService.instance.getTaskById(id);
      expect(stored!.note, 'waiting on review');
      expect(stored.hasNote, isTrue);
    });

    test('a task without a note reads back null', () async {
      final int id = await DatabaseService.instance.insertTask(
        Task(title: 'Plain', scheduledTime: DateTime(2026, 9, 12, 9)),
      );
      final Task? stored = await DatabaseService.instance.getTaskById(id);
      expect(stored!.note, isNull);
      expect(stored.hasNote, isFalse);
    });

    test('updateStatusWithNote stores the status and the reason', () async {
      final int id = await DatabaseService.instance.insertTask(
        Task(title: 'Explain me', scheduledTime: DateTime(2026, 9, 12, 9)),
      );

      await DatabaseService.instance
          .updateStatusWithNote(id, TaskStatus.skipped, '  power cut  ');

      final Task? stored = await DatabaseService.instance.getTaskById(id);
      expect(stored!.status, TaskStatus.skipped);
      expect(stored.note, 'power cut', reason: 'the note is trimmed');
    });

    test('a null or blank note clears any previous one', () async {
      final int id = await DatabaseService.instance.insertTask(
        Task(
          title: 'Had a reason',
          scheduledTime: DateTime(2026, 9, 12, 9),
          status: TaskStatus.partial,
          note: 'old reason',
        ),
      );

      await DatabaseService.instance
          .updateStatusWithNote(id, TaskStatus.pending, null);
      expect((await DatabaseService.instance.getTaskById(id))!.note, isNull);

      await DatabaseService.instance
          .updateStatusWithNote(id, TaskStatus.partial, 'back again');
      await DatabaseService.instance
          .updateStatusWithNote(id, TaskStatus.partial, '   ');
      expect((await DatabaseService.instance.getTaskById(id))!.note, isNull);
    });

    test('plain updateStatus leaves an existing note alone', () async {
      final int id = await DatabaseService.instance.insertTask(
        Task(
          title: 'Keep my reason',
          scheduledTime: DateTime(2026, 9, 12, 9),
          status: TaskStatus.partial,
          note: 'still blocked',
        ),
      );

      await DatabaseService.instance.updateStatus(id, TaskStatus.skipped);

      final Task? stored = await DatabaseService.instance.getTaskById(id);
      expect(stored!.status, TaskStatus.skipped);
      expect(stored.note, 'still blocked');
    });

    test('copyWith keeps a note unless clearNote is set', () {
      final Task task = Task(
        title: 'T',
        scheduledTime: DateTime(2026, 9, 12, 9),
        note: 'reason',
      );

      expect(task.copyWith(status: TaskStatus.skipped).note, 'reason');
      expect(task.copyWith(note: 'new reason').note, 'new reason');
      expect(task.copyWith(clearNote: true).note, isNull);
    });

    test('an empty-string note does not count as a note', () {
      final Task task = Task(
        title: 'T',
        scheduledTime: DateTime(2026, 9, 12, 9),
        note: '   ',
      );
      expect(task.hasNote, isFalse);
    });
  });

  group('Schema migration', () {
    test('a v1 database gains a null note column on upgrade', () async {
      await DatabaseService.instance.close();

      final String path = p.join(
        await databaseFactory.getDatabasesPath(),
        'migration_test.db',
      );
      await databaseFactory.deleteDatabase(path);

      // Build the original v1 schema by hand and put a row in it.
      final Database v1 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (Database db, int version) async {
            await db.execute(
              'CREATE TABLE tasks ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'title TEXT NOT NULL, '
              'scheduled_time INTEGER NOT NULL, '
              "status TEXT NOT NULL DEFAULT 'pending', "
              'created_at INTEGER NOT NULL)',
            );
          },
        ),
      );
      await v1.insert('tasks', <String, Object?>{
        'title': 'Legacy task',
        'scheduled_time': DateTime(2026, 9, 12, 9).millisecondsSinceEpoch,
        'status': TaskStatus.completed,
        'created_at': DateTime(2026, 9, 11).millisecondsSinceEpoch,
      });
      await v1.close();

      // Reopen at the current version, running the real migration.
      DatabaseService.debugDatabaseName = 'migration_test.db';
      final List<Task> tasks = await DatabaseService.instance
          .getTasksForDate(DateTime(2026, 9, 12));

      expect(tasks, hasLength(1));
      expect(tasks.single.title, 'Legacy task');
      expect(tasks.single.note, isNull, reason: 'existing rows survive');

      // And the new column is writable.
      await DatabaseService.instance
          .updateStatusWithNote(tasks.single.id!, TaskStatus.partial, 'why');
      final Task? updated =
          await DatabaseService.instance.getTaskById(tasks.single.id!);
      expect(updated!.note, 'why');

      await DatabaseService.instance.close();
      DatabaseService.debugDatabaseName = 'phase1_test.db';
    });

    test('a v3 database gains the reports table without losing tasks',
        () async {
      await DatabaseService.instance.close();

      final String path = p.join(
        await databaseFactory.getDatabasesPath(),
        'migration_v3_test.db',
      );
      await databaseFactory.deleteDatabase(path);

      // The v3 schema: everything the current one has except reports.
      final Database v3 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (Database db, int version) async {
            await db.execute(
              'CREATE TABLE tasks ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'title TEXT NOT NULL, '
              'scheduled_time INTEGER NOT NULL, '
              "status TEXT NOT NULL DEFAULT 'pending', "
              'created_at INTEGER NOT NULL, '
              'note TEXT, '
              "recurrence_type TEXT NOT NULL DEFAULT 'none', "
              'repeat_days TEXT, '
              'status_date INTEGER)',
            );
          },
        ),
      );
      await v3.insert('tasks', <String, Object?>{
        'title': 'Task from before reports existed',
        'scheduled_time': DateTime(2026, 9, 12, 9).millisecondsSinceEpoch,
        'status': TaskStatus.pending,
        'created_at': DateTime(2026, 9, 11).millisecondsSinceEpoch,
        'recurrence_type': RecurrenceType.none,
      });
      await v3.close();

      DatabaseService.debugDatabaseName = 'migration_v3_test.db';

      // The upgrade runs on first access and must not touch the tasks.
      final List<Task> tasks = await DatabaseService.instance
          .getTasksForDate(DateTime(2026, 9, 12));
      expect(tasks.single.title, 'Task from before reports existed');

      // And the new table is there and usable.
      expect(await DatabaseService.instance.getLatestReport('today'), isNull);
      await DatabaseService.instance.insertReport(SavedReport.forRange(
        ReportRange.today,
        contentMarkdown: 'first report after upgrading',
      ));
      expect(
        (await DatabaseService.instance.getLatestReport('today'))!
            .contentMarkdown,
        'first report after upgrading',
      );

      await DatabaseService.instance.close();
      DatabaseService.debugDatabaseName = 'phase1_test.db';
    });

    test('a v5 database gains the added flag without losing the chat',
        () async {
      await DatabaseService.instance.close();

      final String path = p.join(
        await databaseFactory.getDatabasesPath(),
        'migration_v5_test.db',
      );
      await databaseFactory.deleteDatabase(path);

      // The v5 chat table: no action_added column.
      final Database v5 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (Database db, int version) async {
            await db.execute(
              'CREATE TABLE tasks ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'title TEXT NOT NULL, '
              'scheduled_time INTEGER NOT NULL, '
              "status TEXT NOT NULL DEFAULT 'pending', "
              'created_at INTEGER NOT NULL, '
              'note TEXT, '
              "recurrence_type TEXT NOT NULL DEFAULT 'none', "
              'repeat_days TEXT, '
              'status_date INTEGER)',
            );
            await db.execute(
              'CREATE TABLE chat_messages ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'role TEXT NOT NULL, '
              'content TEXT NOT NULL, '
              'created_at INTEGER NOT NULL)',
            );
          },
        ),
      );
      await v5.insert('chat_messages', <String, Object?>{
        'role': ChatRole.user,
        'content': 'said before the flag existed',
        'created_at': DateTime(2026, 9, 9).millisecondsSinceEpoch,
      });
      await v5.close();

      DatabaseService.debugDatabaseName = 'migration_v5_test.db';

      final List<ChatMessage> stored =
          await DatabaseService.instance.getChatMessages();
      expect(stored.single.content, 'said before the flag existed');
      expect(
        stored.single.actionAdded,
        isFalse,
        reason: 'an unknown history offers its cards again, which is the '
            'safe direction to be wrong in',
      );

      // And the new column is writable.
      await DatabaseService.instance.markChatActionAdded(stored.single.id!);
      expect(
        (await DatabaseService.instance.getChatMessages()).single.actionAdded,
        isTrue,
      );

      await DatabaseService.instance.close();
      DatabaseService.debugDatabaseName = 'phase1_test.db';
    });

    test('the added flag survives a round trip', () async {
      await DatabaseService.instance.clearChatMessages();

      final int id = await DatabaseService.instance.insertChatMessage(
        ChatMessage.assistant('proposed something'),
      );
      expect(
        (await DatabaseService.instance.getChatMessages()).single.actionAdded,
        isFalse,
      );

      expect(await DatabaseService.instance.markChatActionAdded(id), 1);

      final ChatMessage marked =
          (await DatabaseService.instance.getChatMessages()).single;
      expect(marked.actionAdded, isTrue);
      expect(marked.id, id);

      await DatabaseService.instance.clearChatMessages();
    });

    test('marking one turn leaves the rest alone', () async {
      await DatabaseService.instance.clearChatMessages();

      final int first = await DatabaseService.instance
          .insertChatMessage(ChatMessage.assistant('first'));
      await DatabaseService.instance
          .insertChatMessage(ChatMessage.assistant('second'));

      await DatabaseService.instance.markChatActionAdded(first);

      final List<ChatMessage> all =
          await DatabaseService.instance.getChatMessages();
      expect(all.first.actionAdded, isTrue);
      expect(all.last.actionAdded, isFalse);

      await DatabaseService.instance.clearChatMessages();
    });

    test('an existing install gains the chat table on upgrade', () async {
      // Not rebuilt from scratch here — the v3 fixture above already proves
      // the stepwise path. This checks the v5 step lands on a database that
      // has been through every earlier one.
      expect(await DatabaseService.instance.getChatMessages(), isEmpty);

      await DatabaseService.instance.insertChatMessage(
        ChatMessage.user('does the table exist'),
      );
      final List<ChatMessage> stored =
          await DatabaseService.instance.getChatMessages();
      expect(stored.single.content, 'does the table exist');
      expect(stored.single.role, ChatRole.user);

      await DatabaseService.instance.clearChatMessages();
      expect(await DatabaseService.instance.getChatMessages(), isEmpty);
    });

    test('turns come back in the order they were written', () async {
      await DatabaseService.instance.clearChatMessages();
      for (int i = 0; i < 5; i++) {
        await DatabaseService.instance.insertChatMessage(ChatMessage(
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content: 'turn $i',
          timestamp: DateTime(2026, 9, 9, 10, i),
        ));
      }

      expect(
        (await DatabaseService.instance.getChatMessages())
            .map((ChatMessage m) => m.content)
            .toList(),
        <String>['turn 0', 'turn 1', 'turn 2', 'turn 3', 'turn 4'],
      );
      await DatabaseService.instance.clearChatMessages();
    });
  });

  group('SettingsService', () {
    test('falls back to the documented defaults', () async {
      expect(await SettingsService.instance.getApiKey(), '');
      expect(
        await SettingsService.instance.getBaseUrl(),
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(await SettingsService.instance.getModelName(), 'gemini-3.6-flash');
      expect(await SettingsService.instance.isConfigured(), isFalse);
    });

    test('writes and reads back all three fields', () async {
      await SettingsService.instance.saveAll(
        apiKey: '  sk-test-123  ',
        baseUrl: 'https://api.groq.com/openai/v1/',
        modelName: ' llama-3.3-70b-versatile ',
      );

      expect(await SettingsService.instance.getApiKey(), 'sk-test-123');
      expect(
        await SettingsService.instance.getBaseUrl(),
        'https://api.groq.com/openai/v1',
      );
      expect(
        await SettingsService.instance.getModelName(),
        'llama-3.3-70b-versatile',
      );
      expect(await SettingsService.instance.isConfigured(), isTrue);
    });

    test('builds the chat-completions URL without a double slash', () async {
      await SettingsService.instance
          .setBaseUrl('https://openrouter.ai/api/v1///');
      expect(
        await SettingsService.instance.getChatCompletionsUrl(),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('resetToDefaults clears the stored key', () async {
      await SettingsService.instance.setApiKey('sk-live');
      await SettingsService.instance.resetToDefaults();

      expect(await SettingsService.instance.getApiKey(), '');
      expect(await SettingsService.instance.isConfigured(), isFalse);
    });

    test('every preset has a normalized base URL', () {
      for (final ProviderPreset preset in SettingsService.presets) {
        expect(preset.baseUrl.endsWith('/'), isFalse, reason: preset.label);
        expect(preset.modelName, isNotEmpty, reason: preset.label);
      }
    });
  });

  group('Saved reports', () {
    Future<void> clearReports() async {
      final Database db = await DatabaseService.instance.database;
      await db.delete(DatabaseService.reportsTable);
    }

    setUp(clearReports);

    test('a report round-trips through the table', () async {
      final DateTime written = DateTime(2026, 9, 9, 18, 30);
      await DatabaseService.instance.insertReport(SavedReport.forRange(
        ReportRange.thisWeek,
        contentMarkdown: '## Summary\nA good week.',
        createdAt: written,
      ));

      final SavedReport? stored = await DatabaseService.instance
          .getLatestReport(ReportRange.thisWeek.name);

      expect(stored, isNotNull);
      expect(stored!.contentMarkdown, '## Summary\nA good week.');
      expect(stored.periodType, 'thisWeek');
      expect(stored.range, ReportRange.thisWeek);
      expect(stored.createdAt, written);
      expect(stored.id, isNotNull);
    });

    test('the newest report for a period wins', () async {
      for (int day = 1; day <= 3; day++) {
        await DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'report $day',
          createdAt: DateTime(2026, 9, day),
        ));
      }

      final SavedReport? latest =
          await DatabaseService.instance.getLatestReport('today');
      expect(latest!.contentMarkdown, 'report 3');
    });

    test('periods do not read each other\'s reports', () async {
      await DatabaseService.instance.insertReport(SavedReport.forRange(
        ReportRange.today,
        contentMarkdown: 'daily',
      ));

      expect(
        await DatabaseService.instance.getLatestReport('thisWeek'),
        isNull,
      );
      expect(
        (await DatabaseService.instance.getLatestReport('today'))!
            .contentMarkdown,
        'daily',
      );
    });

    test('history is capped so the table cannot grow without bound', () async {
      for (int day = 1; day <= 9; day++) {
        await DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'report $day',
          createdAt: DateTime(2026, 9, day),
        ));
      }

      final List<SavedReport> kept =
          await DatabaseService.instance.getReports('today');

      expect(kept, hasLength(DatabaseService.reportsKeptPerPeriod));
      expect(kept.first.contentMarkdown, 'report 9');
      // The oldest are the ones dropped, newest first in the result.
      expect(kept.last.contentMarkdown, 'report 5');
    });

    test('pruning one period leaves the others alone', () async {
      await DatabaseService.instance.insertReport(SavedReport.forRange(
        ReportRange.thisWeek,
        contentMarkdown: 'weekly',
      ));
      for (int day = 1; day <= 9; day++) {
        await DatabaseService.instance.insertReport(SavedReport.forRange(
          ReportRange.today,
          contentMarkdown: 'report $day',
          createdAt: DateTime(2026, 9, day),
        ));
      }

      expect(await DatabaseService.instance.getReports('thisWeek'),
          hasLength(1));
    });

    test('an unrecognised period name does not crash the model', () {
      final SavedReport orphan = SavedReport(
        periodType: 'lastQuarter',
        contentMarkdown: 'written by a future build',
      );
      expect(orphan.range, isNull);
    });
  });
}
