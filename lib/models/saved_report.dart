import 'report_range.dart';

/// A debrief the model wrote, kept so reopening the screen does not cost
/// another API call.
///
/// The markdown is stored exactly as the model returned it — untouched, so a
/// later change to how reports are rendered applies to old ones too.
class SavedReport {
  final int? id;

  /// The [ReportRange] this covered, stored as its enum name so the column
  /// stays readable and survives a reordering of the enum.
  final String periodType;

  final String contentMarkdown;
  final DateTime createdAt;

  SavedReport({
    this.id,
    required this.periodType,
    required this.contentMarkdown,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  SavedReport.forRange(
    ReportRange range, {
    this.id,
    required this.contentMarkdown,
    DateTime? createdAt,
  })  : periodType = range.name,
        createdAt = createdAt ?? DateTime.now();

  /// The range this belongs to, or null if the stored name is not one we
  /// recognise — a report written by an older build with a range since
  /// removed should be ignored, not crash the screen.
  ReportRange? get range {
    for (final ReportRange value in ReportRange.values) {
      if (value.name == periodType) return value;
    }
    return null;
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'period_type': periodType,
        'content_markdown': contentMarkdown,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory SavedReport.fromMap(Map<String, Object?> map) => SavedReport(
        id: map['id'] as int?,
        periodType: map['period_type'] as String,
        contentMarkdown: map['content_markdown'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );

  @override
  String toString() =>
      'SavedReport(id: $id, period: $periodType, ${contentMarkdown.length} '
      'chars, createdAt: $createdAt)';
}
