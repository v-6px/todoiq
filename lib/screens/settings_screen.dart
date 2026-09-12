import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../l10n/app_strings.dart';
import '../models/task_model.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/locale_controller.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// Outcome of a "Test connection" ping, rendered as an inline status line.
enum _TestOutcome { none, running, success, failure }

/// BYOK credentials for any OpenAI-compatible endpoint.
///
/// Nothing here is required for the app to work — tasks, alarms and storage
/// are fully offline. These values only power the AI debrief and coach.
class SettingsScreen extends StatefulWidget {
  static const Key apiKeyFieldKey = Key('settings_api_key_field');
  static const Key baseUrlFieldKey = Key('settings_base_url_field');
  static const Key modelFieldKey = Key('settings_model_field');
  static const Key visibilityToggleKey = Key('settings_visibility_toggle');
  static const Key testButtonKey = Key('settings_test_button');
  static const Key saveButtonKey = Key('settings_save_button');
  static const Key backKey = Key('settings_back');

  static Key languageKey(String code) => Key('settings_language_$code');

  static Key presetKey(String label) => Key('settings_preset_$label');

  /// Injectable so tests can drive the connection test without a network.
  final http.Client? client;

  const SettingsScreen({super.key, this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _model = TextEditingController();

  late final AiService _ai = AiService(client: widget.client);

  /// True when the key should be rendered as dots.
  bool _obscureKey = true;
  bool _loading = true;
  bool _saving = false;

  /// The language currently selected in the picker.
  String _languageCode = LocaleController.instance.languageCode;

  _TestOutcome _outcome = _TestOutcome.none;
  String _outcomeMessage = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _baseUrl.dispose();
    _model.dispose();
    // AiService closes only a client it created; an injected one belongs to
    // the caller.
    _ai.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final SettingsService settings = SettingsService.instance;
    final String key = await settings.getApiKey();
    final String url = await settings.getBaseUrl();
    final String model = await settings.getModelName();
    final String language = await settings.getLanguageCode();

    if (!mounted) return;
    setState(() {
      _apiKey.text = key;
      _baseUrl.text = url;
      _model.text = model;
      _languageCode = language;
      _loading = false;
    });
  }

  void _applyPreset(ProviderPreset preset) {
    setState(() {
      _baseUrl.text = preset.baseUrl;
      _model.text = preset.modelName;
      // The endpoint changed, so any previous result no longer describes it.
      _outcome = _TestOutcome.none;
      _outcomeMessage = '';
    });
  }

  /// Switches language immediately — the root MaterialApp listens to the
  /// controller, so the whole app re-renders without a restart.
  Future<void> _selectLanguage(String code) async {
    if (code == _languageCode) return;
    setState(() => _languageCode = code);
    await LocaleController.instance.setLanguage(code);

    // Alarms carry the wording they were created with, so pending ones are
    // re-armed in the new language rather than left in the old one.
    final List<Task> live =
        await DatabaseService.instance.getTasksWithLiveAlarms();
    await NotificationService.instance.rescheduleAll(live);
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    await SettingsService.instance.saveAll(
      apiKey: _apiKey.text,
      baseUrl: _baseUrl.text,
      modelName: _model.text,
    );

    if (!mounted) return;
    setState(() {
      // Reflect the normalised base URL back, so what is shown is what is
      // stored.
      _baseUrl.text = SettingsService.normalizeBaseUrl(_baseUrl.text);
      _saving = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.of(context).settingsSaved)),
    );
  }

  /// Sends a 2-token ping to `{base_url}/chat/completions`.
  ///
  /// Deliberately the smallest possible real request: it proves the endpoint,
  /// the key and the model name all work together, which a HEAD request or a
  /// models listing would not.
  Future<void> _testConnection() async {
    final String key = _apiKey.text.trim();
    final String baseUrl = SettingsService.normalizeBaseUrl(_baseUrl.text);
    final String model = _model.text.trim();

    final AppStrings strings = AppStrings.of(context);

    if (key.isEmpty) {
      _setOutcome(_TestOutcome.failure, strings.enterApiKeyFirst);
      return;
    }
    if (baseUrl.isEmpty) {
      _setOutcome(_TestOutcome.failure, strings.enterBaseUrlFirst);
      return;
    }
    if (model.isEmpty) {
      _setOutcome(_TestOutcome.failure, strings.enterModelFirst);
      return;
    }

    _setOutcome(_TestOutcome.running, strings.contactingEndpoint(baseUrl));

    try {
      await _ai.testConnection(
        credentials: AiCredentials(
          apiKey: key,
          baseUrl: baseUrl,
          model: model,
        ),
      );
      if (!mounted) return;
      _setOutcome(_TestOutcome.success, strings.connectedTo(model));
    } on AiException catch (error) {
      if (!mounted) return;
      _setOutcome(_TestOutcome.failure, error.message);
    } catch (_) {
      if (!mounted) return;
      _setOutcome(
        _TestOutcome.failure,
        const AiException(
          'Could not reach the endpoint. Check the URL and your connection.',
        ).message,
      );
    }
  }

  void _setOutcome(_TestOutcome outcome, String message) {
    setState(() {
      _outcome = outcome;
      _outcomeMessage = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: _loading
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.md,
                  AppSpacing.xl,
                  AppSpacing.xxl,
                ),
                children: <Widget>[
                  _header(context, strings),
                  const SizedBox(height: AppSpacing.xl),
                  _SectionLabel(strings.settingsLanguage),
                  const SizedBox(height: AppSpacing.sm),
                  _languageSelector(strings),
                  const SizedBox(height: AppSpacing.xl),
                  _SectionLabel(strings.settingsProvider),
                  const SizedBox(height: AppSpacing.sm),
                  _presets(),
                  const SizedBox(height: AppSpacing.xl),
                  _SectionLabel(strings.settingsCredentials),
                  const SizedBox(height: AppSpacing.sm),
                  _apiKeyField(strings),
                  const SizedBox(height: AppSpacing.md),
                  _field(
                    fieldKey: SettingsScreen.baseUrlFieldKey,
                    controller: _baseUrl,
                    label: strings.settingsBaseUrl,
                    hint: strings.settingsBaseUrlHint,
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _field(
                    fieldKey: SettingsScreen.modelFieldKey,
                    controller: _model,
                    label: strings.settingsModel,
                    hint: strings.settingsModelHint,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  _actions(strings),
                  if (_outcome != _TestOutcome.none) ...<Widget>[
                    const SizedBox(height: AppSpacing.md),
                    _outcomeLine(),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  Text(strings.settingsPrivacyNote, style: AppText.micro),
                ],
              ),
      ),
    );
  }

  Widget _header(BuildContext context, AppStrings strings) {
    return Row(
      children: <Widget>[
        IconButton(
          key: SettingsScreen.backKey,
          onPressed: () => Navigator.of(context).pop(),
          // The arrow mirrors under RTL so it still reads as "back".
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
        Text(strings.settings, style: AppText.displayLg),
      ],
    );
  }

  /// Two chips, styled like the provider presets so the screen reads as one
  /// system.
  Widget _languageSelector(AppStrings strings) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        _PresetChip(
          chipKey: SettingsScreen.languageKey('en'),
          label: strings.languageEnglish,
          isActive: _languageCode == 'en',
          onTap: () => _selectLanguage('en'),
        ),
        _PresetChip(
          chipKey: SettingsScreen.languageKey('ar'),
          label: strings.languageArabic,
          isActive: _languageCode == 'ar',
          onTap: () => _selectLanguage('ar'),
        ),
      ],
    );
  }

  Widget _presets() {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: SettingsService.presets.map((ProviderPreset preset) {
        final bool isActive =
            SettingsService.normalizeBaseUrl(_baseUrl.text) == preset.baseUrl;
        return _PresetChip(
          chipKey: SettingsScreen.presetKey(preset.label),
          label: preset.label,
          isActive: isActive,
          onTap: () => _applyPreset(preset),
        );
      }).toList(),
    );
  }

  Widget _apiKeyField(AppStrings strings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(strings.settingsApiKey, style: AppText.micro),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          key: SettingsScreen.apiKeyFieldKey,
          controller: _apiKey,
          obscureText: _obscureKey,
          autocorrect: false,
          enableSuggestions: false,
          // Keys, URLs and model ids are Latin identifiers: they stay
          // left-to-right even when the rest of the screen is mirrored.
          textDirection: TextDirection.ltr,
          style: AppText.bodyMd,
          decoration: InputDecoration(
            hintText: strings.settingsApiKeyHint,
            suffixIcon: IconButton(
              key: SettingsScreen.visibilityToggleKey,
              onPressed: () => setState(() => _obscureKey = !_obscureKey),
              icon: Icon(
                _obscureKey
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
              color: AppColors.inkMute,
              tooltip: _obscureKey
                  ? strings.settingsShowKey
                  : strings.settingsHideKey,
            ),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required Key fieldKey,
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: AppText.micro),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          key: fieldKey,
          controller: controller,
          autocorrect: false,
          keyboardType: keyboardType,
          textDirection: TextDirection.ltr,
          style: AppText.bodyMd,
          decoration: InputDecoration(hintText: hint),
          onChanged: (_) {
            // Editing by hand can change which preset is highlighted.
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }

  Widget _actions(AppStrings strings) {
    final bool busy = _outcome == _TestOutcome.running || _saving;

    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton(
            key: SettingsScreen.testButtonKey,
            onPressed: busy ? null : _testConnection,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.ink,
              textStyle: AppText.buttonMd,
              side: const BorderSide(color: AppColors.hairlineDark),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl,
                vertical: AppSpacing.md,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.all(Radius.circular(AppRadius.md)),
              ),
            ),
            child: Text(
              _outcome == _TestOutcome.running
                  ? strings.settingsTesting
                  : strings.settingsTestConnection,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: FilledButton(
            key: SettingsScreen.saveButtonKey,
            onPressed: busy ? null : _save,
            child: Text(
              _saving ? strings.settingsSaving : strings.settingsSave,
            ),
          ),
        ),
      ],
    );
  }

  Widget _outcomeLine() {
    final Color color = switch (_outcome) {
      _TestOutcome.success => AppColors.tealDeep,
      _TestOutcome.failure => AppColors.primary,
      _ => AppColors.inkMute,
    };

    final IconData icon = switch (_outcome) {
      _TestOutcome.success => Icons.check_circle_outline_rounded,
      _TestOutcome.failure => Icons.error_outline_rounded,
      _ => Icons.hourglass_empty_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.canvasSoft,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _outcomeMessage,
              style: AppText.caption.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppText.headingLg);
  }
}

/// Quick-fill chip for a provider preset. Pill-shaped per the source system's
/// `pill-tab-light` component.
class _PresetChip extends StatelessWidget {
  final Key chipKey;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _PresetChip({
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
