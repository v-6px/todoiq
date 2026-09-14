import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';
import '../models/chat_message_model.dart';
import '../models/task_action.dart';
import '../models/task_model.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/task_card.dart';
import 'settings_screen.dart';

/// A conversation with a coach that already knows the day's task log.
///
/// The system turn is built once from SQLite — titles, statuses and the notes
/// the user wrote when marking something partial or skipped — so the first
/// question does not have to explain the situation.
class ChatCoachScreen extends StatefulWidget {
  static const Key backKey = Key('coach_back');
  static const Key inputKey = Key('coach_input');
  static const Key sendKey = Key('coach_send');
  static const Key listKey = Key('coach_list');
  static const Key settingsShortcutKey = Key('coach_settings_shortcut');
  static const Key menuKey = Key('coach_menu');
  static const Key clearChatKey = Key('coach_clear_chat');

  static Key bubbleKey(int index) => Key('coach_bubble_$index');

  /// The card under a reply that proposed a task, and its confirm button.
  static Key taskActionKey(int index) => Key('coach_task_action_$index');

  static Key taskActionAddKey(int index) => Key('coach_task_add_$index');

  /// The day to coach on. Injectable so tests are not clock-dependent.
  final DateTime? day;

  /// The real today, which relative dates ("tomorrow") are worked out from.
  ///
  /// Distinct from [day]: opened while browsing next Friday, the log is
  /// Friday's but "tomorrow" still means the day after today. Defaults to
  /// [day] when injected, else the device's local date.
  final DateTime? today;
  final http.Client? client;

  const ChatCoachScreen({super.key, this.day, this.today, this.client});

  /// Builds the task-aware system turn.
  ///
  /// Notes are the point: they are the only record of *why* something stalled,
  /// so they are quoted verbatim next to the task they belong to.
  static String buildSystemPrompt(
    List<Task> tasks,
    DateTime day, {
    AppStrings strings = AppStrings.en,
    DateTime? today,
  }) {
    // The log stays in English so the model reads a stable format; the reply
    // language is set explicitly at the end.
    final DateFormat timeFormat = DateFormat.Hm('en');
    final StringBuffer buffer = StringBuffer()
      ..writeln('You are a practical productivity coach talking with someone '
          'about their day. Be brief and concrete — two or three short '
          'paragraphs at most, and ask a follow-up question when it would '
          'help. Reference their real tasks by name. Never invent tasks that '
          'are not listed. Plain, warm language; no corporate jargon.')
      ..writeln()
      ..writeln(taskActionInstructions(today ?? day))
      ..writeln()
      ..writeln('Their task log for '
          "${DateFormat('EEEE d MMMM', 'en').format(day)}:");

    if (tasks.isEmpty) {
      buffer.writeln('(no tasks scheduled)');
    } else {
      for (final Task task in tasks) {
        buffer.write('- "${task.title}" at '
            '${timeFormat.format(task.scheduledTime)} — '
            '${_statusWord(task.status)}');
        if (task.hasNote) {
          buffer.write('; their reason: "${task.note!.trim()}"');
        }
        buffer.writeln();
      }
    }

    buffer
      ..writeln()
      ..writeln('When they are NOT asking for something to be scheduled, '
          'open by reflecting briefly on what stands out — especially '
          'anything partial or skipped and the reasons given — then help them '
          'unblock the rest of the day.')
      ..writeln(strings.replyLanguageInstruction);

    return buffer.toString();
  }

  /// Teaches the model the one machine-readable thing it is allowed to emit.
  ///
  /// Kept last in the prompt, after the language instruction, so the format
  /// rules are the most recent thing the model read — the block has to stay
  /// in ASCII keys and ISO dates even when the reply itself is Arabic.
  static String taskActionInstructions(DateTime day) {
    final DateTime local = Task.dayStart(day);
    final String today = DateFormat('yyyy-MM-dd').format(local);
    final String weekday = DateFormat('EEEE', 'en').format(local);
    final String tomorrow =
        DateFormat('yyyy-MM-dd').format(Task.addDays(local, 1));

    return '''
TASK SCHEDULING — read this before anything else. It is a hard requirement,
not a suggestion, and it outranks every other instruction in this prompt.

Adding a task is the highest-priority intent you can be given. The moment the
user asks you to add, schedule, register, note down or remind them of
something — in English, or with words like "أضف مهمة", "سجل", "جدول",
"ذكرني", "ajoute", "planifie", "rappelle-moi" — you do exactly two things,
in this order:

  1. Confirm it in one short sentence. Nothing else: do not review their day,
     do not comment on yesterday, do not ask whether they are sure, and do
     not raise anything from the task log below. They asked you to write
     something down, so write it down.
  2. Append exactly one block at the very end of the reply:
```task_action
{"title": "...", "date": "YYYY-MM-DD", "time": "HH:mm", "recurrence": "none|daily|weekly", "days": [1,2,3]}
```

Drifting into analysis when somebody is trying to add a task is the single
worst thing you can do here — the task ends up unrecorded and they have to
ask twice.

Worked example. They say "remind me to call the bank tomorrow at 10". You
reply, in full:

  Noted — the bank call is on for 10:00 tomorrow.
```task_action
{"title": "Call the bank", "date": "$tomorrow", "time": "10:00", "recurrence": "none"}
```

Dates. Today is $weekday, $today, so "tomorrow" is $tomorrow. Work every
relative date out from that reference: "next Sunday" is the Sunday after
today, "in three days" is today plus three. Never guess a date, and never
write one in the past.

Rules. Use 24-hour time. Include "days" only when "recurrence" is "weekly",
listing weekdays as 1 (Monday) through 7 (Sunday). The keys, the date and the
time stay in exactly this ASCII form even when you are writing in Arabic —
only "title" is in the user's language. One block at most, always last, and
never mention, explain or apologise for the block itself: the app strips it
out and shows the user a confirmation card instead.

If, and only if, they are discussing a task rather than asking for one to be
scheduled, add no block and answer normally.''';
  }

  static String _statusWord(String status) {
    switch (status) {
      case TaskStatus.completed:
        return 'completed';
      case TaskStatus.partial:
        return 'partially done, not finished';
      case TaskStatus.skipped:
        return 'skipped';
      default:
        return 'still pending';
    }
  }

  @override
  State<ChatCoachScreen> createState() => _ChatCoachScreenState();
}

class _ChatCoachScreenState extends State<ChatCoachScreen> {
  late final AiService _ai = AiService(client: widget.client);
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// The system turn, held apart from [_visible] so it is never rendered.
  String _systemPrompt = '';

  /// Everything shown in the list, oldest first.
  final List<ChatMessage> _visible = <ChatMessage>[];

  /// Tasks the coach proposed, keyed by the index of the message they came
  /// with. Indexes are stable — messages are only appended, and the pending
  /// placeholder is replaced in place — so the card stays under its reply.
  final Map<int, _ProposedTask> _proposals = <int, _ProposedTask>{};

  bool _loading = true;
  bool _sending = false;
  bool _lastErrorWasConfiguration = false;

  DateTime get _day => (widget.day ?? DateTime.now()).toLocal();

  /// What relative dates in a reply are resolved against.
  DateTime get _today =>
      (widget.today ?? widget.day ?? DateTime.now()).toLocal();

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  @override
  void dispose() {
    _ai.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadContext() async {
    final List<Task> tasks =
        await DatabaseService.instance.getTasksForDate(_day);
    final List<ChatMessage> stored =
        await DatabaseService.instance.getChatMessages();
    if (!mounted) return;

    setState(() {
      _systemPrompt = ChatCoachScreen.buildSystemPrompt(
        tasks,
        _day,
        strings: AppStrings.of(context),
        today: _today,
      );

      _visible
        ..clear()
        ..addAll(_restore(stored));
      _loading = false;
    });

    if (_visible.isNotEmpty) _scrollToEnd();
  }

  /// Rebuilds the rendered conversation from stored turns.
  ///
  /// Assistant turns were stored raw, so the action block is parsed out again
  /// here: the prose is shown, the JSON is not, and a task the assistant
  /// proposed last night is still offered as a card this morning.
  List<ChatMessage> _restore(List<ChatMessage> stored) {
    final List<ChatMessage> restored = <ChatMessage>[];

    for (final ChatMessage message in stored) {
      if (!message.isAssistant) {
        restored.add(message);
        continue;
      }

      final CoachReply parsed = CoachReply.parse(message.content, now: _today);
      if (parsed.action != null) {
        _proposals[restored.length] = _ProposedTask(
          parsed.action!,
          messageId: message.id,
          // A proposal already accepted comes back as a receipt, not as a
          // button — otherwise reopening the screen is an invitation to
          // create the same task again.
          added: message.actionAdded,
        );
      }
      restored.add(message.copyWith(content: parsed.text));
    }

    return restored;
  }

  /// Writes one turn to the conversation history, without blocking the UI on
  /// it. A reply the user can already read is worth more than a guaranteed
  /// write, so a failure here is logged and dropped.
  Future<int?> _persist(ChatMessage message) async {
    try {
      return await DatabaseService.instance.insertChatMessage(message);
    } catch (error, stack) {
      debugPrint('ChatCoachScreen: could not store a ${message.role} turn '
          'with ${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'ChatCoachScreen');
      return null;
    }
  }

  /// Empties the conversation, on screen and on disk.
  Future<void> _clearChat(AppStrings strings) async {
    setState(() {
      _visible.clear();
      _proposals.clear();
      _lastErrorWasConfiguration = false;
    });

    await DatabaseService.instance.clearChatMessages();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(strings.chatCleared),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _send() async {
    final AppStrings strings = AppStrings.of(context);
    final String text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    _input.clear();
    final ChatMessage question = ChatMessage.user(text);
    setState(() {
      _visible.add(question);
      _visible.add(ChatMessage.assistant('', isPending: true));
      _sending = true;
      _lastErrorWasConfiguration = false;
    });
    _scrollToEnd();

    // Stored as asked, before the reply is known: a question that failed to
    // send is still part of the conversation the user had.
    await _persist(question);

    try {
      final String reply = await _ai.complete(
        <AiMessage>[
          AiMessage.system(_systemPrompt),
          // Only real turns go to the model; the pending placeholder and any
          // earlier failures are UI state, not conversation.
          for (final ChatMessage message in _visible)
            if (message.isSendable)
              AiMessage(role: message.role, content: message.content),
        ],
        maxTokens: AiService.coachMaxTokens,
        temperature: 0.8,
      );

      if (!mounted) return;
      // The block is stripped before the text is stored, so the raw JSON is
      // never rendered and never echoed back into the next turn's history.
      final CoachReply parsed = CoachReply.parse(reply, now: _today);

      // A model that talked about scheduling and then shipped no block is a
      // prompt problem, not a user error — and it is invisible from the
      // screen, so it goes to the log where it can be found. Deliberately not
      // recovered from: a task the user never confirmed is worse than one
      // they have to ask for twice.
      if (!parsed.hasAction && parsed.promisedScheduling) {
        debugPrint('ChatCoachScreen: the reply reads as a scheduling promise '
            'but carried no task_action block. Reply was: ${parsed.text}');
      }

      // A reply that was one unreadable block leaves nothing to show and
      // nothing to schedule; say so rather than open a blank bubble.
      final bool unusable = parsed.text.isEmpty && parsed.action == null;

      setState(() {
        final int index = _replacePending(
          unusable
              ? ChatMessage.assistant(strings.coachGenericError, isError: true)
              : ChatMessage.assistant(parsed.text),
        );
        if (parsed.action != null) {
          _proposals[index] = _ProposedTask(parsed.action!);
        }
        _sending = false;
      });

      // Stored raw, block and all. Stripping it here would lose the proposal
      // on the next launch; it is parsed out again on the way back in.
      if (!unusable) {
        final int? rowId = await _persist(ChatMessage.assistant(reply));
        // The card needs to know which row to mark once it is confirmed.
        _proposals[_visible.length - 1]?.messageId = rowId;
      }
    } on AiException catch (error) {
      // Status and provider body go to the log; the bubble gets one plain
      // sentence in the user's language, never the raw JSON.
      debugPrint('ChatCoachScreen: reply failed (${error.kind}): '
          '${error.message}');
      if (!mounted) return;
      setState(() {
        _replacePending(
          ChatMessage.assistant(
            _friendlyError(error.kind, strings),
            isError: true,
          ),
        );
        _lastErrorWasConfiguration = error.isConfigurationError;
        _sending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _replacePending(
          ChatMessage.assistant(strings.coachGenericError, isError: true),
        );
        _sending = false;
      });
    }
    _scrollToEnd();
  }

  /// The shared translated explanation for [kind], except where that one
  /// talks about a report — in a conversation the coach's own wording fits.
  static String _friendlyError(AiFailure kind, AppStrings strings) {
    switch (kind) {
      case AiFailure.emptyResponse:
      case AiFailure.other:
        return strings.coachGenericError;
      default:
        return strings.aiFailure(kind);
    }
  }

  /// Returns the index the replacement landed at.
  int _replacePending(ChatMessage replacement) {
    final int index =
        _visible.indexWhere((ChatMessage m) => m.isPending);
    if (index == -1) {
      _visible.add(replacement);
      return _visible.length - 1;
    }
    _visible[index] = replacement;
    return index;
  }

  /// Commits a proposed task: one row, then its alarms.
  ///
  /// Deliberately tap-to-confirm rather than automatic — the model is being
  /// trusted with a date and a repeat rule, and a wrong one silently landing
  /// in the schedule is worse than one extra tap.
  Future<void> _addProposedTask(int index, AppStrings strings) async {
    final _ProposedTask? proposal = _proposals[index];
    if (proposal == null || proposal.adding || proposal.added) return;

    setState(() => proposal.adding = true);

    final Task saved;
    try {
      final Task task = proposal.action.toTask();
      saved = task.copyWith(id: await DatabaseService.instance.insertTask(task));
    } catch (error, stack) {
      debugPrint('ChatCoachScreen: insert failed for '
          '"${proposal.action.title}" with ${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'ChatCoachScreen');

      if (!mounted) return;
      setState(() => proposal.adding = false);
      _toast(strings.coachTaskAddFailed);
      return;
    }

    // Saved either way past this point; a refused alarm is reported as such
    // rather than as a failed add.
    final int? armed = await NotificationService.instance.trySchedule(saved);

    // Recorded before anything else can interrupt, so closing the screen
    // straight after confirming still leaves the proposal marked as taken.
    final int? messageId = proposal.messageId;
    if (messageId != null) {
      try {
        await DatabaseService.instance.markChatActionAdded(messageId);
      } catch (error, stack) {
        debugPrint('ChatCoachScreen: could not mark chat row $messageId as '
            'added, so its card may be offered again: $error');
        debugPrintStack(stackTrace: stack, label: 'ChatCoachScreen');
      }
    }

    if (!mounted) return;
    setState(() {
      proposal.adding = false;
      proposal.added = true;
    });
    _toast(armed == null
        ? strings.taskSavedReminderFailed
        : strings.coachTaskAdded);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: AppText.bodyMd.copyWith(
            color: AppColors.onPrimary,
          )),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// Keeps the newest message in view after each turn.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _header(context, strings),
            Expanded(
              child: _loading
                  ? const SizedBox.shrink()
                  : _visible.isEmpty
                      ? _CoachEmptyState(strings: strings)
                      : _messageList(strings),
            ),
            if (_lastErrorWasConfiguration)
              _settingsShortcut(context, strings),
            _composer(strings),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppStrings strings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.xl,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: ChatCoachScreen.backKey,
            onPressed: () => Navigator.of(context).pop(),
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
          Expanded(
            child: Text(strings.coachTitle, style: AppText.displayLg),
          ),
          // Only offered once there is something to clear.
          if (_visible.isNotEmpty)
            PopupMenuButton<String>(
              key: ChatCoachScreen.menuKey,
              icon: const Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: AppColors.inkMute,
              ),
              tooltip: strings.clearChat,
              position: PopupMenuPosition.under,
              onSelected: (_) => _clearChat(strings),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  key: ChatCoachScreen.clearChatKey,
                  value: 'clear',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: AppColors.inkMute,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(strings.clearChat, style: AppText.bodyMd),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _messageList(AppStrings strings) {
    return ListView.builder(
      key: ChatCoachScreen.listKey,
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      itemCount: _visible.length,
      itemBuilder: (BuildContext context, int index) {
        return _Bubble(
          bubbleKey: ChatCoachScreen.bubbleKey(index),
          message: _visible[index],
          strings: strings,
          index: index,
          proposal: _proposals[index],
          onAddTask: () => _addProposedTask(index, strings),
        );
      },
    );
  }

  Widget _settingsShortcut(BuildContext context, AppStrings strings) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: ChatCoachScreen.settingsShortcutKey,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const SettingsScreen(),
            ),
          ),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            textStyle: AppText.buttonCap,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(strings.openSettings),
        ),
      ),
    );
  }

  Widget _composer(AppStrings strings) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: AppColors.canvas,
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              key: ChatCoachScreen.inputKey,
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              style: AppText.bodyMd,
              decoration: InputDecoration(hintText: strings.coachInputHint),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Material(
            color: _sending ? AppColors.hairline : AppColors.primary,
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.md)),
            child: InkWell(
              key: ChatCoachScreen.sendKey,
              onTap: _sending ? null : _send,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.md)),
              child: Tooltip(
                message: strings.send,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    size: 20,
                    color: _sending ? AppColors.inkFaint : AppColors.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoachEmptyState extends StatelessWidget {
  final AppStrings strings;

  const _CoachEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(strings.coachEmptyTitle, style: AppText.displayMd),
            const SizedBox(height: AppSpacing.sm),
            Text(
              strings.coachEmptyHint,
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}

/// One chat bubble. The user's turn is the filled indigo; the coach replies on
/// the soft canvas so the conversation reads as a column, not a ping-pong.
/// A task the assistant proposed, plus where the user has got to with it.
class _ProposedTask {
  final TaskAction action;

  /// The `chat_messages` row this came from, once it has been written.
  ///
  /// Null only for the moment between the reply arriving and the insert
  /// returning; a card confirmed inside that window still adds the task, it
  /// just cannot record the fact, and will offer itself again next time.
  int? messageId;

  bool adding = false;
  bool added = false;

  _ProposedTask(this.action, {this.messageId, this.added = false});
}

class _Bubble extends StatelessWidget {
  final Key bubbleKey;
  final ChatMessage message;
  final AppStrings strings;
  final int index;

  /// The task this reply proposed, if it proposed one.
  final _ProposedTask? proposal;
  final VoidCallback onAddTask;

  const _Bubble({
    required this.bubbleKey,
    required this.message,
    required this.strings,
    required this.index,
    required this.proposal,
    required this.onAddTask,
  });

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.isUser;

    return Align(
      key: bubbleKey,
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: isUser ? AppColors.primary : AppColors.canvasSoft,
          borderRadius:
              const BorderRadius.all(Radius.circular(AppRadius.lg)),
          border: Border.all(
            color: isUser ? AppColors.primary : AppColors.hairline,
          ),
        ),
        child: _content(context, isUser),
      ),
    );
  }

  Widget _content(BuildContext context, bool isUser) {
    if (message.isPending) {
      return Text(strings.coachThinking, style: AppText.caption);
    }

    if (isUser) {
      return Text(
        message.content,
        style: AppText.bodyMd.copyWith(color: AppColors.onPrimary),
      );
    }

    if (message.isError) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              message.content,
              style: AppText.caption.copyWith(color: AppColors.primary),
            ),
          ),
        ],
      );
    }

    final Widget? card = _actionCard(context);
    if (card == null) return _markdown(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // A reply that was nothing but the action block leaves no prose to
        // show, so the card stands alone rather than opening a blank gap.
        if (message.content.trim().isNotEmpty) _markdown(context),
        const SizedBox(height: AppSpacing.md),
        card,
      ],
    );
  }

  Widget _markdown(BuildContext context) {
    // The coach answers in Markdown, same as the debrief. MarkdownBody builds
    // its own spans, so the Arabic family has to be set on each style.
    final String? family = AppTheme.fontFamilyForLocale(
      Localizations.localeOf(context),
    );
    TextStyle f(TextStyle style) => style.copyWith(fontFamily: family);

    return MarkdownBody(
      data: message.content,
      styleSheet: MarkdownStyleSheet(
        p: f(AppText.bodyMd),
        h1: f(AppText.displayMd),
        h2: f(AppText.headingLg),
        listBullet: f(AppText.bodyMd),
        strong: f(AppText.bodyMd.copyWith(fontWeight: FontWeight.w700)),
        em: f(AppText.bodyMd.copyWith(fontStyle: FontStyle.italic)),
        pPadding: const EdgeInsets.only(top: AppSpacing.xs),
      ),
    );
  }

  /// The confirm card shown under a reply that proposed a task.
  ///
  /// Everything the task will be is spelled out — title, day, clock, repeat —
  /// because this is the user's only chance to catch the model putting the
  /// wrong date or the wrong repeat rule into their schedule.
  Widget? _actionCard(BuildContext context) {
    final _ProposedTask? proposed = proposal;
    if (proposed == null) return null;

    final TaskAction action = proposed.action;
    final String language = strings.languageCode;
    final DateTime when = action.scheduledTime;
    final String repeat = TaskCard.recurrenceLabel(action.toTask(), strings);
    final String stamp = '${DateFormat('EEE d MMM', language).format(when)}'
        '  ·  ${DateFormat.Hm(language).format(when)}'
        '${repeat.isEmpty ? '' : '  ·  $repeat'}';

    return Container(
      key: ChatCoachScreen.taskActionKey(index),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            strings.coachProposedTask.toUpperCase(),
            style: AppText.micro.copyWith(color: AppColors.inkFaint),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            action.title,
            style: AppText.bodyMd.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(stamp, style: AppText.caption),
          const SizedBox(height: AppSpacing.md),
          _actionButton(proposed),
        ],
      ),
    );
  }

  Widget _actionButton(_ProposedTask proposed) {
    if (proposed.added) {
      return Row(
        key: ChatCoachScreen.taskActionAddKey(index),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: AppColors.tealDeep,
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              strings.coachTaskAdded,
              style: AppText.caption.copyWith(color: AppColors.tealDeep),
            ),
          ),
        ],
      );
    }

    return Material(
      color: proposed.adding ? AppColors.hairline : AppColors.primary,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      child: InkWell(
        key: ChatCoachScreen.taskActionAddKey(index),
        onTap: proposed.adding ? null : onAddTask,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        child: Container(
          width: double.infinity,
          height: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text(
            proposed.adding
                ? strings.coachAddingTask
                : strings.coachAddTaskButton,
            textAlign: TextAlign.center,
            style: AppText.buttonMd.copyWith(
              color: proposed.adding
                  ? AppColors.inkFaint
                  : AppColors.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
