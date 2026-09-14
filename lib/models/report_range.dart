import '../models/task_model.dart';

/// The timeframes the debrief can cover.
///
/// Every range is retrospective: it ends at the end of today, so a debrief
/// never reports on tasks that have not come due yet.
enum ReportRange {
  today('Today'),
  lastThreeDays('Last 3 days'),
  thisWeek('This week');

  const ReportRange(this.englishLabel);

  /// Stable English name, used inside AI prompts. The user-facing label comes
  /// from AppStrings so it follows the app language.
  final String englishLabel;

  /// First instant included, at midnight.
  ///
  /// Calendar arithmetic throughout: subtracting 24-hour durations drifts an
  /// hour off midnight across a daylight-saving change.
  DateTime start(DateTime now) {
    final DateTime local = now.toLocal();
    switch (this) {
      case ReportRange.today:
        return Task.dayStart(local);
      case ReportRange.lastThreeDays:
        // Today plus the two days before it.
        return Task.addDays(local, -2);
      case ReportRange.thisWeek:
        // ISO weeks start on Monday; DateTime.weekday is 1 for Monday.
        return Task.addDays(local, -(local.weekday - 1));
    }
  }

  /// Exclusive upper bound: midnight tonight.
  DateTime end(DateTime now) => Task.addDays(now, 1);

  /// How many whole days the range spans for [now].
  ///
  /// Counted on the calendar, since a range containing the clocks going back
  /// is 25 hours longer than its days and `inDays` would round wrongly.
  int dayCount(DateTime now) {
    final DateTime from = start(now);
    final DateTime to = end(now);
    return DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;
  }
}

/// Counts of each status over a range, ready for the summary row.
class ReportSummary {
  final int completed;
  final int partial;
  final int skipped;
  final int pending;

  const ReportSummary({
    this.completed = 0,
    this.partial = 0,
    this.skipped = 0,
    this.pending = 0,
  });

  factory ReportSummary.fromCounts(Map<String, int> counts) {
    return ReportSummary(
      completed: counts[TaskStatus.completed] ?? 0,
      partial: counts[TaskStatus.partial] ?? 0,
      skipped: counts[TaskStatus.skipped] ?? 0,
      pending: counts[TaskStatus.pending] ?? 0,
    );
  }

  int get total => completed + partial + skipped + pending;

  /// Tasks that reached a terminal state — the ones worth debriefing on.
  int get resolved => completed + partial + skipped;

  bool get isEmpty => total == 0;

  /// Share of resolved tasks that were completed, 0-100. Null when nothing
  /// has been resolved, so the UI can omit it rather than show a fake zero.
  int? get completionRate {
    if (resolved == 0) return null;
    return ((completed / resolved) * 100).round();
  }

  @override
  String toString() => 'ReportSummary(completed: $completed, '
      'partial: $partial, skipped: $skipped, pending: $pending)';
}
