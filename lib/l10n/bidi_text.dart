/// Keeps Latin text from disturbing the Arabic around it.
///
/// A debrief is Arabic prose quoting task titles the user typed in English.
/// The Unicode bidirectional algorithm resolves each line as a whole, so a
/// Latin run sitting next to a comma, a full stop or a digit can pull that
/// punctuation to the wrong end of the line — the line looks broken even
/// though every character is correct.
///
/// Wrapping each Latin run in an isolate (U+2068 FIRST STRONG ISOLATE …
/// U+2069 POP DIRECTIONAL ISOLATE) tells the algorithm to resolve that run on
/// its own and treat it as a single neutral object in the Arabic line, which
/// is exactly what a quoted title is.
class BidiText {
  /// FIRST STRONG ISOLATE.
  static const String fsi = '\u2068';

  /// POP DIRECTIONAL ISOLATE.
  static const String pdi = '\u2069';

  /// A run of Latin text: starts and ends on a letter or digit, and may hold
  /// spaces, apostrophes, ampersands and full stops in between.
  ///
  /// Markdown syntax characters are deliberately excluded, so isolating a run
  /// can never land inside `**bold**`, a `[link](url)`, a heading marker or a
  /// list bullet and change how the document parses.
  static final RegExp _latinRun = RegExp(
    r"[A-Za-z][A-Za-z0-9 '’&.]*[A-Za-z0-9]|[A-Za-z]",
  );

  /// Isolates every Latin run in [text].
  ///
  /// Runs already isolated are left alone, so this is safe to apply twice.
  static String isolateLatin(String text) {
    if (text.isEmpty) return text;

    return text.splitMapJoin(
      _latinRun,
      onMatch: (Match match) {
        final String run = match[0]!;
        final String input = match.input;

        // The isolates sit outside the run, so idempotence has to be checked
        // against the surrounding characters rather than the match itself.
        final bool alreadyIsolated = match.start > 0 &&
            input[match.start - 1] == fsi &&
            match.end < input.length &&
            input[match.end] == pdi;

        return alreadyIsolated ? run : '$fsi$run$pdi';
      },
      onNonMatch: (String other) => other,
    );
  }

  /// [isolateLatin], applied only when the text will be laid out right to
  /// left. In an LTR paragraph the isolates would be invisible but pointless.
  static String forDirection(String text, {required bool isRtl}) =>
      isRtl ? isolateLatin(text) : text;

  /// Strips the isolate marks again — for tests, and for anything that has to
  /// compare rendered text against what the model actually wrote.
  static String strip(String text) =>
      text.replaceAll(fsi, '').replaceAll(pdi, '');

  const BidiText._();
}
