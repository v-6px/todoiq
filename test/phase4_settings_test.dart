import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:todo_list/screens/settings_screen.dart';
import 'package:todo_list/services/ai_service.dart';
import 'package:todo_list/services/settings_service.dart';
import 'package:todo_list/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Requests the screen sent to the fake endpoint.
  late List<http.Request> requests;

  /// Installs a fresh preference store.
  ///
  /// Both caches have to be dropped: the plugin's own static instance and
  /// SettingsService's singleton handle. Without this, every test after the
  /// first keeps reading the store the first one loaded.
  void useStoredSettings([Map<String, Object> values = const <String, Object>{}]) {
    SharedPreferences.setMockInitialValues(values);
    SharedPreferences.resetStatic();
    SettingsService.instance.resetCacheForTesting();
  }

  setUp(() {
    requests = <http.Request>[];
    useStoredSettings();
  });

  /// A client that records the request and replies with [status] / [body].
  MockClient respondWith(int status, {String body = '{"choices":[]}'}) {
    return MockClient((http.Request request) async {
      requests.add(request);
      return http.Response(body, status);
    });
  }

  /// A client that always throws, standing in for no connectivity.
  MockClient failing() {
    return MockClient((http.Request request) async {
      requests.add(request);
      throw const SocketExceptionStub();
    });
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    http.Client? client,
    String language = 'en',
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.forLocale(Locale(language)),
      locale: Locale(language),
      supportedLocales: const <Locale>[
        Locale('en'),
        Locale('ar'),
        Locale('fr'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: SettingsScreen(client: client ?? respondWith(200)),
    ));
    await tester.pumpAndSettle();
  }

  group('Loading stored values', () {
    testWidgets('shows the documented defaults on a fresh install', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.baseUrlFieldKey),
        ).controller!.text,
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.modelFieldKey),
        ).controller!.text,
        'gemini-3.6-flash',
      );
      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.apiKeyFieldKey),
        ).controller!.text,
        isEmpty,
      );
    });

    testWidgets('restores previously saved credentials', (
      WidgetTester tester,
    ) async {
      useStoredSettings(<String, Object>{
        'api_key': 'sk-stored',
        'base_url': 'https://api.groq.com/openai/v1',
        'model_name': 'llama-3.3-70b-versatile',
      });

      await pumpSettings(tester);

      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.apiKeyFieldKey),
        ).controller!.text,
        'sk-stored',
      );
      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.modelFieldKey),
        ).controller!.text,
        'llama-3.3-70b-versatile',
      );
    });
  });

  group('API key visibility', () {
    testWidgets('the key is obscured until the toggle is tapped', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      TextField keyField() => tester.widget<TextField>(
            find.byKey(SettingsScreen.apiKeyFieldKey),
          );

      expect(keyField().obscureText, isTrue);

      await tester.tap(find.byKey(SettingsScreen.visibilityToggleKey));
      await tester.pumpAndSettle();
      expect(keyField().obscureText, isFalse);

      await tester.tap(find.byKey(SettingsScreen.visibilityToggleKey));
      await tester.pumpAndSettle();
      expect(keyField().obscureText, isTrue);
    });
  });

  group('Endpoint building', () {
    test('the release manifest grants INTERNET', () {
      // Flutter only adds this permission to the debug and profile manifests.
      // Without it here every AI call succeeds in development and fails the
      // instant it runs in a release build.
      final String manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();

      expect(
        manifest,
        contains('<uses-permission android:name='
            '"android.permission.INTERNET"/>'),
      );
    });

    test('whitespace anywhere in a base URL is stripped', () {
      expect(
        SettingsService.normalizeBaseUrl('  https://api.example.com/v1  '),
        'https://api.example.com/v1',
      );
      // A newline or a non-breaking space picked up while pasting is
      // invisible in the field but fatal to Uri.parse.
      expect(
        SettingsService.normalizeBaseUrl('https://api.example.com\n/v1/'),
        'https://api.example.com/v1',
      );
      expect(
        SettingsService.normalizeBaseUrl('https://api.example.com\u00a0/v1'),
        'https://api.example.com/v1',
      );
    });

    test('a padded base URL still reaches the right endpoint', () {
      expect(
        AiService.resolveEndpoint('  https://api.example.com/v1/  ')
            .toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(
        AiService.resolveEndpoint(
          'https://generativelanguage.googleapis.com/v1beta/openai',
        ).toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai/'
            'chat/completions',
      );
    });

    test('an unusable base URL names the field, not the connection', () {
      for (final String bad in <String>[
        'api.example.com',
        'ftp://api.example.com',
        'https://',
        'not a url',
      ]) {
        expect(
          () => AiService.resolveEndpoint(bad),
          throwsA(isA<AiException>().having(
            (AiException e) => e.message,
            'message',
            contains('base URL'),
          )),
          reason: bad,
        );
      }
    });
  });

  group('Presets', () {
    testWidgets(
        'the Gemini preset builds the exact chat-completions endpoint, '
        'with no truncation or double slash', (WidgetTester tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(SettingsScreen.presetKey('Gemini Flash')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.baseUrlFieldKey),
        ).controller!.text,
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );

      await tester.enterText(
        find.byKey(SettingsScreen.apiKeyFieldKey),
        'sk-live',
      );
      await tester.ensureVisible(find.byKey(SettingsScreen.testButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsScreen.testButtonKey));
      await tester.pumpAndSettle();

      expect(
        requests.single.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      );
    });

    testWidgets('every preset renders a chip', (WidgetTester tester) async {
      await pumpSettings(tester);

      for (final ProviderPreset preset in SettingsService.presets) {
        expect(
          find.byKey(SettingsScreen.presetKey(preset.label)),
          findsOneWidget,
          reason: 'missing chip for ${preset.label}',
        );
      }
    });

    testWidgets('tapping a preset fills the base URL and model', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      const ProviderPreset groq = ProviderPreset(
        label: 'Groq',
        baseUrl: 'https://api.groq.com/openai/v1',
        modelName: 'llama-3.3-70b-versatile',
      );

      await tester.tap(find.byKey(SettingsScreen.presetKey(groq.label)));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.baseUrlFieldKey),
        ).controller!.text,
        groq.baseUrl,
      );
      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.modelFieldKey),
        ).controller!.text,
        groq.modelName,
      );
    });

    testWidgets('a preset never overwrites the API key', (
      WidgetTester tester,
    ) async {
      useStoredSettings(<String, Object>{'api_key': 'sk-keep-me'});
      await pumpSettings(tester);

      await tester.tap(find.byKey(SettingsScreen.presetKey('OpenRouter')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.apiKeyFieldKey),
        ).controller!.text,
        'sk-keep-me',
      );
    });
  });

  group('Saving', () {
    testWidgets('persists all three fields to shared_preferences', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.enterText(
        find.byKey(SettingsScreen.apiKeyFieldKey),
        'sk-test-123',
      );
      await tester.enterText(
        find.byKey(SettingsScreen.baseUrlFieldKey),
        'https://openrouter.ai/api/v1',
      );
      await tester.enterText(
        find.byKey(SettingsScreen.modelFieldKey),
        'openai/gpt-4o-mini',
      );

      await tester.tap(find.byKey(SettingsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      expect(await SettingsService.instance.getApiKey(), 'sk-test-123');
      expect(
        await SettingsService.instance.getBaseUrl(),
        'https://openrouter.ai/api/v1',
      );
      expect(
        await SettingsService.instance.getModelName(),
        'openai/gpt-4o-mini',
      );
      expect(await SettingsService.instance.isConfigured(), isTrue);
    });

    testWidgets('confirms the save to the user', (WidgetTester tester) async {
      await pumpSettings(tester);

      await tester.enterText(
        find.byKey(SettingsScreen.apiKeyFieldKey),
        'sk-confirm',
      );
      await tester.tap(find.byKey(SettingsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Settings saved.'), findsOneWidget);
    });

    testWidgets('trims the key and normalises a trailing slash', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.enterText(
        find.byKey(SettingsScreen.apiKeyFieldKey),
        '  sk-padded  ',
      );
      await tester.enterText(
        find.byKey(SettingsScreen.baseUrlFieldKey),
        'https://api.groq.com/openai/v1///',
      );

      await tester.tap(find.byKey(SettingsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      expect(await SettingsService.instance.getApiKey(), 'sk-padded');
      expect(
        await SettingsService.instance.getBaseUrl(),
        'https://api.groq.com/openai/v1',
      );
      // What is shown matches what was stored.
      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.baseUrlFieldKey),
        ).controller!.text,
        'https://api.groq.com/openai/v1',
      );
    });

    testWidgets('a saved preset survives reopening the screen', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(SettingsScreen.presetKey('Groq')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(SettingsScreen.apiKeyFieldKey),
        'sk-reopen',
      );
      await tester.tap(find.byKey(SettingsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Rebuild the screen from scratch, as reopening it would.
      await pumpSettings(tester);

      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.baseUrlFieldKey),
        ).controller!.text,
        'https://api.groq.com/openai/v1',
      );
      expect(
        tester.widget<TextField>(
          find.byKey(SettingsScreen.apiKeyFieldKey),
        ).controller!.text,
        'sk-reopen',
      );
    });
  });

  group('Test connection', () {
    Future<void> fillCredentials(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(SettingsScreen.apiKeyFieldKey),
        'sk-live',
      );
      await tester.pumpAndSettle();
    }

    /// The settings form scrolls, and the actions sit below the fold once the
    /// language section is in place — so bring the target into view first.
    Future<void> tapTest(WidgetTester tester) async {
      final Finder button = find.byKey(SettingsScreen.testButtonKey);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('sends a minimal ping to {base_url}/chat/completions', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, client: respondWith(200));
      await fillCredentials(tester);

      await tapTest(tester);

      expect(requests, hasLength(1));
      final http.Request request = requests.single;

      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      );
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer sk-live');
      expect(request.headers['Content-Type'], contains('application/json'));
      expect(request.headers['User-Agent'], isNotNull);

      final Map<String, Object?> body =
          jsonDecode(request.body) as Map<String, Object?>;
      expect(body['model'], 'gemini-3.6-flash');
      expect(body['max_tokens'], AiService.pingMaxTokens);
      expect(body['messages'], isA<List<Object?>>());

      // Exactly the three standard fields and nothing else. Anything extra
      // is a field some provider validates strictly and rejects with a 400,
      // which then reads as "the key is wrong" to the user.
      expect(
        body.keys.toSet(),
        <String>{'model', 'messages', 'max_tokens'},
        reason: 'the ping must carry no vendor extensions',
      );
      expect(body.containsKey('max_completion_tokens'), isFalse);
      expect(body.containsKey('temperature'), isFalse);

      final List<Object?> messages = body['messages']! as List<Object?>;
      expect(messages, hasLength(1));
      expect(
        messages.single,
        <String, String>{'role': 'user', 'content': 'ping'},
      );
    });

    testWidgets('a rejection shows what the server actually said', (
      WidgetTester tester,
    ) async {
      // The whole point: a 400 that says only "request rejected" sends the
      // user hunting through settings that are already correct.
      await pumpSettings(
        tester,
        client: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': <String, Object?>{
                'code': 400,
                'message': 'Unknown name "max_completion_tokens": Cannot find '
                    'field.',
                'status': 'INVALID_ARGUMENT',
              },
            }),
            400,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      await fillCredentials(tester);
      await tapTest(tester);

      expect(find.textContaining('HTTP 400'), findsOneWidget);
      expect(
        find.textContaining('Unknown name "max_completion_tokens"'),
        findsOneWidget,
      );
    });

    testWidgets('a non-JSON rejection is still shown verbatim', (
      WidgetTester tester,
    ) async {
      await pumpSettings(
        tester,
        client: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response('<html><body>502 Bad Gateway</body></html>', 502);
        }),
      );
      await fillCredentials(tester);
      await tapTest(tester);

      expect(find.textContaining('502 Bad Gateway'), findsOneWidget);
    });

    testWidgets('reports success on 200', (WidgetTester tester) async {
      await pumpSettings(tester, client: respondWith(200));
      await fillCredentials(tester);

      await tapTest(tester);

      expect(find.textContaining('Connected'), findsOneWidget);
    });

    testWidgets('never sends a request without an API key', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, client: respondWith(200));

      await tapTest(tester);

      expect(requests, isEmpty);
      expect(find.text('Enter an API key first.'), findsOneWidget);
    });

    testWidgets('refuses an empty base URL', (WidgetTester tester) async {
      await pumpSettings(tester, client: respondWith(200));
      await fillCredentials(tester);
      await tester.enterText(find.byKey(SettingsScreen.baseUrlFieldKey), '');

      await tapTest(tester);

      expect(requests, isEmpty);
      expect(find.text('Enter a base URL first.'), findsOneWidget);
    });

    testWidgets('refuses an empty model name', (WidgetTester tester) async {
      await pumpSettings(tester, client: respondWith(200));
      await fillCredentials(tester);
      await tester.enterText(find.byKey(SettingsScreen.modelFieldKey), '');

      await tapTest(tester);

      expect(requests, isEmpty);
      expect(find.text('Enter a model name first.'), findsOneWidget);
    });

    testWidgets('explains a rejected key on 401', (WidgetTester tester) async {
      await pumpSettings(
        tester,
        client: respondWith(
          401,
          body: '{"error":{"message":"Invalid API key"}}',
        ),
      );
      await fillCredentials(tester);

      await tapTest(tester);

      expect(find.textContaining('API key was rejected'), findsOneWidget);
      // The provider's own message is surfaced, not swallowed.
      expect(find.textContaining('Invalid API key'), findsOneWidget);
    });

    testWidgets('points at the base URL on 404', (WidgetTester tester) async {
      await pumpSettings(tester, client: respondWith(404, body: ''));
      await fillCredentials(tester);

      await tapTest(tester);

      expect(find.textContaining('No endpoint at that URL'), findsOneWidget);
    });

    testWidgets('names rate limiting on 429', (WidgetTester tester) async {
      await pumpSettings(tester, client: respondWith(429, body: ''));
      await fillCredentials(tester);

      await tapTest(tester);

      expect(find.textContaining('Rate limited'), findsOneWidget);
    });

    testWidgets('blames the provider on 500', (WidgetTester tester) async {
      await pumpSettings(tester, client: respondWith(500, body: ''));
      await fillCredentials(tester);

      await tapTest(tester);

      expect(find.textContaining('provider returned an error'), findsOneWidget);
    });

    testWidgets('a network failure is caught, not thrown', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, client: failing());
      await fillCredentials(tester);

      await tapTest(tester);

      expect(
        find.textContaining('Could not reach the endpoint'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a non-JSON error body still yields a readable message', (
      WidgetTester tester,
    ) async {
      await pumpSettings(
        tester,
        client: respondWith(400, body: '<html>Bad Request</html>'),
      );
      await fillCredentials(tester);

      await tapTest(tester);

      expect(find.textContaining('HTTP 400'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching preset clears a previous result', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, client: respondWith(200));
      await fillCredentials(tester);

      await tapTest(tester);
      expect(find.textContaining('Connected'), findsOneWidget);

      await tester.tap(find.byKey(SettingsScreen.presetKey('Groq')));
      await tester.pumpAndSettle();

      // The old result described a different endpoint, so it must not linger.
      expect(find.textContaining('Connected'), findsNothing);
    });

    testWidgets('testing does not write anything to storage', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, client: respondWith(200));
      await fillCredentials(tester);

      await tapTest(tester);

      // Nothing is persisted until Save is pressed.
      expect(await SettingsService.instance.getApiKey(), isEmpty);
    });
  });
}

/// Stands in for a socket failure without importing dart:io into the test.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketExceptionStub: no connection';
}
