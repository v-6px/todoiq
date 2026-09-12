import 'package:flutter/widgets.dart';

import 'settings_service.dart';

/// Holds the active locale and rebuilds the app when it changes.
///
/// A [ValueNotifier] rather than a full state-management package: there is
/// exactly one value, one writer (the settings screen) and one listener (the
/// root [MaterialApp]), so anything heavier would be ceremony. Switching
/// language takes effect immediately — no restart.
class LocaleController extends ValueNotifier<Locale> {
  LocaleController._(super.initial);

  static final LocaleController instance =
      LocaleController._(const Locale('ar'));

  String get languageCode => value.languageCode;

  bool get isArabic => languageCode == 'ar';

  /// Reads the stored preference (or the device locale) into the notifier.
  /// Call once during start-up, before the first frame.
  Future<void> load() async {
    final String code = await SettingsService.instance.getLanguageCode();
    value = Locale(code);
  }

  /// Switches language and persists the choice.
  Future<void> setLanguage(String code) async {
    if (!SettingsService.supportedLanguageCodes.contains(code)) return;
    await SettingsService.instance.setLanguageCode(code);
    value = Locale(code);
  }

  /// Sets the locale without persisting. Tests only.
  @visibleForTesting
  void setForTesting(String code) {
    value = Locale(code);
  }
}
