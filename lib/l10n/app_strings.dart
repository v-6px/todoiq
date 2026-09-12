import 'package:flutter/widgets.dart';

/// Every user-facing string, in English and Arabic.
///
/// Hand-written rather than generated: the app has one screen's worth of
/// strings per phase and no translator pipeline, so an abstract class with two
/// implementations keeps everything type-checked without adding codegen.
abstract class AppStrings {
  const AppStrings();

  /// The languages the app offers.
  static const List<String> supportedLanguageCodes = <String>['en', 'ar'];

  static const AppStrings en = _EnStrings();
  static const AppStrings ar = _ArStrings();

  static AppStrings forLanguage(String languageCode) =>
      languageCode == 'ar' ? ar : en;

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

  // Section headings the model is told to write. Localised so an Arabic
  // debrief does not come back with English headings stranded in an
  // otherwise right-to-left document.
  String get reportHeadingSummary;
  String get reportHeadingBottlenecks;
  String get reportHeadingNextSteps;
  String get openSettings;
  String get debriefFailed;

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
  String get aiCoach => 'AI coach';
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
      'only used for the AI debrief and coach.';
  @override
  String get languageEnglish => 'English';
  @override
  String get languageArabic => 'العربية';

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
  String get reportHeadingSummary => 'Summary';
  @override
  String get reportHeadingBottlenecks => 'Obstacles';
  @override
  String get reportHeadingNextSteps => 'Tomorrow\u2019s steps';
  @override
  String get openSettings => 'Open Settings';
  @override
  String get debriefFailed => 'Something went wrong generating the debrief.';

  @override
  String get coachTitle => 'Coach';
  @override
  String get coachEmptyTitle => 'Your coach has today\'s log.';
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
  String get aiCoach => 'المدرّب';
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
      'الاعتماد هذه للتقارير والمدرّب فقط.';
  @override
  String get languageEnglish => 'English';
  @override
  String get languageArabic => 'العربية';

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
  String get reportHeadingSummary => 'الملخص';
  @override
  String get reportHeadingBottlenecks => 'المعوقات';
  @override
  String get reportHeadingNextSteps => 'خطوات الغد';
  @override
  String get openSettings => 'فتح الإعدادات';
  @override
  String get debriefFailed => 'تعذّر إنشاء الحصيلة.';

  @override
  String get coachTitle => 'المدرّب';
  @override
  String get coachEmptyTitle => 'مدرّبك يعرف مهام يومك.';
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
  String notificationBody(String time) => 'موعد المهمة: $time';

  @override
  String get replyLanguageInstruction =>
      'أجب بالعربية الفصحى المبسّطة، بأسلوب واضح ومباشر.';
}
