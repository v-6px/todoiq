import 'package:flutter/widgets.dart';

import '../models/ai_failure.dart';

/// Every user-facing string, in English, Arabic and French.
///
/// Hand-written rather than generated: the app has one screen's worth of
/// strings per phase and no translator pipeline, so an abstract class with one
/// implementation per language keeps everything type-checked without adding
/// codegen. Adding a language means implementing every member — the compiler
/// will not let a translation ship half-finished.
abstract class AppStrings {
  const AppStrings();

  /// The languages the app offers.
  static const List<String> supportedLanguageCodes = <String>[
    'en',
    'ar',
    'fr',
  ];

  static const AppStrings en = _EnStrings();
  static const AppStrings ar = _ArStrings();
  static const AppStrings fr = _FrStrings();

  /// Strings for [languageCode], falling back to English for anything the
  /// app does not carry.
  static AppStrings forLanguage(String languageCode) {
    switch (languageCode) {
      case 'ar':
        return ar;
      case 'fr':
        return fr;
      default:
        return en;
    }
  }

  static AppStrings forLocale(Locale locale) =>
      forLanguage(locale.languageCode);

  /// Strings for the locale currently in scope.
  static AppStrings of(BuildContext context) =>
      forLocale(Localizations.localeOf(context));

  String get languageCode;

  /// Text direction for this language.
  TextDirection get textDirection =>
      languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr;

  // --- Home -------------------------------------------------------------
  /// The product name, identical in both languages — a brand is not
  /// translated, and this is what sits next to the launcher icon.
  String get appTitle;
  String get nothingScheduledToday;
  String get nothingScheduledThisDay;
  String get emptyStateHint;
  String get newTask;
  String get previousDay;
  String get nextDay;
  String get today;
  String get aiReports;
  String get aiCoach;
  String get settings;
  String get back;

  /// "nothing scheduled" / "3 of 5 left" / "all 4 done".
  String summaryNothingScheduled();
  String summaryAllDone(int total);
  String summaryRemaining(int pending, int total);

  // --- Task card --------------------------------------------------------
  String get statusDone;
  String get statusPartial;
  String get statusSkipped;
  String get statusPending;
  String get actionComplete;
  String get actionPartial;
  String get actionSkip;

  // --- Add task ---------------------------------------------------------
  String get addTaskTitle;
  String get addTaskHint;
  String get addTaskEmptyError;
  String get addTaskSaveError;

  /// Shown when the row was written but the OS refused the alarm.
  String get taskSavedReminderFailed;

  // --- Exact-alarm permission banner ------------------------------------
  String get exactAlarmBannerTitle;
  String get exactAlarmBannerBody;
  String get exactAlarmBannerAction;
  String get exactAlarmBannerDismiss;
  String get addTaskButton;
  String get addTaskSaving;

  // --- Editing and deleting ---------------------------------------------
  String get editTaskTitle;
  String get editTaskButton;
  String get deleteTask;
  String get taskDeleted;
  String get undo;
  String get changeTime;
  String get timeHasPassedNotice;
  String get dateLabel;
  String get timeLabel;
  String get dateToday;
  String get dateTomorrow;
  String get datePick;
  String get repeatLabel;
  String get repeatOnce;
  String get repeatDaily;
  String get repeatSpecificDays;
  String get pickAtLeastOneDay;
  String get repeatsDaily;

  /// "Repeats Mon, Wed" — [days] is already localised and joined.
  String repeatsOn(String days);

  // --- Note sheet -------------------------------------------------------
  String get notePromptPartial;
  String get notePromptSkipped;
  String get notePromptGeneric;
  String get noteHint;
  String get noteSave;
  String get noteSkip;

  // --- Settings ---------------------------------------------------------
  String get settingsProvider;
  String get settingsCredentials;
  String get settingsLanguage;
  String get settingsApiKey;
  String get settingsApiKeyHint;
  String get settingsBaseUrl;
  String get settingsBaseUrlHint;
  String get settingsModel;
  String get settingsModelHint;
  String get settingsShowKey;
  String get settingsHideKey;
  String get settingsTestConnection;
  String get settingsTesting;
  String get settingsSave;
  String get settingsSaving;
  String get settingsSaved;
  String get settingsPrivacyNote;
  String get languageEnglish;
  String get languageArabic;
  String get languageFrench;

  String contactingEndpoint(String baseUrl);
  String connectedTo(String model);
  String get enterApiKeyFirst;
  String get enterBaseUrlFirst;
  String get enterModelFirst;

  // --- Report -----------------------------------------------------------
  String get reportTitle;
  String get rangeToday;
  String get rangeLastThreeDays;
  String get rangeThisWeek;
  String get statCompleted;
  String get statPartial;
  String get statSkipped;
  String get generateDebrief;
  String get generatingDebrief;
  String get noTasksInRange;
  String get nothingResolvedYet;
  String get regenerateDebrief;

  /// Caption over a stored debrief, e.g. "Generated 12 Sep, 14:30".
  String reportGeneratedAt(String when);

  // Section headings the model is told to write, verbatim. Localised so an
  // Arabic debrief does not come back with English headings stranded in an
  // otherwise right-to-left document. The emoji that precede them live in
  // DebriefService, so every language carries the same three marks.
  String get reportHeadingSummary;
  String get reportHeadingBottlenecks;
  String get reportHeadingNextSteps;
  String get openSettings;
  String get debriefFailed;

  /// A short, friendly explanation of an AI failure — never the provider's
  /// raw error body.
  String aiFailure(AiFailure kind);

  // --- Coach ------------------------------------------------------------
  String get coachTitle;
  String get coachEmptyTitle;
  String get coachEmptyHint;
  String get coachInputHint;
  String get coachThinking;
  String get coachGenericError;
  String get send;

  /// Label on the card the coach attaches when it proposes a task.
  String get coachAddTaskButton;
  String get coachAddingTask;
  String get coachTaskAdded;
  String get coachTaskAddFailed;
  String get coachProposedTask;
  String get clearChat;
  String get chatCleared;

  // --- Notifications ----------------------------------------------------
  /// Body shown under the task title in the alarm, e.g. "Scheduled for 14:30".
  String notificationBody(String time);

  // --- AI prompts -------------------------------------------------------
  /// Appended to every system prompt so replies come back in this language.
  String get replyLanguageInstruction;
}

class _EnStrings extends AppStrings {
  const _EnStrings();

  @override
  String get languageCode => 'en';

  @override
  String get appTitle => 'ToDoIQ';
  @override
  String get nothingScheduledToday => 'Nothing scheduled today.';
  @override
  String get nothingScheduledThisDay => 'Nothing scheduled this day.';
  @override
  String get emptyStateHint =>
      'Add the first task and it will alarm on time, offline.';
  @override
  String get newTask => 'New task';
  @override
  String get previousDay => 'Previous day';
  @override
  String get nextDay => 'Next day';
  @override
  String get today => 'Today';
  @override
  String get aiReports => 'AI reports';
  @override
  String get aiCoach => 'Personal Assistant';
  @override
  String get settings => 'Settings';
  @override
  String get back => 'Back';

  @override
  String summaryNothingScheduled() => 'nothing scheduled';
  @override
  String summaryAllDone(int total) => 'all $total done';
  @override
  String summaryRemaining(int pending, int total) =>
      '$pending of $total left';

  @override
  String get statusDone => 'Done';
  @override
  String get statusPartial => 'Partial';
  @override
  String get statusSkipped => 'Skipped';
  @override
  String get statusPending => 'Pending';
  @override
  String get actionComplete => 'Complete';
  @override
  String get actionPartial => 'Partial progress';
  @override
  String get actionSkip => 'Skip';

  @override
  String get addTaskTitle => 'New task';
  @override
  String get addTaskHint => 'What needs doing?';
  @override
  String get addTaskEmptyError => 'Give the task a name.';
  @override
  String get addTaskSaveError => 'Could not save the task. Please try again.';
  @override
  String get taskSavedReminderFailed =>
      'Task saved, but the reminder could not be set. Check notification '
      'and alarm permissions.';

  @override
  String get exactAlarmBannerTitle => 'Reminders cannot be set';
  @override
  String get exactAlarmBannerBody =>
      'Android is blocking exact alarms for this app, so your tasks will not '
      'notify you at their scheduled time.';
  @override
  String get exactAlarmBannerAction => 'Allow alarms';
  @override
  String get exactAlarmBannerDismiss => 'Not now';
  @override
  String get addTaskButton => 'Add task';
  @override
  String get addTaskSaving => 'Saving…';
  @override
  String get editTaskTitle => 'Edit task';
  @override
  String get editTaskButton => 'Save changes';
  @override
  String get deleteTask => 'Delete';
  @override
  String get taskDeleted => 'Task deleted';
  @override
  String get undo => 'Undo';
  @override
  String get changeTime => 'Change';
  @override
  String get timeHasPassedNotice =>
      'That time has passed — the task is saved without a reminder.';
  @override
  String get dateLabel => 'Date';
  @override
  String get timeLabel => 'Time';
  @override
  String get dateToday => 'Today';
  @override
  String get dateTomorrow => 'Tomorrow';
  @override
  String get datePick => 'Pick a date';
  @override
  String get repeatLabel => 'Repeat';
  @override
  String get repeatOnce => 'Once';
  @override
  String get repeatDaily => 'Daily';
  @override
  String get repeatSpecificDays => 'Specific days';
  @override
  String get pickAtLeastOneDay => 'Choose at least one day.';
  @override
  String get repeatsDaily => 'Repeats daily';
  @override
  String repeatsOn(String days) => 'Repeats $days';

  @override
  String get notePromptPartial => 'What stopped you finishing?';
  @override
  String get notePromptSkipped => 'What got in the way?';
  @override
  String get notePromptGeneric => 'Add a quick reason (optional)';
  @override
  String get noteHint => 'Ran out of time, blocked on review…';
  @override
  String get noteSave => 'Save';
  @override
  String get noteSkip => 'Skip';

  @override
  String get settingsProvider => 'Provider';
  @override
  String get settingsCredentials => 'Credentials';
  @override
  String get settingsLanguage => 'Language';
  @override
  String get settingsApiKey => 'API key';
  @override
  String get settingsApiKeyHint => 'sk-…';
  @override
  String get settingsBaseUrl => 'Base URL';
  @override
  String get settingsBaseUrlHint => 'https://api.example.com/v1';
  @override
  String get settingsModel => 'Model name';
  @override
  String get settingsModelHint => 'gemini-3.6-flash';
  @override
  String get settingsShowKey => 'Show key';
  @override
  String get settingsHideKey => 'Hide key';
  @override
  String get settingsTestConnection => 'Test connection';
  @override
  String get settingsTesting => 'Testing…';
  @override
  String get settingsSave => 'Save';
  @override
  String get settingsSaving => 'Saving…';
  @override
  String get settingsSaved => 'Settings saved.';
  @override
  String get settingsPrivacyNote =>
      'Tasks, alarms and history stay on this device. These credentials are '
      'only used for the AI debrief and the assistant.';
  @override
  String get languageEnglish => 'English';
  @override
  String get languageArabic => 'العربية';
  @override
  String get languageFrench => 'Français';

  @override
  String contactingEndpoint(String baseUrl) => 'Contacting $baseUrl…';
  @override
  String connectedTo(String model) => 'Connected. $model responded.';
  @override
  String get enterApiKeyFirst => 'Enter an API key first.';
  @override
  String get enterBaseUrlFirst => 'Enter a base URL first.';
  @override
  String get enterModelFirst => 'Enter a model name first.';

  @override
  String get reportTitle => 'Debrief';
  @override
  String get rangeToday => 'Today';
  @override
  String get rangeLastThreeDays => 'Last 3 days';
  @override
  String get rangeThisWeek => 'This week';
  @override
  String get statCompleted => 'Completed';
  @override
  String get statPartial => 'Partial';
  @override
  String get statSkipped => 'Skipped';
  @override
  String get generateDebrief => 'Generate AI debrief';
  @override
  String get generatingDebrief => 'Generating…';
  @override
  String get noTasksInRange =>
      'No tasks in this range yet. Add a few and come back once the day has '
      'played out.';
  @override
  String get nothingResolvedYet =>
      'Nothing has been marked done, partial or skipped yet — the debrief '
      'will have little to work with.';
  @override
  String get regenerateDebrief => 'Re-generate';
  @override
  String reportGeneratedAt(String when) => 'Generated $when';
  @override
  String get reportHeadingSummary => 'Completion summary';
  @override
  String get reportHeadingBottlenecks => 'Where it broke down';
  @override
  String get reportHeadingNextSteps => 'Correction plan for tomorrow';
  @override
  String get openSettings => 'Open Settings';
  @override
  String get debriefFailed => 'Something went wrong generating the debrief.';
  @override
  String aiFailure(AiFailure kind) {
    switch (kind) {
      case AiFailure.missingConfiguration:
        return 'Add your API key, base URL and model in Settings first.';
      case AiFailure.invalidUrl:
        return 'The base URL in Settings is not a valid address.';
      case AiFailure.unauthorized:
        return 'Your API key was not accepted. Check it in Settings.';
      case AiFailure.notFound:
        return 'The service or model was not found. Check the base URL and '
            'model name in Settings.';
      case AiFailure.rateLimited:
        return 'Too many requests right now. Wait a minute and try again.';
      case AiFailure.unavailable:
        return 'The AI service is busy at the moment. Please try again in a '
            'little while.';
      case AiFailure.network:
        return 'Could not connect. Check your internet connection and try '
            'again.';
      case AiFailure.emptyResponse:
      case AiFailure.other:
        return 'The report could not be generated this time. Please try '
            'again.';
    }
  }

  @override
  String get coachTitle => 'Personal Assistant';
  @override
  String get coachEmptyTitle => 'Your assistant has today\'s log.';
  @override
  String get coachEmptyHint =>
      'Ask what went wrong, or what to do with the time that is left.';
  @override
  String get coachInputHint => 'Why did today stall?';
  @override
  String get coachThinking => 'Thinking…';
  @override
  String get coachGenericError => 'Something went wrong. Try again.';
  @override
  String get send => 'Send';
  @override
  String get coachAddTaskButton => '➕ Add Task to Schedule';
  @override
  String get coachAddingTask => 'Adding…';
  @override
  String get coachTaskAdded => 'Task added to your schedule.';
  @override
  String get coachTaskAddFailed => 'Could not add the task. Try again.';
  @override
  String get coachProposedTask => 'Suggested task';
  @override
  String get clearChat => 'Clear chat';
  @override
  String get chatCleared => 'Conversation cleared.';

  @override
  String notificationBody(String time) => 'Scheduled for $time';

  @override
  String get replyLanguageInstruction => 'Reply in English.';
}

class _ArStrings extends AppStrings {
  const _ArStrings();

  @override
  String get languageCode => 'ar';

  @override
  String get appTitle => 'ToDoIQ';
  @override
  String get nothingScheduledToday => 'لا مهام اليوم.';
  @override
  String get nothingScheduledThisDay => 'لا مهام في هذا اليوم.';
  @override
  String get emptyStateHint =>
      'أضف أول مهمة وسينبّهك المنبّه في وقتها، دون إنترنت.';
  @override
  String get newTask => 'مهمة جديدة';
  @override
  String get previousDay => 'اليوم السابق';
  @override
  String get nextDay => 'اليوم التالي';
  @override
  String get today => 'اليوم';
  @override
  String get aiReports => 'التقارير';
  @override
  String get aiCoach => 'المساعد الشخصي';
  @override
  String get settings => 'الإعدادات';
  @override
  String get back => 'رجوع';

  @override
  String summaryNothingScheduled() => 'لا شيء مجدول';
  @override
  String summaryAllDone(int total) => 'أُنجزت كلها ($total)';
  @override
  String summaryRemaining(int pending, int total) =>
      'بقيت $pending من $total';

  @override
  String get statusDone => 'مكتملة';
  @override
  String get statusPartial => 'جزئية';
  @override
  String get statusSkipped => 'متجاوَزة';
  @override
  String get statusPending => 'معلّقة';
  @override
  String get actionComplete => 'إكمال';
  @override
  String get actionPartial => 'إنجاز جزئي';
  @override
  String get actionSkip => 'تجاوز';

  @override
  String get addTaskTitle => 'مهمة جديدة';
  @override
  String get addTaskHint => 'ما الذي تريد إنجازه؟';
  @override
  String get addTaskEmptyError => 'اكتب اسمًا للمهمة.';
  @override
  String get addTaskSaveError => 'تعذّر حفظ المهمة. حاول مرة أخرى.';
  @override
  String get taskSavedReminderFailed =>
      'تم حفظ المهمة، لكن تعذّر ضبط التذكير. تحقّق من أذونات الإشعارات '
      'والمنبّهات.';

  @override
  String get exactAlarmBannerTitle => 'التذكيرات معطّلة';
  @override
  String get exactAlarmBannerBody =>
      'يمنع نظام أندرويد المنبّهات الدقيقة لهذا التطبيق، لذلك لن تصلك '
      'تنبيهات مهامك في مواعيدها.';
  @override
  String get exactAlarmBannerAction => 'السماح بالمنبّهات';
  @override
  String get exactAlarmBannerDismiss => 'ليس الآن';
  @override
  String get addTaskButton => 'إضافة المهمة';
  @override
  String get addTaskSaving => 'جارٍ الحفظ…';
  @override
  String get editTaskTitle => 'تعديل المهمة';
  @override
  String get editTaskButton => 'حفظ التعديلات';
  @override
  String get deleteTask => 'حذف';
  @override
  String get taskDeleted => 'حُذفت المهمة';
  @override
  String get undo => 'تراجع';
  @override
  String get changeTime => 'تغيير';
  @override
  String get timeHasPassedNotice =>
      'مضى هذا الوقت — ستُحفظ المهمة دون تنبيه.';
  @override
  String get dateLabel => 'التاريخ';
  @override
  String get timeLabel => 'الوقت';
  @override
  String get dateToday => 'اليوم';
  @override
  String get dateTomorrow => 'غدًا';
  @override
  String get datePick => 'اختر تاريخًا';
  @override
  String get repeatLabel => 'التكرار';
  @override
  String get repeatOnce => 'مرة واحدة';
  @override
  String get repeatDaily => 'يوميًا';
  @override
  String get repeatSpecificDays => 'أيام محددة';
  @override
  String get pickAtLeastOneDay => 'اختر يومًا واحدًا على الأقل.';
  @override
  String get repeatsDaily => 'يتكرر يوميًا';
  @override
  String repeatsOn(String days) => 'يتكرر: $days';

  @override
  String get notePromptPartial => 'ما الذي منعك من الإكمال؟ (اختياري)';
  @override
  String get notePromptSkipped => 'ما الذي عطّلك؟ (اختياري)';
  @override
  String get notePromptGeneric => 'أضف سببًا سريعًا (اختياري)';
  @override
  String get noteHint => 'لم يتّسع الوقت، بانتظار المراجعة…';
  @override
  String get noteSave => 'حفظ';
  @override
  String get noteSkip => 'تخطّي';

  @override
  String get settingsProvider => 'المزوّد';
  @override
  String get settingsCredentials => 'بيانات الاعتماد';
  @override
  String get settingsLanguage => 'اللغة';
  @override
  String get settingsApiKey => 'مفتاح الواجهة';
  @override
  String get settingsApiKeyHint => 'sk-…';
  @override
  String get settingsBaseUrl => 'الرابط الأساسي';
  @override
  String get settingsBaseUrlHint => 'https://api.example.com/v1';
  @override
  String get settingsModel => 'اسم النموذج';
  @override
  String get settingsModelHint => 'gemini-3.6-flash';
  @override
  String get settingsShowKey => 'إظهار المفتاح';
  @override
  String get settingsHideKey => 'إخفاء المفتاح';
  @override
  String get settingsTestConnection => 'اختبار الاتصال';
  @override
  String get settingsTesting => 'جارٍ الاختبار…';
  @override
  String get settingsSave => 'حفظ';
  @override
  String get settingsSaving => 'جارٍ الحفظ…';
  @override
  String get settingsSaved => 'حُفظت الإعدادات.';
  @override
  String get settingsPrivacyNote =>
      'المهام والمنبّهات والسجلّ تبقى على هذا الجهاز. تُستخدم بيانات '
      'الاعتماد هذه للتقارير والمساعد الشخصي فقط.';
  @override
  String get languageEnglish => 'English';
  @override
  String get languageArabic => 'العربية';
  @override
  String get languageFrench => 'Français';

  @override
  String contactingEndpoint(String baseUrl) => 'جارٍ الاتصال بـ $baseUrl…';
  @override
  String connectedTo(String model) => 'تم الاتصال. استجاب $model.';
  @override
  String get enterApiKeyFirst => 'أدخل مفتاح الواجهة أولًا.';
  @override
  String get enterBaseUrlFirst => 'أدخل الرابط الأساسي أولًا.';
  @override
  String get enterModelFirst => 'أدخل اسم النموذج أولًا.';

  @override
  String get reportTitle => 'الحصيلة';
  @override
  String get rangeToday => 'اليوم';
  @override
  String get rangeLastThreeDays => 'آخر ٣ أيام';
  @override
  String get rangeThisWeek => 'هذا الأسبوع';
  @override
  String get statCompleted => 'مكتملة';
  @override
  String get statPartial => 'جزئية';
  @override
  String get statSkipped => 'متجاوَزة';
  @override
  String get generateDebrief => 'أنشئ الحصيلة';
  @override
  String get generatingDebrief => 'جارٍ الإنشاء…';
  @override
  String get noTasksInRange =>
      'لا مهام في هذه الفترة بعد. أضف بعضها وعُد بعد أن ينقضي اليوم.';
  @override
  String get nothingResolvedYet =>
      'لم تُعلَّم أي مهمة كمكتملة أو جزئية أو متجاوَزة بعد — لن تجد الحصيلة '
      'الكثير لتحلّله.';
  @override
  String get regenerateDebrief => 'إعادة إنشاء';
  @override
  String reportGeneratedAt(String when) => 'أُنشئت في $when';
  @override
  String get reportHeadingSummary => 'خلاصة الإنجاز';
  @override
  String get reportHeadingBottlenecks => 'نقاط التعثر والخلل';
  @override
  String get reportHeadingNextSteps => 'خطة الضبط لليوم القادم';
  @override
  String get openSettings => 'فتح الإعدادات';
  @override
  String get debriefFailed => 'تعذّر إنشاء الحصيلة.';
  @override
  String aiFailure(AiFailure kind) {
    switch (kind) {
      case AiFailure.missingConfiguration:
        return 'أضف مفتاح الواجهة البرمجية والرابط والنموذج من الإعدادات أولًا.';
      case AiFailure.invalidUrl:
        return 'الرابط الأساسي في الإعدادات غير صالح.';
      case AiFailure.unauthorized:
        return 'لم يُقبل مفتاح الواجهة البرمجية. تحقّق منه في الإعدادات.';
      case AiFailure.notFound:
        return 'لم يُعثر على الخدمة أو النموذج. تحقّق من الرابط واسم النموذج '
            'في الإعدادات.';
      case AiFailure.rateLimited:
        return 'طلبات كثيرة في وقت قصير. انتظر دقيقة ثم حاول مجددًا.';
      case AiFailure.unavailable:
        return 'خدمة الذكاء الاصطناعي مشغولة حاليًا. يُرجى المحاولة مرة أخرى '
            'بعد قليل.';
      case AiFailure.network:
        return 'تعذّر الاتصال. تحقّق من اتصالك بالإنترنت ثم حاول مجددًا.';
      case AiFailure.emptyResponse:
      case AiFailure.other:
        return 'تعذّر إنشاء التقرير هذه المرة. يُرجى المحاولة مرة أخرى.';
    }
  }

  @override
  String get coachTitle => 'المساعد الشخصي';
  @override
  String get coachEmptyTitle => 'مساعدك يعرف مهام يومك.';
  @override
  String get coachEmptyHint =>
      'اسأله عمّا تعثّر، أو كيف تستثمر ما تبقّى من الوقت.';
  @override
  String get coachInputHint => 'لماذا تعثّر يومي؟';
  @override
  String get coachThinking => 'يفكّر…';
  @override
  String get coachGenericError => 'حدث خطأ ما. حاول مرة أخرى.';
  @override
  String get send => 'إرسال';
  @override
  String get coachAddTaskButton =>
      '➕ إضافة المهمة إلى الجدول';
  @override
  String get coachAddingTask => 'جارٍ الإضافة…';
  @override
  String get coachTaskAdded => 'تمت إضافة المهمة إلى جدولك.';
  @override
  String get coachTaskAddFailed =>
      'تعذّرت إضافة المهمة. حاول مرة أخرى.';
  @override
  String get coachProposedTask => 'مهمة مقترحة';
  @override
  String get clearChat => 'مسح المحادثة';
  @override
  String get chatCleared => 'تم مسح المحادثة.';

  @override
  String notificationBody(String time) => 'موعد المهمة: $time';

  @override
  String get replyLanguageInstruction =>
      'أجب بالعربية الفصحى المبسّطة، بأسلوب واضح ومباشر.';
}

class _FrStrings extends AppStrings {
  const _FrStrings();

  @override
  String get languageCode => 'fr';

  @override
  String get appTitle => 'ToDoIQ';
  @override
  String get nothingScheduledToday => 'Rien de prévu aujourd’hui.';
  @override
  String get nothingScheduledThisDay => 'Rien de prévu ce jour-là.';
  @override
  String get emptyStateHint =>
      'Ajoutez une première tâche : son alarme sonnera à l’heure, même '
      'hors connexion.';
  @override
  String get newTask => 'Nouvelle tâche';
  @override
  String get previousDay => 'Jour précédent';
  @override
  String get nextDay => 'Jour suivant';
  @override
  String get today => 'Aujourd’hui';
  @override
  String get aiReports => 'Bilans IA';
  @override
  String get aiCoach => 'Assistant personnel';
  @override
  String get settings => 'Réglages';
  @override
  String get back => 'Retour';

  @override
  String summaryNothingScheduled() => 'rien de prévu';
  @override
  String summaryAllDone(int total) =>
      total == 1 ? 'la seule tâche est faite' : 'les $total tâches sont faites';
  @override
  String summaryRemaining(int pending, int total) =>
      '$pending sur $total restantes';

  @override
  String get statusDone => 'Faite';
  @override
  String get statusPartial => 'Partielle';
  @override
  String get statusSkipped => 'Passée';
  @override
  String get statusPending => 'À faire';
  @override
  String get actionComplete => 'Terminer';
  @override
  String get actionPartial => 'Avancée partielle';
  @override
  String get actionSkip => 'Passer';

  @override
  String get addTaskTitle => 'Nouvelle tâche';
  @override
  String get addTaskHint => 'Qu’y a-t-il à faire ?';
  @override
  String get addTaskEmptyError => 'Donnez un nom à la tâche.';
  @override
  String get addTaskSaveError =>
      'Impossible d’enregistrer la tâche. Réessayez.';
  @override
  String get taskSavedReminderFailed =>
      'Tâche enregistrée, mais le rappel n’a pas pu être programmé. '
      'Vérifiez les autorisations de notifications et d’alarmes.';

  @override
  String get exactAlarmBannerTitle =>
      'Les rappels ne peuvent pas être programmés';
  @override
  String get exactAlarmBannerBody =>
      'Android bloque les alarmes exactes pour cette application : vos tâches '
      'ne vous préviendront pas à l’heure prévue.';
  @override
  String get exactAlarmBannerAction => 'Autoriser les alarmes';
  @override
  String get exactAlarmBannerDismiss => 'Plus tard';
  @override
  String get addTaskButton => 'Ajouter la tâche';
  @override
  String get addTaskSaving => 'Enregistrement…';
  @override
  String get editTaskTitle => 'Modifier la tâche';
  @override
  String get editTaskButton => 'Enregistrer les modifications';
  @override
  String get deleteTask => 'Supprimer';
  @override
  String get taskDeleted => 'Tâche supprimée';
  @override
  String get undo => 'Annuler';
  @override
  String get changeTime => 'Modifier';
  @override
  String get timeHasPassedNotice =>
      'Cette heure est passée — la tâche est enregistrée sans rappel.';
  @override
  String get dateLabel => 'Date';
  @override
  String get timeLabel => 'Heure';
  @override
  String get dateToday => 'Aujourd’hui';
  @override
  String get dateTomorrow => 'Demain';
  @override
  String get datePick => 'Choisir une date';
  @override
  String get repeatLabel => 'Répétition';
  @override
  String get repeatOnce => 'Une fois';
  @override
  String get repeatDaily => 'Chaque jour';
  @override
  String get repeatSpecificDays => 'Jours précis';
  @override
  String get pickAtLeastOneDay => 'Choisissez au moins un jour.';
  @override
  String get repeatsDaily => 'Se répète chaque jour';
  @override
  String repeatsOn(String days) => 'Se répète : $days';

  @override
  String get notePromptPartial => 'Qu’est-ce qui vous a empêché de finir ?';
  @override
  String get notePromptSkipped => 'Qu’est-ce qui vous a bloqué ?';
  @override
  String get notePromptGeneric => 'Ajoutez une raison courte (facultatif)';
  @override
  String get noteHint => 'Manque de temps, en attente d’une relecture…';
  @override
  String get noteSave => 'Enregistrer';
  @override
  String get noteSkip => 'Passer';

  @override
  String get settingsProvider => 'Fournisseur';
  @override
  String get settingsCredentials => 'Identifiants';
  @override
  String get settingsLanguage => 'Langue';
  @override
  String get settingsApiKey => 'Clé API';
  @override
  String get settingsApiKeyHint => 'sk-…';
  @override
  String get settingsBaseUrl => 'URL de base';
  @override
  String get settingsBaseUrlHint => 'https://api.example.com/v1';
  @override
  String get settingsModel => 'Nom du modèle';
  @override
  String get settingsModelHint => 'gemini-3.6-flash';
  @override
  String get settingsShowKey => 'Afficher la clé';
  @override
  String get settingsHideKey => 'Masquer la clé';
  @override
  String get settingsTestConnection => 'Tester la connexion';
  @override
  String get settingsTesting => 'Test en cours…';
  @override
  String get settingsSave => 'Enregistrer';
  @override
  String get settingsSaving => 'Enregistrement…';
  @override
  String get settingsSaved => 'Réglages enregistrés.';
  @override
  String get settingsPrivacyNote =>
      'Vos tâches, alarmes et historique restent sur cet appareil. Ces '
      'identifiants ne servent qu’au bilan et à l’assistant.';
  @override
  String get languageEnglish => 'English';
  @override
  String get languageArabic => 'العربية';
  @override
  String get languageFrench => 'Français';

  @override
  String contactingEndpoint(String baseUrl) => 'Connexion à $baseUrl…';
  @override
  String connectedTo(String model) => 'Connecté. $model a répondu.';
  @override
  String get enterApiKeyFirst => 'Saisissez d’abord une clé API.';
  @override
  String get enterBaseUrlFirst => 'Saisissez d’abord une URL de base.';
  @override
  String get enterModelFirst => 'Saisissez d’abord un nom de modèle.';

  @override
  String get reportTitle => 'Bilan';
  @override
  String get rangeToday => 'Aujourd’hui';
  @override
  String get rangeLastThreeDays => '3 derniers jours';
  @override
  String get rangeThisWeek => 'Cette semaine';
  @override
  String get statCompleted => 'Terminées';
  @override
  String get statPartial => 'Partielles';
  @override
  String get statSkipped => 'Passées';
  @override
  String get generateDebrief => 'Générer le bilan IA';
  @override
  String get generatingDebrief => 'Génération…';
  @override
  String get noTasksInRange =>
      'Aucune tâche sur cette période. Ajoutez-en quelques-unes et revenez '
      'une fois la journée écoulée.';
  @override
  String get nothingResolvedYet =>
      'Aucune tâche n’est encore marquée faite, partielle ou passée — le '
      'bilan aura peu de matière.';
  @override
  String get regenerateDebrief => 'Regénérer';
  @override
  String reportGeneratedAt(String when) => 'Généré le $when';
  @override
  String get reportHeadingSummary => 'Bilan d\u2019exécution';
  @override
  String get reportHeadingBottlenecks => 'Points de blocage';
  @override
  String get reportHeadingNextSteps => 'Plan de redressement';
  @override
  String get openSettings => 'Ouvrir les réglages';
  @override
  String get debriefFailed => 'La génération du bilan a échoué.';
  @override
  String aiFailure(AiFailure kind) {
    switch (kind) {
      case AiFailure.missingConfiguration:
        return 'Ajoutez d’abord votre clé API, l’URL et le modèle dans les '
            'Réglages.';
      case AiFailure.invalidUrl:
        return 'L’URL de base dans les Réglages n’est pas une adresse valide.';
      case AiFailure.unauthorized:
        return 'Votre clé API a été refusée. Vérifiez-la dans les Réglages.';
      case AiFailure.notFound:
        return 'Service ou modèle introuvable. Vérifiez l’URL et le nom du '
            'modèle dans les Réglages.';
      case AiFailure.rateLimited:
        return 'Trop de requêtes pour le moment. Patientez une minute puis '
            'réessayez.';
      case AiFailure.unavailable:
        return 'Le service d’IA est surchargé pour le moment. Réessayez dans '
            'un instant.';
      case AiFailure.network:
        return 'Connexion impossible. Vérifiez votre accès à Internet puis '
            'réessayez.';
      case AiFailure.emptyResponse:
      case AiFailure.other:
        return 'Le rapport n’a pas pu être généré cette fois. Réessayez.';
    }
  }

  @override
  String get coachTitle => 'Assistant personnel';
  @override
  String get coachEmptyTitle =>
      'Votre assistant connaît vos tâches du jour.';
  @override
  String get coachEmptyHint =>
      'Demandez-lui ce qui a coincé, ou quoi faire du temps qu’il reste.';
  @override
  String get coachInputHint => 'Pourquoi la journée a-t-elle calé ?';
  @override
  String get coachThinking => 'Réflexion…';
  @override
  String get coachGenericError =>
      'Une erreur est survenue. Réessayez.';
  @override
  String get send => 'Envoyer';
  @override
  String get coachAddTaskButton => '➕ Ajouter la tâche au planning';
  @override
  String get coachAddingTask => 'Ajout…';
  @override
  String get coachTaskAdded => 'Tâche ajoutée à votre planning.';
  @override
  String get coachTaskAddFailed =>
      'Impossible d’ajouter la tâche. Réessayez.';
  @override
  String get coachProposedTask => 'Tâche suggérée';
  @override
  String get clearChat => 'Effacer la conversation';
  @override
  String get chatCleared => 'Conversation effacée.';

  @override
  String notificationBody(String time) => 'Prévu pour $time';

  @override
  String get replyLanguageInstruction =>
      'Réponds en français, dans un style clair et direct.';
}
