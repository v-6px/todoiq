Smart Local-First To-Do & AI Debriefing App (Technical Roadmap)

1. Core Principles
   100% Local-First: All database operations (SQLite) and alarms/notifications run offline directly on the device.

BYOK (Bring Your Own Key): Works with any standard OpenAI-compatible endpoint (OpenRouter, Groq, Google Gemini OpenAI-compatible gateway, CodeCraft). Keys and endpoints are stored in shared_preferences.

Three-State Task Logic: completed (Done), partial (Made progress, unfinished), skipped (Postponed/missed).

Zero-Server Notifications: Local hardware alarms managed by the operating system.

AI Debriefing & Chat: Periodic reporting and interactive productivity coaching.

2. Dependencies (pubspec.yaml)
   YAML
   dependencies:
   flutter:
   sdk: flutter
   sqflite: ^2.4.1
   path: ^1.9.0
   shared_preferences: ^2.3.5
   flutter_local_notifications: ^18.0.1
   timezone: ^0.10.0
   http: ^1.3.0
   intl: ^0.20.2
   flutter_markdown: ^0.7.5
3. Directory Layout
   Plaintext
   lib/
   ├── main.dart
   ├── models/
   │ ├── task_model.dart
   │ └── chat_message_model.dart
   ├── services/
   │ ├── database_service.dart
   │ ├── notification_service.dart
   │ ├── settings_service.dart
   │ └── ai_service.dart
   ├── screens/
   │ ├── home_screen.dart
   │ ├── report_screen.dart
   │ ├── chat_coach_screen.dart
   │ └── settings_screen.dart
   └── widgets/
   ├── task_card.dart
   ├── add_task_sheet.dart
   └── stat_chip.dart
4. Phased Execution Roadmap
   Phase 1: Local Storage & Native Permissions Setup
   Goal: Project setup, permissions configuration, and local storage (SQLite + SharedPreferences).

Tasks:

Add dependencies to pubspec.yaml.

Setup native permissions:

Android (AndroidManifest.xml): Add POST_NOTIFICATIONS, SCHEDULE_EXACT_ALARM, and USE_EXACT_ALARM.

iOS (Info.plist & AppDelegate.swift): Configure alert and sound notification permissions.

Create models/task_model.dart:

Fields: id (int?), title (String), scheduled_time (DateTime), status (String: 'pending', 'completed', 'partial', 'skipped'), created_at (DateTime).

Include toMap() and fromMap() methods.

Create services/database_service.dart:

Initialize SQLite database and tasks table.

Implement CRUD: insertTask, getTasksForDate(DateTime date), getTasksBetween(DateTime start, DateTime end), updateStatus(int id, String status), deleteTask(int id).

Create services/settings_service.dart:

Read/Write settings via shared_preferences:

api_key (String, default: "")

base_url (String, default: "[https://generativelanguage.googleapis.com/v1beta/openai/](https://generativelanguage.googleapis.com/v1beta/openai/)")

model_name (String, default: "gemini-1.5-flash")

Verification: Verify creating a task, querying SQLite, and reading/writing settings in a test run before moving to Phase 2.

Phase 2: Offline Local Notifications Service
Goal: Time-accurate alarms on device hardware without internet.

Tasks:

Initialize flutter_local_notifications plugin and timezone database (timezone/data/latest_all.dart).

Implement services/notification_service.dart:

init(): Request native alert permissions.

scheduleNotification(int id, String title, DateTime scheduledDate): Call zonedSchedule for exact alert timing.

cancelNotification(int id): Cancel alarm if task is marked complete, partial, skipped, or deleted.

Verification: Schedule an alert 5 seconds in the future and verify it rings on device/emulator without network access.

Phase 3: Minimalist Home Dashboard & Task Actions
Goal: Tactile, distraction-free task management UI.

Tasks:

Create widgets/task_card.dart:

Display task title and scheduled time.

Three action buttons:

[ ✓ ] Complete: Updates status to completed, cancels alarm.

[ ~ ] Partial: Updates status to partial, cancels alarm.

[ ✕ ] Skip: Updates status to skipped, cancels alarm.

Create widgets/add_task_sheet.dart:

Clean bottom sheet containing a title input field and interactive TimePicker.

Saves record to SQLite and schedules notification.

Create screens/home_screen.dart:

Header displaying today's date and 3 action icons:

AI Reports (Icons.auto_graph_outlined)

AI Coach Chat (Icons.chat_bubble_outline)

Settings (Icons.settings_outlined)

Scrollable list of today's tasks fetched from SQLite.

Verification: Add multiple tasks, switch statuses between Done, Partial, and Skip, and verify SQLite updates on restart.

Phase 4: Flexible BYOK Settings Screen
Goal: UI to enter credentials for any OpenAI-compatible provider.

Tasks:

Create screens/settings_screen.dart:

Input fields for API Key, Base URL, and Model Name.

Presets dropdown (e.g., Gemini Flash, Groq, OpenRouter).

"Test Connection" button sending a 2-token ping to ${base_url}/chat/completions.

"Save" button storing fields into shared_preferences.

Verification: Save custom credentials, execute connection test, and verify persistent retrieval on app reboot.

Phase 5: AI Productivity Debriefing Screen
Goal: Extract task history, generate structured debriefs, and display markdown reports.

Tasks:

Create services/ai_service.dart:

Execute POST requests to ${baseUrl}/chat/completions using the http package.

Pass headers: Authorization: Bearer <API_KEY>, Content-Type: application/json, and User-Agent.

Create screens/report_screen.dart:

Filter chips: "Today", "Last 3 Days", "This Week".

Summary badges displaying counts: Completed, Partial, Skipped.

"Generate AI Debrief" button:

Fetch tasks in selected range from SQLite.

Submit structured prompt instructing the model to review completed vs. partial vs. skipped items, find workflow bottlenecks, and give 2 concrete tips.

Display AI response via flutter_markdown.

Verification: Generate reports for varying test task lists; verify differentiation between partial and skipped tasks in output.

Phase 6: Task-Aware Interactive AI Coach Chat
Goal: Conversational interface aware of the user's task history.

Tasks:

Create models/chat_message_model.dart (role, content, timestamp).

Create screens/chat_coach_screen.dart:

Automatically inject system prompt loaded with today's uncompleted and partial tasks.

Clean chat bubbles UI with text input field.

Maintain local session dialogue to discuss reasons for delays and adjust plans.

Verification: Send an inquiry like "Why did I struggle today?", verify the model references unfinished tasks from local SQLite.

5. Claude Code Execution Instructions
   Always build and verify each phase sequentially.

Wrap all HTTP operations in try/catch with clear UI snackbars on error.

Keep state updates predictable and maintain strict offline functionality for Phases 1, 2, and 3.
