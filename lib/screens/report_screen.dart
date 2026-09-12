import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
// intl exports a TextDirection of its own, which would shadow the one
// Directionality needs.
import 'package:intl/intl.dart' hide TextDirection;

import '../l10n/app_strings.dart';
import '../l10n/bidi_text.dart';
import '../models/report_range.dart';
import '../models/saved_report.dart';
import '../models/task_model.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import '../widgets/stat_chip.dart';
import 'settings_screen.dart';

/// Reviews a stretch of task history and asks the model for a debrief.
///
/// The counts and history come from SQLite and work offline; only the debrief
/// itself needs the network.
class ReportScreen extends StatefulWidget {
  static const Key backKey = Key('report_back');
  static const Key generateKey = Key('report_generate');
  static const Key markdownKey = Key('report_markdown');
  static const Key errorKey = Key('report_error');
  static const Key settingsShortcutKey = Key('report_settings_shortcut');
  static const Key generatedAtKey = Key('report_generated_at');

  static Key rangeKey(ReportRange range) => Key('report_range_${range.name}');

  /// The translated label for a range.
  static String rangeLabel(ReportRange range, AppStrings strings) {
    switch (range) {
      case ReportRange.today:
        return strings.rangeToday;
      case ReportRange.lastThreeDays:
        return strings.rangeLastThreeDays;
      case ReportRange.thisWeek:
        return strings.rangeThisWeek;
    }
  }

  /// Injectable so tests can drive the screen without a clock or a network.
  final DateTime? now;
  final http.Client? client;

  const ReportScreen({super.key, this.now, this.client});

  static String systemPrompt(AppStrings strings) =>
      'You are a concise productivity coach reviewing a task log. '
      'Write in Markdown. Be specific and reference the actual task titles. '
      'Never invent tasks that are not in the log. Keep the whole reply under '
      '250 words. ${strings.replyLanguageInstruction}';

  /// Builds the user turn: the log, plus what to do with it.
  ///
  /// Tasks are grouped by status so the distinction the app is built around —
  /// partial means real progress, skipped means it never started — survives
  /// into the prompt.
  static String buildDebriefPrompt(
    ReportRange range,
    List<Task> tasks,
    DateTime now, {
    AppStrings strings = AppStrings.en,
  }) {
    // The log itself stays in English so the model reads a stable format; the
    // reply language is set by the system turn.
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

    final StringBuffer prompt = StringBuffer()
      ..writeln('Task log for: ${range.englishLabel.toLowerCase()} '
          '(${range.dayCount(now)} day(s), ending ${dayFormat.format(now)}).')
      ..writeln()
      ..writeln(section('COMPLETED (finished)', TaskStatus.completed))
      ..writeln(section('PARTIAL (progress made, not finished)',
          TaskStatus.partial))
      ..writeln(section('SKIPPED (never started or postponed)',
          TaskStatus.skipped))
      ..writeln(section('STILL PENDING (not yet actioned)',
          TaskStatus.pending))
      ..writeln()
      ..writeln('Write the debrief with these Markdown sections, using these '
          'headings exactly as written — they are already in the language '
          'you are replying in, so copy them verbatim and do not translate '
          'or re-word them:')
      ..writeln('## ${strings.reportHeadingSummary}')
      ..writeln('Two sentences on how the period went, contrasting what was '
          'completed against what was only partial or skipped.')
      ..writeln('## ${strings.reportHeadingBottlenecks}')
      ..writeln('Identify what is blocking the PARTIAL tasks specifically — '
          'why work starts but does not finish. Where a reason is quoted, '
          'treat it as the primary evidence and build on it rather than '
          'speculating. Look for patterns in the timing and the kind of '
          'work. If the evidence is thin, say so rather than guessing.')
      ..writeln('## ${strings.reportHeadingTips}')
      ..writeln('Exactly two concrete, actionable tips tied to the tasks '
          'above. No generic advice.')
      ..writeln()
      ..writeln('Write flowing prose in your reply language. Task titles are '
          'quoted from the log and stay exactly as they are spelled, even '
          'when the rest of the sentence is in another script.');

    return prompt.toString();
  }

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late final AiService _ai = AiService(client: widget.client);

  ReportRange _range = ReportRange.today;
  ReportSummary _summary = const ReportSummary();
  bool _loadingCounts = true;

  bool _generating = false;
  String? _debrief;

  /// When the debrief on screen was written, or null if it is unsaved.
  ///
  /// Doubles as the "this came from storage" flag: a report with a timestamp
  /// is one the user has seen before, so the button offers to replace it
  /// rather than to create one.
  DateTime? _debriefAt;

  String? _error;
  bool _errorIsConfiguration = false;

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  @override
  void dispose() {
    _ai.dispose();
    super.dispose();
  }

  Future<void> _loadCounts() async {
    final Map<String, int> counts =
        await DatabaseService.instance.getStatusCounts(
      _range.start(_now),
      _range.end(_now),
    );

    // The last debrief written for this range, so reopening the screen costs
    // nothing and the user sees what they already paid for.
    final SavedReport? saved =
        await DatabaseService.instance.getLatestReport(_range.name);

    if (!mounted) return;
    setState(() {
      _summary = ReportSummary.fromCounts(counts);
      _debrief = saved?.contentMarkdown;
      _debriefAt = saved?.createdAt;
      _loadingCounts = false;
    });
  }

  Future<void> _selectRange(ReportRange range) async {
    if (range == _range) return;
    setState(() {
      _range = range;
      _loadingCounts = true;
      // The previous debrief described a different window; _loadCounts puts
      // this range's own stored one back in its place, if there is one.
      _debrief = null;
      _debriefAt = null;
      _error = null;
    });
    await _loadCounts();
  }

  Future<void> _generate() async {
    final AppStrings strings = AppStrings.of(context);

    setState(() {
      _generating = true;
      _error = null;
      _debrief = null;
    });

    try {
      // Occurrence-by-occurrence, so a recurring task contributes each day it
      // actually ran, carrying that day's own status and note.
      final List<Task> tasks =
          await DatabaseService.instance.getOccurrencesBetween(
        _range.start(_now),
        _range.end(_now),
      );

      final String reply = await _ai.complete(
        <AiMessage>[
          AiMessage.system(ReportScreen.systemPrompt(strings)),
          AiMessage.user(
            ReportScreen.buildDebriefPrompt(
              _range,
              tasks,
              _now,
              strings: strings,
            ),
          ),
        ],
        maxTokens: 700,
        temperature: 0.7,
      );

      // Stored exactly as written, before any rendering is applied to it.
      final SavedReport saved = SavedReport.forRange(
        _range,
        contentMarkdown: reply,
      );
      await DatabaseService.instance.insertReport(saved);

      if (!mounted) return;
      setState(() {
        _debrief = reply;
        _debriefAt = saved.createdAt;
        _generating = false;
      });
    } on AiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _errorIsConfiguration = error.isConfigurationError;
        _generating = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = strings.debriefFailed;
        _errorIsConfiguration = false;
        _generating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.xxl,
          ),
          children: <Widget>[
            _header(context, strings),
            const SizedBox(height: AppSpacing.xl),
            _rangeChips(strings),
            const SizedBox(height: AppSpacing.xl),
            if (_loadingCounts)
              const SizedBox(height: 64)
            else ...<Widget>[
              _stats(strings),
              const SizedBox(height: AppSpacing.xl),
              _generateButton(strings),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              _errorPanel(context, strings),
            ],
            if (_debrief != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              _debriefPanel(strings),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppStrings strings) {
    return Row(
      children: <Widget>[
        IconButton(
          key: ReportScreen.backKey,
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(
            Icons.arrow_back_rounded,
            size: 20,
            textDirection: Directionality.of(context),
          ),
          color: AppColors.inkMute,
          tooltip: strings.back,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(strings.reportTitle, style: AppText.displayLg),
      ],
    );
  }

  Widget _rangeChips(AppStrings strings) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: ReportRange.values.map((ReportRange range) {
        return _RangeChip(
          chipKey: ReportScreen.rangeKey(range),
          label: ReportScreen.rangeLabel(range, strings),
          isActive: range == _range,
          onTap: () => _selectRange(range),
        );
      }).toList(),
    );
  }

  Widget _stats(AppStrings strings) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        StatChip(
          label: strings.statCompleted,
          count: _summary.completed,
          accent: AppColors.tealDeep,
        ),
        StatChip(
          label: strings.statPartial,
          count: _summary.partial,
          accent: AppColors.primary,
        ),
        StatChip(
          label: strings.statSkipped,
          count: _summary.skipped,
          accent: AppColors.inkFaint,
        ),
      ],
    );
  }

  Widget _generateButton(AppStrings strings) {
    if (_summary.isEmpty) {
      return Text(strings.noTasksInRange, style: AppText.caption);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: ReportScreen.generateKey,
            onPressed: _generating ? null : _generate,
            child: Text(
              _generating
                  ? strings.generatingDebrief
                  : _debrief == null
                      ? strings.generateDebrief
                      : strings.regenerateDebrief,
            ),
          ),
        ),
        if (_summary.resolved == 0) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(strings.nothingResolvedYet, style: AppText.micro),
        ],
      ],
    );
  }

  Widget _errorPanel(BuildContext context, AppStrings strings) {
    return Container(
      key: ReportScreen.errorKey,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.canvasSoft,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.error_outline_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _error!,
                  style: AppText.caption.copyWith(color: AppColors.primary),
                ),
              ),
            ],
          ),
          if (_errorIsConfiguration) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              key: ReportScreen.settingsShortcutKey,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const SettingsScreen(),
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                textStyle: AppText.buttonCap,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(strings.openSettings),
            ),
          ],
        ],
      ),
    );
  }

  Widget _debriefPanel(AppStrings strings) {
    final TextDirection direction = strings.textDirection;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_debriefAt != null) ...<Widget>[
          Text(
            strings.reportGeneratedAt(
              DateFormat('d MMM, HH:mm', strings.languageCode)
                  .format(_debriefAt!),
            ),
            key: ReportScreen.generatedAtKey,
            style: AppText.micro.copyWith(color: AppColors.inkFaint),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.lg)),
            border: Border.all(color: AppColors.hairline),
          ),
          // Pinned to the language's own direction rather than inherited, so
          // the debrief lays out right-to-left even if it is ever rendered
          // somewhere that has not set a direction.
          child: Directionality(
            textDirection: direction,
            child: MarkdownBody(
              key: ReportScreen.markdownKey,
              // Latin task titles are isolated so they cannot drag the
              // surrounding Arabic punctuation to the wrong end of the line.
              data: BidiText.forDirection(
                _debrief!,
                isRtl: direction == TextDirection.rtl,
              ),
              styleSheet: _markdownStyle,
            ),
          ),
        ),
      ],
    );
  }

  MarkdownStyleSheet get _markdownStyle {
    // MarkdownBody builds its own spans, so the theme's family does not reach
    // them by inheritance — it has to be set on each style.
    final String? family = AppTheme.fontFamilyForLocale(
      Localizations.localeOf(context),
    );
    TextStyle f(TextStyle style) => style.copyWith(fontFamily: family);

    return MarkdownStyleSheet(
      p: f(AppText.bodyMd),
      h1: f(AppText.displayMd),
      h2: f(AppText.headingLg),
      h3: f(AppText.bodyMd.copyWith(fontWeight: FontWeight.w700)),
      listBullet: f(AppText.bodyMd),
      strong: f(AppText.bodyMd.copyWith(fontWeight: FontWeight.w700)),
      em: f(AppText.bodyMd.copyWith(fontStyle: FontStyle.italic)),
      blockquote: AppText.caption,
      code: AppText.caption.copyWith(
        fontFamily: 'monospace',
        color: AppColors.ink,
      ),
      codeblockDecoration: BoxDecoration(
        color: AppColors.canvasSoft,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
        border: Border.all(color: AppColors.hairline),
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.hairline, width: 3)),
      ),
      h2Padding: const EdgeInsets.only(top: AppSpacing.lg),
      pPadding: const EdgeInsets.only(top: AppSpacing.xs),
    );
  }
}

/// Timeframe selector chip, matching the settings preset chips.
class _RangeChip extends StatelessWidget {
  final Key chipKey;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _RangeChip({
    required this.chipKey,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? AppColors.primary : AppColors.canvas,
      borderRadius: const BorderRadius.all(Radius.circular(999)),
      child: InkWell(
        key: chipKey,
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            border: Border.all(
              color: isActive ? AppColors.primary : AppColors.hairline,
            ),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: AppText.buttonCap.copyWith(
                color: isActive ? AppColors.onPrimary : AppColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
