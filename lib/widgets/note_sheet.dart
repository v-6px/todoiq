import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/task_model.dart';
import '../theme/app_theme.dart';

/// What the user chose to do with the note prompt.
class NoteResult {
  /// The reason they typed, or null when they skipped or left it blank.
  final String? note;

  const NoteResult(this.note);
}

/// Asks, optionally, why a task ended up partial or skipped.
///
/// Deliberately skippable in one tap: the status change is the important part
/// and must never be held hostage to typing. Dismissing the sheet by dragging
/// it away is treated the same as "Skip".
class NoteSheet extends StatefulWidget {
  static const Key fieldKey = Key('note_field');
  static const Key saveKey = Key('note_save');
  static const Key skipKey = Key('note_skip');

  final String taskTitle;
  final String status;
  final String? initialNote;

  const NoteSheet({
    super.key,
    required this.taskTitle,
    required this.status,
    this.initialNote,
  });

  /// Opens the sheet. Resolves to null only if the caller should treat the
  /// interaction as "no note" — which is also what dismissal produces.
  static Future<NoteResult> show(
    BuildContext context, {
    required String taskTitle,
    required String status,
    String? initialNote,
  }) async {
    final NoteResult? result = await showModalBottomSheet<NoteResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      builder: (BuildContext context) => NoteSheet(
        taskTitle: taskTitle,
        status: status,
        initialNote: initialNote,
      ),
    );

    return result ?? const NoteResult(null);
  }

  @override
  State<NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<NoteSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialNote ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final String text = _controller.text.trim();
    Navigator.of(context).pop(NoteResult(text.isEmpty ? null : text));
  }

  void _skip() => Navigator.of(context).pop(const NoteResult(null));

  /// The prompt is worded for the status, so the question is about the thing
  /// that actually happened.
  String _prompt(AppStrings strings) {
    switch (widget.status) {
      case TaskStatus.partial:
        return strings.notePromptPartial;
      case TaskStatus.skipped:
        return strings.notePromptSkipped;
      default:
        return strings.notePromptGeneric;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius:
                        BorderRadius.all(Radius.circular(AppRadius.xs)),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(_prompt(strings), style: AppText.displayMd),
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.taskTitle,
                style: AppText.micro,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                key: NoteSheet.fieldKey,
                controller: _controller,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                maxLength: 280,
                textCapitalization: TextCapitalization.sentences,
                style: AppText.bodyMd,
                decoration: InputDecoration(
                  hintText: strings.noteHint,
                  counterText: '',
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      key: NoteSheet.skipKey,
                      onPressed: _skip,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink,
                        textStyle: AppText.buttonMd,
                        side: const BorderSide(color: AppColors.hairlineDark),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xl,
                          vertical: AppSpacing.md,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(
                            Radius.circular(AppRadius.md),
                          ),
                        ),
                      ),
                      child: Text(strings.noteSkip),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FilledButton(
                      key: NoteSheet.saveKey,
                      onPressed: _save,
                      child: Text(strings.noteSave),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
