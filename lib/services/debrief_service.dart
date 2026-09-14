import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';
import '../models/report_range.dart';
import '../models/task_model.dart';

/// Builds the two turns that produce a debrief.
///
/// Kept out of the screen because the wording is the product here: the same
/// task log yields a useful debrief or a useless one depending entirely on
/// what is asked for, and that is worth reading and changing on its own.
///
/// The log itself is written in English whatever the app language is, so the
/// model always parses a stable format; the reply language and the section
/// headings are set explicitly instead.
class DebriefService {
  /// Emoji sit in the template rather than in [AppStrings], so every language
  /// gets the same three marks and a translator cannot drop one.
  static const String summaryMark = '\u{1F4CA}';
  static const String obstaclesMark = '❌';
  static const String planMark = '\u{1F3AF}';

  /// The standing instruction: who the model is, and how it writes.
  ///
  /// Deliberately blunt. A debrief that opens with "great effort today!" is
  /// worth nothing to someone looking at three skipped tasks — the value is
  /// in being told plainly what slipped and what to do differently.
  static String systemPrompt(AppStrings strings) {
    return 'You are a high-accountability productivity coach reviewing '
        'somebody\'s task log. You are analytical, direct and unsentimental. '
        'You do not open with praise, you do not soften findings, and you do '
        'not pad. No greetings, no encouragement, no closing pleasantries — '
        'the reader wants the assessment, not reassurance.\n'
        '\n'
        'Judge the record as it stands. Where the numbers are poor, say so in '
        'plain words. Where the user recorded a reason for a task stalling, '
        'that reason is evidence: build the analysis on it rather than '
        'speculating around it. Never invent a task that is not in the log, '
        'and never soften a fact to make it more comfortable.\n'
        '\n'
        'Output rules. Clean Markdown only, using exactly the three "###" '
        'headings given in the user message, verbatim, in that order, '
        'including their emoji — they are already written in the language you '
        'must reply in. No other headings, no preamble before the first one, '
        'nothing after the last section. Write full, complete sentences: '
        'short, concrete and professional, never clipped notes and never '
        'stopping mid-thought. Keep it concise and structured: the first '
        'section is two to four sentences, the second and third are three to '
        'five "-" bullets of one or two sentences each. Aim for 200-350 words '
        'in total and never exceed 400. If you are running long, write less '
        'in each section rather than dropping one — all three sections must '
        'be present and the last one must end on a complete sentence. Do not '
        'think out loud or draft in the reply; write only the final report. '
        '${strings.replyLanguageInstruction}';
  }

  /// The user turn: the log, then the shape the debrief must take.
  ///
  /// Tasks are grouped by status so the distinction the app is built around —
  /// partial means real progress, skipped means it never started — survives
  /// into the prompt.
  static String buildPrompt(
    ReportRange range,
    List<Task> tasks,
    DateTime now, {
    AppStrings strings = AppStrings.en,
  }) {
    final DateFormat dayFormat = DateFormat('EEE d MMM', 'en');
    final DateFormat timeFormat = DateFormat.Hm('en');

    String section(String heading, String status) {
      final List<Task> matching =
          tasks.where((Task t) => t.status == status).toList();
      if (matching.isEmpty) return '$heading: none\n';

      final StringBuffer buffer = StringBuffer('$heading:\n');
      for (final Task task in matching) {
        buffer.write(
          '- "${task.title}" scheduled ${dayFormat.format(task.scheduledTime)} '
          'at ${timeFormat.format(task.scheduledTime)}',
        );
        // The note is the user's own account of what went wrong — the most
        // valuable signal in the whole log.
        if (task.hasNote) {
          buffer.write('; their reason: "${task.note!.trim()}"');
        }
        buffer.writeln();
      }
      return buffer.toString();
    }

    final int completed =
        tasks.where((Task t) => t.status == TaskStatus.completed).length;
    final int resolved = tasks
        .where((Task t) => t.status != TaskStatus.pending)
        .length;

    final StringBuffer prompt = StringBuffer()
      ..writeln('Task log for: ${range.englishLabel.toLowerCase()} '
          '(${range.dayCount(now)} day(s), ending ${dayFormat.format(now)}).')
      ..writeln('Today is ${DateFormat('yyyy-MM-dd').format(now)}.')
      ..writeln('Totals: ${tasks.length} scheduled, $completed completed, '
          '$resolved actioned one way or another.')
      ..writeln()
      ..writeln(section('COMPLETED (finished)', TaskStatus.completed))
      ..writeln(section('PARTIAL (progress made, not finished)',
          TaskStatus.partial))
      ..writeln(section('SKIPPED (never started or postponed)',
          TaskStatus.skipped))
      ..writeln(section('STILL PENDING (not yet actioned)',
          TaskStatus.pending))
      ..writeln()
      ..writeln('Write the debrief with exactly these three sections, using '
          'these headings verbatim — copy them character for character, '
          'including the emoji, and do not translate or re-word them:')
      ..writeln()
      ..writeln('### $summaryMark ${strings.reportHeadingSummary}')
      ..writeln('Executive summary in two to four sentences: a direct, '
          'unsparing read of how much actually got done. State the '
          'completion rate, name the completed tasks that mattered most, and '
          'say what the numbers mean. No compliments, no hedging, no "but".')
      ..writeln()
      ..writeln('### $obstaclesMark ${strings.reportHeadingBottlenecks}')
      ..writeln('Analyse precisely which tasks stalled or were skipped and '
          'why, working from the reasons quoted in the log above. Go after '
          'the PARTIAL tasks specifically — those are where work starts and '
          'does not finish, which is the pattern worth breaking. Name it: '
          'the hour it happens, the kind of work, the recurring excuse. '
          'Where the evidence is thin, say so rather than guessing.')
      ..writeln()
      ..writeln('### $planMark ${strings.reportHeadingNextSteps}')
      ..writeln('Two or three corrective steps for tomorrow, as bullets, '
          'including one that builds on what did get done. Each one must be '
          'specific enough to act on without thinking: name the task, the '
          'time, or the thing to cut. No general advice, no motivational '
          'lines.')
      ..writeln()
      ..writeln('Task titles are quoted from the log and keep their exact '
          'spelling, even where the rest of the sentence is in another '
          'script. Finish the last section properly — a debrief that stops '
          'part-way is worse than a short one.');

    return prompt.toString();
  }

  const DebriefService._();
}
