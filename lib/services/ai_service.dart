import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/ai_failure.dart';
import 'settings_service.dart';

export '../models/ai_failure.dart';

/// A single turn in a chat-completions request.
class AiMessage {
  final String role;
  final String content;

  const AiMessage({required this.role, required this.content});

  const AiMessage.system(this.content) : role = 'system';
  const AiMessage.user(this.content) : role = 'user';
  const AiMessage.assistant(this.content) : role = 'assistant';

  Map<String, String> toJson() =>
      <String, String>{'role': role, 'content': content};
}

/// A failure the user can act on.
///
/// [message] is the technical English explanation, provider detail included —
/// right for the settings screen's connection test and for logs. [kind] is
/// what a screen shows everyone else, as a short translated sentence, so a
/// user never has to read a raw JSON error body.
class AiException implements Exception {
  final String message;
  final int? statusCode;
  final AiFailure kind;

  const AiException(
    this.message, {
    this.statusCode,
    this.kind = AiFailure.other,
  });

  /// The failure category an HTTP status belongs to.
  static AiFailure kindForStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) return AiFailure.unauthorized;
    if (statusCode == 404) return AiFailure.notFound;
    if (statusCode == 429) return AiFailure.rateLimited;
    if (statusCode >= 500) return AiFailure.unavailable;
    return AiFailure.other;
  }

  /// True when the cause is missing configuration rather than a failed call,
  /// so the UI can offer a shortcut to Settings.
  bool get isConfigurationError =>
      kind == AiFailure.missingConfiguration ||
      (statusCode == null && _isSetupMessage);

  bool get _isSetupMessage =>
      message.contains('API key') ||
      message.contains('base URL') ||
      message.contains('model name');

  @override
  String toString() => 'AiException($message)';
}

/// Talks to any OpenAI-compatible `/chat/completions` endpoint.
///
/// Credentials come from [SettingsService], so switching provider is purely a
/// settings change. This is the only part of the app that uses the network.
class AiService {
  static const Duration defaultTimeout = Duration(seconds: 60);
  static const Duration pingTimeout = Duration(seconds: 20);

  /// Reply budget for every generated reply, debrief and coach alike.
  ///
  /// A model that runs out of budget stops mid-sentence rather than wrapping
  /// up, which reads as a bug rather than as a limit. The ceiling sits far
  /// above what any prompt asks for, because the prompt is what should decide
  /// the length — this only stops a runaway. Arabic costs noticeably more
  /// tokens per word than English, so the same prompt needs more headroom in
  /// one language than in another, and one generous number covers both.
  ///
  /// Thinking models — the default Gemini Flash among them — count their
  /// hidden reasoning against `max_tokens` on the OpenAI-compatible endpoint.
  /// At 2048 a debrief could spend most of the budget thinking and be cut off
  /// a paragraph into the visible text. 8192 leaves the reasoning its room and
  /// the report all of its own.
  static const int defaultMaxTokens = 8192;

  /// Kept as names so call sites read for themselves; both are the ceiling.
  static const int debriefMaxTokens = defaultMaxTokens;
  static const int coachMaxTokens = defaultMaxTokens;

  /// How many times a reply cut off at the ceiling is asked to carry on.
  ///
  /// Only used where the caller opts in. Two is enough to finish any debrief
  /// the prompt asks for, and bounds the cost of a model that never stops.
  static const int maxContinuations = 2;

  /// The turn that asks a truncated reply to carry on.
  @visibleForTesting
  static const String continuationPrompt =
      'Your previous reply was cut off by the length limit. Continue exactly '
      'where it stopped — mid-sentence if need be. Do not repeat anything, '
      'do not restart a heading, and add no preamble.';

  /// Budget for the connection ping. Enough that a model which cannot emit
  /// fewer than a handful of tokens still answers, small enough to be free.
  static const int pingMaxTokens = 10;
  static const String userAgent = 'TaskMaster/1.0 (Flutter)';

  /// Statuses worth trying again: the provider is overloaded or a gateway in
  /// front of it hiccupped. Gemini answers 503 "model is overloaded" under
  /// load, and it usually clears within seconds.
  static const Set<int> retryableStatuses = <int>{502, 503, 504};

  /// Retries after the first attempt, so at most three requests in all.
  static const int maxRetries = 2;

  /// Longest wait honoured from a provider's `Retry-After` header.
  static const Duration maxRetryDelay = Duration(seconds: 10);

  /// 2s, then 4s.
  static Duration defaultRetryBackoff(int retry) =>
      Duration(seconds: 2 << (retry - 1));

  final http.Client _client;

  /// A client passed in belongs to the caller; one made here is ours to close.
  final bool _ownsClient;

  /// Wait before retry number `retry` (1-based). Injectable so tests of the
  /// retry path do not sit through real seconds.
  final Duration Function(int retry) _retryBackoff;

  AiService({
    http.Client? client,
    @visibleForTesting Duration Function(int retry)? retryBackoff,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _retryBackoff = retryBackoff ?? defaultRetryBackoff;

  /// Sends [messages] and returns the assistant's reply.
  ///
  /// Throws [AiException] for every failure path — missing configuration, a
  /// rejected request, or no connectivity — so callers have one thing to catch.
  ///
  /// With [continueIfTruncated], a reply the provider stopped at its token
  /// ceiling (`finish_reason: length`) is not handed back half-written: the
  /// partial text goes back as an assistant turn with a request to carry on,
  /// up to [maxContinuations] times, and the pieces are joined.
  Future<String> complete(
    List<AiMessage> messages, {
    AiCredentials? credentials,
    int? maxTokens,
    double? temperature,
    Duration timeout = defaultTimeout,
    bool requireContent = true,
    bool continueIfTruncated = false,
    bool retryTransientFailures = true,
  }) async {
    final AiCredentials resolved = await _resolveCredentials(credentials);

    String text = await _completeOnce(
      messages,
      credentials: resolved,
      maxTokens: maxTokens,
      temperature: temperature,
      timeout: timeout,
      requireContent: requireContent,
      retry: retryTransientFailures,
    );
    if (!continueIfTruncated) return text;

    for (int round = 0;
        round < maxContinuations && _lastFinishReason == 'length';
        round++) {
      debugPrint('AiService: reply hit the token ceiling; asking it to '
          'continue (${round + 1}/$maxContinuations).');
      // The original turns plus everything written so far, so the model sees
      // one unbroken reply to extend. An empty continuation just means there
      // was nothing left to say; what is already in hand stands.
      final String more = await _completeOnce(
        <AiMessage>[
          ...messages,
          AiMessage.assistant(text),
          const AiMessage.user(continuationPrompt),
        ],
        credentials: resolved,
        maxTokens: maxTokens,
        temperature: temperature,
        timeout: timeout,
        requireContent: false,
        retry: retryTransientFailures,
      );
      if (more.isEmpty) break;
      text = joinContinuation(text, more);
    }
    return text;
  }

  /// `finish_reason` of the most recent reply, or null if it gave none.
  String? _lastFinishReason;

  /// Joins a continuation onto the text it continues.
  ///
  /// The reply is trimmed on the way in, so the whitespace at the seam is
  /// gone: a continuation that starts a new block gets its line break back,
  /// one that carries on a sentence gets a single space.
  @visibleForTesting
  static String joinContinuation(String head, String tail) {
    final bool newBlock = tail.startsWith('#') ||
        tail.startsWith('- ') ||
        tail.startsWith('* ') ||
        RegExp(r'^\d+\. ').hasMatch(tail);
    return newBlock ? '$head\n\n$tail' : '$head $tail';
  }

  /// One logical request: the POST, retried on [retryableStatuses] with a
  /// backoff when [retry] is set.
  Future<String> _completeOnce(
    List<AiMessage> messages, {
    required AiCredentials credentials,
    int? maxTokens,
    double? temperature,
    required Duration timeout,
    required bool requireContent,
    required bool retry,
  }) async {
    _lastFinishReason = null;
    final Uri endpoint = resolveEndpoint(credentials.baseUrl);

    for (int attempt = 0;; attempt++) {
      final http.Response response = await _post(
        endpoint,
        messages,
        credentials: credentials,
        maxTokens: maxTokens,
        temperature: temperature,
        timeout: timeout,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final String body = readBody(response);
        if (warnIfTruncated(body)) _lastFinishReason = 'length';
        return _extractContent(body, requireContent: requireContent);
      }

      final String failureBody = readBody(response);

      // The whole body, verbatim. A 400 from an OpenAI-compatible server
      // almost always names the offending field, and that sentence is the
      // difference between a five-minute fix and an afternoon.
      debugPrint('AiService: $endpoint returned HTTP '
          '${response.statusCode} (attempt ${attempt + 1}). '
          'Body: $failureBody');

      if (retry &&
          attempt < maxRetries &&
          retryableStatuses.contains(response.statusCode)) {
        final Duration wait =
            _retryAfter(response) ?? _retryBackoff(attempt + 1);
        debugPrint('AiService: retrying in ${wait.inMilliseconds}ms.');
        await Future<void>.delayed(wait);
        continue;
      }

      throw AiException(
        describeHttpFailure(response.statusCode, failureBody),
        statusCode: response.statusCode,
        kind: AiException.kindForStatus(response.statusCode),
      );
    }
  }

  /// The provider's own `Retry-After`, in seconds, capped at [maxRetryDelay].
  static Duration? _retryAfter(http.Response response) {
    final int? seconds =
        int.tryParse(response.headers['retry-after']?.trim() ?? '');
    if (seconds == null || seconds < 0) return null;
    final Duration wait = Duration(seconds: seconds);
    return wait > maxRetryDelay ? maxRetryDelay : wait;
  }

  Future<http.Response> _post(
    Uri endpoint,
    List<AiMessage> messages, {
    required AiCredentials credentials,
    int? maxTokens,
    double? temperature,
    required Duration timeout,
  }) async {
    final AiCredentials resolved = credentials;
    try {
      return await _client
          .post(
            endpoint,
            headers: <String, String>{
              'Authorization': 'Bearer ${resolved.apiKey}',
              'Content-Type': 'application/json',
              'User-Agent': userAgent,
            },
            body: jsonEncode(<String, Object?>{
              'model': resolved.model,
              'messages':
                  messages.map((AiMessage m) => m.toJson()).toList(),
              // Only the fields every OpenAI-compatible server understands.
              // `max_completion_tokens` was sent alongside `max_tokens` for a
              // while: OpenAI's newer models want it, but Gemini's
              // compatibility layer validates the request strictly and
              // rejects the unknown field with a 400, which took the whole
              // app down for the default provider. One standard field beats
              // one extra provider.
              //
              // Deliberately no `stop`: a stop sequence matching a heading or
              // a blank line would end the reply early and look exactly like a
              // token-limit cut.
              'max_tokens': ?maxTokens,
              'temperature': ?temperature,
            }),
          )
          .timeout(timeout);
    } on AiException {
      rethrow;
    } catch (error, stack) {
      // The message the user sees is deliberately plain, which makes this the
      // one failure nobody can diagnose from the screen. The real exception
      // goes to the log instead. The URL is safe to print; the API key lives
      // in a header and never appears here.
      debugPrint('AiService: POST $endpoint failed with '
          '${error.runtimeType}: $error');
      debugPrintStack(stackTrace: stack, label: 'AiService.complete');

      throw const AiException(
        'Could not reach the endpoint. Check the URL and your connection.',
        kind: AiFailure.network,
      );
    }
  }

  /// Logs, and returns true, when the provider says it stopped because it
  /// ran out of room.
  ///
  /// Nothing is cut on this side, but a `finish_reason` of `length` is the
  /// provider telling us the text ends mid-thought — invisible on screen,
  /// which is why callers that care opt into continuation.
  @visibleForTesting
  static bool warnIfTruncated(String body) {
    if (!body.contains('"length"')) return false;

    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return false;
      final Object? choices = decoded['choices'];
      if (choices is! List<Object?> || choices.isEmpty) return false;
      final Object? first = choices.first;
      if (first is! Map<String, Object?>) return false;

      if (first['finish_reason'] == 'length') {
        debugPrint('AiService: the provider stopped at its token ceiling '
            '(finish_reason: length, max_tokens $defaultMaxTokens).');
        return true;
      }
    } on FormatException {
      // Not our problem here; _extractContent reports an unreadable body.
    }
    return false;
  }

  /// Builds the chat-completions URL, rejecting anything Uri cannot use.
  ///
  /// Without this a malformed base URL surfaces as "could not reach the
  /// endpoint", which sends the user looking at their connection instead of
  /// at the one field that is actually wrong.
  static Uri resolveEndpoint(String baseUrl) {
    final String normalized = SettingsService.normalizeBaseUrl(baseUrl);
    final Uri? endpoint = Uri.tryParse('$normalized/chat/completions');

    if (endpoint == null ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
        endpoint.host.isEmpty) {
      throw AiException(
        'That base URL is not a valid address: "$normalized". It should look '
        'like https://api.example.com/v1',
        kind: AiFailure.invalidUrl,
      );
    }

    return endpoint;
  }

  /// Decodes a response body as UTF-8 unless the provider said otherwise.
  ///
  /// JSON is UTF-8 by specification, but `http` falls back to latin-1 when a
  /// response omits the charset — and several OpenAI-compatible servers do.
  /// Left unhandled that turns an Arabic reply into mojibake, which then ends
  /// up in the task the coach proposed.
  static String readBody(http.Response response) {
    final String charset = response.headers['content-type'] ?? '';
    if (charset.toLowerCase().contains('charset=')) return response.body;
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      // Genuinely not UTF-8; fall back to whatever http worked out.
      return response.body;
    }
  }

  /// A minimal ping proving the endpoint, key and model work together.
  ///
  /// Deliberately the plainest request the API allows — model, one user
  /// message, a token ceiling, and nothing else. No temperature, no sampling
  /// options, no vendor extensions: if this is rejected, the problem is the
  /// URL, the key or the model name, and never a field the app added.
  ///
  /// Returns the model name on success; throws [AiException] otherwise.
  Future<String> testConnection({AiCredentials? credentials}) async {
    final AiCredentials resolved = await _resolveCredentials(credentials);

    await complete(
      const <AiMessage>[AiMessage.user('ping')],
      credentials: resolved,
      maxTokens: pingMaxTokens,
      timeout: pingTimeout,
      requireContent: false,
      // The connection test should answer at once, with the real status.
      retryTransientFailures: false,
    );

    return resolved.model;
  }

  /// Uses [override] when given — the settings screen tests the values
  /// currently typed in, which may not be saved yet — and otherwise reads
  /// what is stored.
  Future<AiCredentials> _resolveCredentials(AiCredentials? override) async {
    if (override != null) return override;

    final SettingsService settings = SettingsService.instance;
    final AiCredentials stored = AiCredentials(
      apiKey: await settings.getApiKey(),
      baseUrl: await settings.getBaseUrl(),
      model: await settings.getModelName(),
    );

    if (stored.apiKey.isEmpty) {
      throw const AiException(
        'Add an API key in Settings first.',
        kind: AiFailure.missingConfiguration,
      );
    }
    if (stored.baseUrl.isEmpty) {
      throw const AiException(
        'Add a base URL in Settings first.',
        kind: AiFailure.missingConfiguration,
      );
    }
    if (stored.model.isEmpty) {
      throw const AiException(
        'Add a model name in Settings first.',
        kind: AiFailure.missingConfiguration,
      );
    }

    return stored;
  }

  /// Reads `choices[0].message.content` from a chat-completions response.
  ///
  /// With [requireContent] false an empty reply is returned as an empty
  /// string instead of throwing — a 2-token ping can legitimately run out of
  /// budget before the model writes anything, and the 2xx already proves the
  /// endpoint works.
  static String _extractContent(String body, {bool requireContent = true}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const AiException(
        'The provider returned a response that could not be read.',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw const AiException(
        'The provider returned a response that could not be read.',
      );
    }

    final Object? choices = decoded['choices'];
    if (choices is List<Object?> && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map<String, Object?>) {
        final Object? message = first['message'];
        if (message is Map<String, Object?>) {
          final Object? content = message['content'];
          if (content is String && content.trim().isNotEmpty) {
            return content.trim();
          }
        }
      }
    }

    // A 200 with no usable content usually means the model hit its token
    // budget before writing anything.
    if (!requireContent) return '';
    throw const AiException(
      'The provider returned an empty response.',
      kind: AiFailure.emptyResponse,
    );
  }

  /// Turns a status code into something the user can act on.
  static String describeHttpFailure(int statusCode, String body) {
    final String detail = extractApiMessage(body);
    final String suffix = detail.isEmpty ? '' : ' $detail';

    switch (statusCode) {
      case 401:
      case 403:
        return 'The API key was rejected (HTTP $statusCode).$suffix';
      case 404:
        return 'No endpoint at that URL (HTTP 404). Check the base URL — it '
            'should end before /chat/completions.$suffix';
      case 429:
        return 'Rate limited (HTTP 429). Try again shortly.$suffix';
      default:
        if (statusCode >= 500) {
          return 'The provider returned an error (HTTP $statusCode).$suffix';
        }
        return 'Request rejected (HTTP $statusCode).$suffix';
    }
  }

  /// Longest server explanation carried into the on-screen error.
  ///
  /// Long enough for a real validation message, short enough not to bury the
  /// sentence that says what to do about it.
  static const int maxApiMessageLength = 300;

  /// Pulls the provider's own explanation out of an error body.
  ///
  /// Falls back to the raw body when it is not the OpenAI error shape: a
  /// provider that rejects a request always says why somewhere, and showing
  /// that verbatim beats showing only a status code.
  static String extractApiMessage(String body) {
    if (body.isEmpty) return '';
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final Object? error = decoded['error'];
        if (error is Map<String, Object?> && error['message'] is String) {
          return _clip(error['message']! as String);
        }
        if (error is String) return _clip(error);
        // Some servers answer with {"message": ...} and no "error" wrapper.
        if (decoded['message'] is String) {
          return _clip(decoded['message']! as String);
        }
      }
      return _clip(body);
    } catch (_) {
      // Not JSON at all — an HTML error page or a proxy notice. Still worth
      // showing: it usually names the thing that rejected the request.
      return _clip(body);
    }
  }

  /// One line, trimmed to [maxApiMessageLength].
  static String _clip(String value) {
    final String flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= maxApiMessageLength) return flat;
    return '${flat.substring(0, maxApiMessageLength)}…';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// Endpoint credentials for one request. Values are normalised on
/// construction so callers never have to think about stray whitespace or a
/// trailing slash.
class AiCredentials {
  final String apiKey;
  final String baseUrl;
  final String model;

  AiCredentials({
    required String apiKey,
    required String baseUrl,
    required String model,
  })  : apiKey = apiKey.trim(),
        baseUrl = SettingsService.normalizeBaseUrl(baseUrl),
        model = model.trim();
}
