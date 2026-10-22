import 'dart:convert';

import 'package:a_fish_in_sea/anki/anki_server.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Mock app server: asserts the proxy envelope, answers from [script].
SyncClient mockServer(
  Map<String, dynamic> Function(Map<String, dynamic> request) script, {
  List<Map<String, dynamic>>? seen,
  int status = 200,
}) {
  final mock = MockClient((http.Request req) async {
    // SyncClient always routes through ServerConfig (funnel `/fish`
    // prefix on native), so match the suffix, not the full path.
    expect(req.url.path.endsWith('/api/anki/invoke'), isTrue);
    expect(req.headers['Authorization'], 'Bearer test-token');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    seen?.add(body);
    return http.Response(jsonEncode(script(body)), status);
  });
  return SyncClient(
    serverBase: () => 'http://127.0.0.1:8000',
    accessToken: () => 'test-token',
    refreshAccessToken: () async => null,
    client: mock,
  );
}

void main() {
  group('Anki via server', () {
    test('deckNames lists decks', () async {
      final client = mockServer((req) {
        expect(req['action'], 'deckNames');
        return {
          'result': ['Default', 'Japanese']
        };
      });
      expect(await ankiServerDeckNames(client), ['Default', 'Japanese']);
    });

    test('reviewsToday forwards the shared findCards query', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockServer(
        (req) => {
          'result': ['a', 'b']
        },
        seen: seen,
      );
      expect(await ankiServerReviewsToday(client), 2);
      expect(seen.single['action'], 'findCards');
      expect(seen.single['params'], {
        'query': 'rated:1',
      });
      expect(
          await ankiServerReviewsToday(client, deck: 'Japanese'), 2);
      expect(seen.last['params'], {
        'query': 'deck:"Japanese" rated:1',
      });
    });

    test('401 becomes a sign-in prompt', () async {
      final mock = MockClient((http.Request req) async =>
          http.Response(jsonEncode({'detail': 'Missing bearer token'}), 401));
      final client = SyncClient(
        serverBase: () => 'http://127.0.0.1:8000',
        accessToken: () => 'stale',
        refreshAccessToken: () async => null,
        client: mock,
      );
      expect(
          () => ankiServerDeckNames(client),
          throwsA(isA<AnkiServerException>().having(
              (e) => e.message, 'message', contains('Sign in'))));
    });

    test('upstream failures keep the server message', () async {
      final client = mockServer(
        (req) => {'detail': 'Anki is unreachable: boom'},
        status: 502,
      );
      expect(
          () => ankiServerReviewsToday(client),
          throwsA(isA<AnkiServerException>().having((e) => e.message,
              'message', contains('Anki is unreachable'))));
    });

    test('unknown shapes become displayable errors', () async {
      final client = mockServer((req) => {'unexpected': true});
      expect(() => ankiServerDeckNames(client),
          throwsA(isA<AnkiServerException>()));

      final shapeClient = mockServer((req) => {'result': 'not-a-list'});
      expect(() => ankiServerDeckNames(shapeClient),
          throwsA(isA<AnkiServerException>()));
    });
  });
}
