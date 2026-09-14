import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';

/// A named BYOK provider configuration offered in the settings screen.
class ProviderPreset {
  final String label;
  final String baseUrl;
  final String modelName;

  const ProviderPreset({
    required this.label,
    required this.baseUrl,
    required this.modelName,
  });
}

/// Reads and writes BYOK credentials via `shared_preferences`.
///
/// Nothing here talks to the network — it only persists what the user typed.
/// The app works fully offline; these values are read by the AI layer later.
class SettingsService {
  static const String _apiKeyKey = 'api_key';
  static const String _baseUrlKey = 'base_url';
  static const String _modelNameKey = 'model_name';
  static const String _languageKey = 'language_code';

  static const String defaultApiKey = '';
  static const String defaultBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';
  static const String defaultModelName = 'gemini-3.6-flash';

  /// Used when the device locale is neither English nor Arabic.
  static const String fallbackLanguageCode = 'ar';

  /// Mirrors [AppStrings.supportedLanguageCodes]; a language the strings do
  /// not carry must never be storable.
  static const List<String> supportedLanguageCodes =
      AppStrings.supportedLanguageCodes;

  /// Presets for the settings dropdown. All are OpenAI-compatible endpoints.
  static const List<ProviderPreset> presets = <ProviderPreset>[
    ProviderPreset(
      label: 'Gemini Flash',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      modelName: 'gemini-3.6-flash',
    ),
    ProviderPreset(
      label: 'Groq',
      baseUrl: 'https://api.groq.com/openai/v1',
      modelName: 'llama-3.3-70b-versatile',
    ),
    ProviderPreset(
      label: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelName: 'openai/gpt-4o-mini',
    ),
    ProviderPreset(
      label: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      modelName: 'gpt-4o-mini',
    ),
  ];

  SettingsService._internal();

  static final SettingsService instance = SettingsService._internal();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Loads the backing store. Call once during app start-up so later reads
  /// are synchronous from the plugin's in-memory cache.
  Future<void> init() async {
    await _preferences;
  }

  // --- Reads --------------------------------------------------------------

  Future<String> getApiKey() async {
    final SharedPreferences prefs = await _preferences;
    return prefs.getString(_apiKeyKey) ?? defaultApiKey;
  }

  Future<String> getBaseUrl() async {
    final SharedPreferences prefs = await _preferences;
    return prefs.getString(_baseUrlKey) ?? defaultBaseUrl;
  }

  Future<String> getModelName() async {
    final SharedPreferences prefs = await _preferences;
    return prefs.getString(_modelNameKey) ?? defaultModelName;
  }

  /// True once an API key has been stored, i.e. the AI features are usable.
  Future<bool> isConfigured() async {
    final String key = await getApiKey();
    return key.trim().isNotEmpty;
  }

  /// The stored UI language, or the device's if nothing has been chosen.
  ///
  /// A device set to English gets English; anything else falls back to Arabic,
  /// which is the app's primary language.
  Future<String> getLanguageCode() async {
    final SharedPreferences prefs = await _preferences;
    final String? stored = prefs.getString(_languageKey);
    if (stored != null && supportedLanguageCodes.contains(stored)) {
      return stored;
    }
    return resolveDeviceLanguage();
  }

  /// True once the user has picked a language explicitly, so the device
  /// locale should stop overriding it.
  Future<bool> hasLanguagePreference() async {
    final SharedPreferences prefs = await _preferences;
    return prefs.getString(_languageKey) != null;
  }

  /// Maps the platform locale onto a language the app actually ships.
  static String resolveDeviceLanguage([Locale? locale]) {
    final Locale device =
        locale ?? PlatformDispatcher.instance.locale;
    if (supportedLanguageCodes.contains(device.languageCode)) {
      return device.languageCode;
    }
    return fallbackLanguageCode;
  }

  // --- Writes -------------------------------------------------------------

  Future<void> setApiKey(String value) async {
    final SharedPreferences prefs = await _preferences;
    await prefs.setString(_apiKeyKey, value.trim());
  }

  /// Stores [value] without its trailing slash, so callers can safely append
  /// `/chat/completions`.
  Future<void> setBaseUrl(String value) async {
    final SharedPreferences prefs = await _preferences;
    await prefs.setString(_baseUrlKey, normalizeBaseUrl(value));
  }

  Future<void> setModelName(String value) async {
    final SharedPreferences prefs = await _preferences;
    await prefs.setString(_modelNameKey, value.trim());
  }

  Future<void> setLanguageCode(String value) async {
    assert(
      supportedLanguageCodes.contains(value),
      'Unsupported language: $value',
    );
    final SharedPreferences prefs = await _preferences;
    await prefs.setString(_languageKey, value);
  }

  /// Writes all three fields in one call.
  Future<void> saveAll({
    required String apiKey,
    required String baseUrl,
    required String modelName,
  }) async {
    await setApiKey(apiKey);
    await setBaseUrl(baseUrl);
    await setModelName(modelName);
  }

  /// Restores the defaults, clearing the stored API key.
  Future<void> resetToDefaults() async {
    final SharedPreferences prefs = await _preferences;
    await prefs.remove(_apiKeyKey);
    await prefs.remove(_baseUrlKey);
    await prefs.remove(_modelNameKey);
  }

  /// Forgets an explicit language choice, returning to the device locale.
  Future<void> clearLanguagePreference() async {
    final SharedPreferences prefs = await _preferences;
    await prefs.remove(_languageKey);
  }

  /// Drops the cached [SharedPreferences] handle.
  ///
  /// Tests only: the singleton would otherwise keep serving the store it
  /// loaded first, so a later `setMockInitialValues` would have no effect.
  @visibleForTesting
  void resetCacheForTesting() {
    _prefs = null;
  }

  /// Trims whitespace and any trailing slashes from a base URL.
  static String normalizeBaseUrl(String value) {
    // Every whitespace character goes, not just the ends: a base URL is
    // usually pasted, and a stray newline or non-breaking space in the middle
    // is invisible in the field but makes Uri.parse throw.
    String url = value.replaceAll(RegExp(r'\s'), '');
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// The chat-completions endpoint for the stored base URL.
  Future<String> getChatCompletionsUrl() async {
    final String baseUrl = await getBaseUrl();
    return '${normalizeBaseUrl(baseUrl)}/chat/completions';
  }
}
