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
  final String role;
  final String content;
  final DateTime timestamp;

  /// True while the reply is still being waited on, so the UI can show a
  /// placeholder bubble in the right place.
  final bool isPending;

  /// True when this turn failed, so it can be styled as an error.
  final bool isError;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.isPending = false,
    this.isError = false,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage.system(this.content, {DateTime? timestamp})
      : role = ChatRole.system,
        timestamp = timestamp ?? DateTime.now(),
        isPending = false,
        isError = false;

  ChatMessage.user(this.content, {DateTime? timestamp})
      : role = ChatRole.user,
        timestamp = timestamp ?? DateTime.now(),
        isPending = false,
        isError = false;

  ChatMessage.assistant(
    this.content, {
    DateTime? timestamp,
    this.isPending = false,
    this.isError = false,
  })  : role = ChatRole.assistant,
        timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == ChatRole.user;
  bool get isAssistant => role == ChatRole.assistant;
  bool get isSystem => role == ChatRole.system;

  /// True when this message should be sent to the model. Pending placeholders
  /// and failed turns are UI-only.
  bool get isSendable => !isPending && !isError;

  ChatMessage copyWith({
    String? content,
    bool? isPending,
    bool? isError,
  }) {
    return ChatMessage(
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      isPending: isPending ?? this.isPending,
      isError: isError ?? this.isError,
    );
  }

  Map<String, String> toJson() =>
      <String, String>{'role': role, 'content': content};

  @override
  String toString() => 'ChatMessage($role, ${content.length} chars)';
}
