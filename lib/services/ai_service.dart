import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'settings_service.dart';

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
/// [message] is written to be shown directly in the UI — it names what went
/// wrong and, where possible, which field to fix.
class AiException implements Exception {
  final String message;
  final int? statusCode;

  const AiException(this.message, {this.statusCode});

  /// True when the cause is missing configuration rather than a failed call,
  /// so the UI can offer a shortcut to Settings.
  bool get isConfigurationError => statusCode == null && _isSetupMessage;

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
  static const String userAgent = 'TaskMaster/1.0 (Flutter)';

  final http.Client _client;

  /// A client passed in belongs to the caller; one made here is ours to close.
  final bool _ownsClient;

  AiService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Sends [messages] and returns the assistant's reply.
  ///
  /// Throws [AiException] for every failure path — missing configuration, a
  /// rejected request, or no connectivity — so callers have one thing to catch.
  Future<String> complete(
    List<AiMessage> messages, {
    AiCredentials? credentials,
    int? maxTokens,
    double? temperature,
    Duration timeout = defaultTimeout,
    bool requireContent = true,
  }) async {
    final AiCredentials resolved = await _resolveCredentials(credentials);
    final Uri endpoint = resolveEndpoint(resolved.baseUrl);

    final http.Response response;
    try {
      response = await _client
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
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiException(
        describeHttpFailure(response.statusCode, readBody(response)),
        statusCode: response.statusCode,
      );
    }

    return _extractContent(readBody(response), requireContent: requireContent);
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

  /// A 2-token ping proving the endpoint, key and model work together.
  ///
  /// Returns the model name on success; throws [AiException] otherwise.
  Future<String> testConnection({AiCredentials? credentials}) async {
    final AiCredentials resolved = await _resolveCredentials(credentials);

    await complete(
      const <AiMessage>[AiMessage.user('ping')],
      credentials: resolved,
      maxTokens: 2,
      timeout: pingTimeout,
      requireContent: false,
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
      throw const AiException('Add an API key in Settings first.');
    }
    if (stored.baseUrl.isEmpty) {
      throw const AiException('Add a base URL in Settings first.');
    }
    if (stored.model.isEmpty) {
      throw const AiException('Add a model name in Settings first.');
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
    throw const AiException('The provider returned an empty response.');
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

  /// Pulls `error.message` out of an OpenAI-style error body, if present.
  static String extractApiMessage(String body) {
    if (body.isEmpty) return '';
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final Object? error = decoded['error'];
        if (error is Map<String, Object?> && error['message'] is String) {
          return error['message']! as String;
        }
        if (error is String) return error;
      }
    } catch (_) {
      // Not JSON, or not the shape we expected — the status code alone will
      // have to do.
    }
    return '';
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
