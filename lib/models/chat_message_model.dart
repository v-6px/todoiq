/// Who said a line in the coach conversation.
class ChatRole {
  static const String system = 'system';
  static const String user = 'user';
  static const String assistant = 'assistant';

  const ChatRole._();
}

/// One line of the coach conversation.
///
/// The session lives in memory for the life of the screen — nothing is
/// persisted, so a closed conversation leaves no trace on the device.
class ChatMessage {
  /// The `chat_messages` row id, or null for a turn not yet stored.
  final int? id;

  final String role;
  final String content;
  final DateTime timestamp;

  /// True once the task this turn proposed has been added to the schedule.
  ///
  /// Stored, not derived: the proposal card comes back every time the screen
  /// reopens, and without a record of the tap it would happily create the
  /// same task again on each visit.
  final bool actionAdded;

  /// True while the reply is still being waited on, so the UI can show a
  /// placeholder bubble in the right place.
  final bool isPending;

  /// True when this turn failed, so it can be styled as an error.
  final bool isError;

  ChatMessage({
    this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.isPending = false,
    this.isError = false,
    this.actionAdded = false,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage.system(this.content, {DateTime? timestamp})
      : id = null,
        role = ChatRole.system,
        timestamp = timestamp ?? DateTime.now(),
        isPending = false,
        isError = false,
        actionAdded = false;

  ChatMessage.user(this.content, {DateTime? timestamp})
      : id = null,
        role = ChatRole.user,
        timestamp = timestamp ?? DateTime.now(),
        isPending = false,
        isError = false,
        actionAdded = false;

  ChatMessage.assistant(
    this.content, {
    DateTime? timestamp,
    this.isPending = false,
    this.isError = false,
  })  : id = null,
        role = ChatRole.assistant,
        timestamp = timestamp ?? DateTime.now(),
        actionAdded = false;

  bool get isUser => role == ChatRole.user;
  bool get isAssistant => role == ChatRole.assistant;
  bool get isSystem => role == ChatRole.system;

  /// True when this message should be sent to the model. Pending placeholders
  /// and failed turns are UI-only.
  bool get isSendable => !isPending && !isError;

  ChatMessage copyWith({
    int? id,
    String? content,
    bool? isPending,
    bool? isError,
    bool? actionAdded,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      isPending: isPending ?? this.isPending,
      isError: isError ?? this.isError,
      actionAdded: actionAdded ?? this.actionAdded,
    );
  }

  Map<String, String> toJson() =>
      <String, String>{'role': role, 'content': content};

  /// Serialises to the `chat_messages` column layout.
  ///
  /// [isPending] and [isError] are deliberately absent: a placeholder waiting
  /// on a reply and a turn that failed are both UI state, and neither is part
  /// of the conversation worth reopening tomorrow.
  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'role': role,
        'content': content,
        'created_at': timestamp.millisecondsSinceEpoch,
        'action_added': actionAdded ? 1 : 0,
      };

  factory ChatMessage.fromMap(Map<String, Object?> map) => ChatMessage(
        id: map['id'] as int?,
        role: map['role'] as String,
        content: map['content'] as String,
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
        actionAdded: (map['action_added'] as int? ?? 0) != 0,
      );

  @override
  String toString() => 'ChatMessage($role, ${content.length} chars)';
}
