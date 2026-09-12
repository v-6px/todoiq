import 'package:flutter/material.dart';

/// Design tokens from `skill.md`.
///
/// The source system is a marketing-site language; this app takes its palette,
/// type scale, radii and spacing and drops the page-level signatures (the
/// half-bleed portrait hero, the closing teal band) that have no dashboard
/// equivalent. The palette discipline still holds: indigo, violet-soft, teal
/// and the off-warm-greys, and body text is never pure black.
class AppColors {
  static const Color primary = Color(0xFF1B1938);
  static const Color primaryDeep = Color(0xFF0E0C1F);
  static const Color onPrimary = Color(0xFFFFFFFF);

  static const Color ink = Color(0xFF292827);
  static const Color inkMute = Color(0xFF73706D);
  static const Color inkFaint = Color(0xFF9A9794);

  static const Color canvas = Color(0xFFFFFFFF);
  static const Color canvasSoft = Color(0xFFFAFAF8);

  static const Color violetSoft = Color(0xFFC9B4FA);
  static const Color tealDeep = Color(0xFF0E3030);
  static const Color tealMid = Color(0xFF155555);

  static const Color hairline = Color(0xFFE8E4DD);
  static const Color hairlineDark = Color(0xFF3F3A52);

  const AppColors._();
}

/// 8px base with 2/4/12 sub-tokens for fine work.
class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 64;

  const AppSpacing._();
}

class AppRadius {
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;

  const AppRadius._();
}

/// The type scale, with the source system's tight display leading and
/// negative tracking preserved.
///
/// The brand's sub-default variable weights (460 / 540 / 600) need a variable
/// font binary; with the system font stack available here they map to the
/// nearest fixed weights — 460 to w500, 540 and 600 to w600.
class AppText {
  static const TextStyle displayLg = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.14,
    letterSpacing: -0.63,
    color: AppColors.ink,
  );

  static const TextStyle displayMd = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.1,
    letterSpacing: -0.315,
    color: AppColors.ink,
  );

  static const TextStyle headingLg = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: -0.4,
    color: AppColors.ink,
  );

  static const TextStyle bodyMd = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    height: 1.5,
    color: AppColors.ink,
  );

  static const TextStyle buttonMd = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1,
    color: AppColors.onPrimary,
  );

  static const TextStyle buttonCap = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1,
    color: AppColors.ink,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: AppColors.inkMute,
  );

  static const TextStyle micro = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.4,
    color: AppColors.inkMute,
  );

  const AppText._();
}

/// Assembles the tokens into the app's [ThemeData].
class AppTheme {
  /// The Arabic display family, converted from the supplied
  /// `thmanyah-sans-Regular.woff2` and registered in `pubspec.yaml`.
  static const String arabicFontFamily = 'Thmanyah';

  /// The family for [languageCode], or null to keep the platform default.
  ///
  /// Thmanyah carries Arabic, Latin and Arabic-Indic digits, but only a
  /// Regular weight — so in Arabic the heavier tokens render at 400.
  static String? fontFamilyForLanguage(String languageCode) =>
      languageCode == 'ar' ? arabicFontFamily : null;

  static String? fontFamilyForLocale(Locale locale) =>
      fontFamilyForLanguage(locale.languageCode);

  /// The theme for [locale]. Arabic swaps in Thmanyah across every token.
  ///
  /// The typography tokens deliberately leave `fontFamily` null, so Flutter's
  /// style merge lets this one setting reach every [Text] in the tree.
  static ThemeData forLocale(Locale locale) =>
      _build(fontFamilyForLocale(locale));

  /// English theme. Kept for call sites that are language-independent.
  static ThemeData get light => _build(null);

  static ThemeData _build(String? fontFamily) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(seedColor: AppColors.primary).copyWith(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      surface: AppColors.canvas,
      onSurface: AppColors.ink,
    );

    const TextTheme baseTextTheme = TextTheme(
      displayMedium: AppText.displayLg,
      headlineSmall: AppText.displayMd,
      titleLarge: AppText.headingLg,
      bodyLarge: AppText.bodyMd,
      bodyMedium: AppText.caption,
      labelSmall: AppText.micro,
    );

    // An explicitly supplied textTheme is not re-processed by ThemeData's
    // fontFamily, so the family is applied here. This is what lets every
    // widget that leaves fontFamily null inherit Thmanyah under Arabic.
    final TextTheme textTheme = fontFamily == null
        ? baseTextTheme
        : baseTextTheme.apply(fontFamily: fontFamily);

    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      splashFactory: InkSparkle.splashFactory,
      textTheme: textTheme,
      // The source system's buttons are rounded rectangles at 8px, never pills.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          textStyle: AppText.buttonMd,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.canvas,
        hintStyle: AppText.bodyMd.copyWith(color: AppColors.inkFaint),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: _inputBorder(AppColors.hairline),
        enabledBorder: _inputBorder(AppColors.hairline),
        focusedBorder: _inputBorder(AppColors.primary),
        errorBorder: _inputBorder(AppColors.inkMute),
        focusedErrorBorder: _inputBorder(AppColors.primary),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.primary,
        contentTextStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: AppColors.onPrimary,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius:
            const BorderRadius.all(Radius.circular(AppRadius.sm)),
        borderSide: BorderSide(color: color),
      );

  const AppTheme._();
}
