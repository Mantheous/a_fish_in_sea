import 'dart:convert';

import 'package:a_fish_in_sea/anki/anki_connect.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Mock AnkiConnect: asserts the request envelope, answers from [script].
AnkiConnectClient mockAnki(
  Map<String, dynamic> Function(Map<String, dynamic> request) script, {
  List<Map<String, dynamic>>? seen,
}) {
  final mock = MockClient((http.Request req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    seen?.add(body);
    expect(body['version'], AnkiConnectClient.apiVersion);
    final answer = script(body);
    final status = answer['__status'] as int?;
    answer.remove('__status');
    return http.Response(jsonEncode(answer), status ?? 200);
  });
  return AnkiConnectClient(host: 'http://127.0.0.1:8765', httpClient: mock);
}

void main() {
  group('AnkiConnectClient', () {
    test('reviewsToday counts findCards results, unscoped', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockAnki(
        (req) {
          expect(req['action'], 'findCards');
          expect(req['params'], {'query': 'rated:1'});
          return {
            'result': ['card1', 'card2', 'card3'],
            'error': null,
          };
        },
        seen: seen,
      );
      expect(await client.reviewsToday(), 3);
      expect(seen.single['action'], 'findCards');
      client.close();
    });

    test('reviewsToday scopes to the deck, quoting names', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockAnki(
        (req) {
          expect(req['action'], 'findCards');
          return {
            'result': ['only'],
            'error': null,
          };
        },
        seen: seen,
      );
      expect(await client.reviewsToday(deck: 'Japanese'), 1);
      expect(seen.single['params']['query'], 'deck:"Japanese" rated:1');
      await client.reviewsToday(deck: 'Weird "Deck"');
      expect(seen.last['params']['query'],
          'deck:"Weird \\"Deck\\"" rated:1');
      client.close();
    });

    test('deckNames lists decks (connection test)', () async {
      final client = mockAnki((req) {
        expect(req['action'], 'deckNames');
        return {
          'result': ['Default', 'Japanese'],
          'error': null,
        };
      });
      expect(await client.deckNames(), ['Default', 'Japanese']);
      client.close();
    });

    test('Anki errors become displayable AnkiExceptions', () async {
      final errClient = mockAnki(
          (req) => {'result': null, 'error': 'collection is not open'});
      expect(() => errClient.reviewsToday(),
          throwsA(isA<AnkiException>().having((e) => e.message, 'message',
              contains('collection is not open'))));
      errClient.close();

      final httpClient = mockAnki((req) => {
            'result': null,
            'error': null,
            '__status': 500,
          });
      expect(() => httpClient.deckNames(), throwsA(isA<AnkiException>()));
      httpClient.close();

      final shapeClient = mockAnki(
          (req) => {'result': 'not-a-list', 'error': null});
      expect(() => shapeClient.deckNames(), throwsA(isA<AnkiException>()));
      shapeClient.close();
    });

    test('normalizeHost defaults, prefixes, and rejects garbage', () {
      expect(AnkiConnectClient.normalizeHost('').toString(),
          'http://127.0.0.1:8765');
      expect(AnkiConnectClient.normalizeHost('192.168.1.5:8765').host,
          '192.168.1.5');
      expect(() => AnkiConnectClient.normalizeHost('http://'),
          throwsA(isA<AnkiException>()));
      expect(() => AnkiConnectClient(host: 'http://'),
          throwsA(isA<AnkiException>()));
    });
  });
}
