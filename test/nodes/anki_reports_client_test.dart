import 'dart:convert';

import 'package:a_fish_in_sea/anki/anki_reports.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SyncClient _client(MockClient mock) => SyncClient(
  serverBase: () => '',
  accessToken: () => 'jwt',
  refreshAccessToken: () async => null,
  client: mock,
);

void main() {
  test('requests the date window and parses days', () async {
    late http.Request seen;
    final client = _client(
      MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'days': [
              {
                'day': '2026-11-03',
                'deck': 'Japanese',
                'cards': 4,
                'reviews': 6,
              },
            ],
            'decks': [
              {
                'name': 'Japanese',
                'cards': 4,
                'reviews': 6,
                'last_day': '2026-11-03',
              },
            ],
            'last_report_at': '2026-11-03T18:30:00+00:00',
            'last_client': 'anki/1.0',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final data = await fetchAnkiReport(
      client,
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 4),
    );

    expect(seen.method, 'GET');
    expect(seen.url.path, '/api/v1/anki/reviews');
    expect(seen.url.queryParameters, {
      'start': '2026-11-01',
      'end': '2026-11-04',
    });
    expect(seen.headers['authorization'], 'Bearer jwt');
    expect(data.days.single.cards, 4);
    expect(data.days.single.reviews, 6);
    expect(data.decks.single.name, 'Japanese');
    expect(data.lastClient, 'anki/1.0');
  });

  test('401 becomes a sign-in message, not a raw status', () async {
    final client = _client(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': 'Missing bearer token'}),
          401,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      fetchAnkiReport(
        client,
        start: DateTime(2026, 11, 1),
        end: DateTime(2026, 11, 4),
      ),
      throwsA(
        isA<AnkiReportException>().having(
          (e) => e.message,
          'message',
          contains('Sign in'),
        ),
      ),
    );
  });
}
