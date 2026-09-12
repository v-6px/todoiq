import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
}
