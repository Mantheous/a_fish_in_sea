import 'dart:convert';

import 'package:a_fish_in_sea/feedback/feedback_service.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Serves raw bodies (garbage, empty, or valid JSON) with a fixed status.
class _RawStubClient extends http.BaseClient {
  final List<String> bodies;
  _RawStubClient(this.bodies);
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    return http.StreamedResponse(
      Stream.value(utf8.encode(bodies[(calls - 1) % bodies.length])),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

SyncClient _client(List<String> bodies) => SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: _RawStubClient(bodies),
    );

void main() {
  group('list endpoints treat invalid JSON as empty', () {
    test('mine returns [] for empty / garbage / non-list bodies', () async {
      final service = FeedbackService(_client(['', '<html>...</html>', '[]']));
      expect(await service.mine(), equals(const <FeedbackReport>[]));
      expect(await service.mine(), equals(const <FeedbackReport>[]));
      expect(await service.mine(), equals(const <FeedbackReport>[]));
    });

    test('pending returns [] for invalid JSON', () async {
      final service = FeedbackService(_client(['{not valid', '42', '']));
      expect(await service.pending(), equals(const <FeedbackReport>[]));
    });

    test('trusted returns [] for invalid JSON', () async {
      final service = FeedbackService(_client(['<html>proxy</html>']));
      expect(await service.trusted(), equals(const <TrustedReporter>[]));
    });

    test('real lists still parse', () async {
      final service = FeedbackService(_client([
        jsonEncode([
          {
            'id': 1,
            'kind': 'bug',
            'title': 't',
            'description': 'd',
            'device': 'web',
            'status': 'pending',
            'email': 'a@example.com'
          }
        ])
      ]));
      final mine = await service.mine();
      expect(mine, hasLength(1));
      expect(mine.first.id, 1);
    });
  });

  group('map endpoints tolerate null body', () {
    test('status does not throw on empty JSON', () async {
      final service = FeedbackService(_client(['']));
      final status = await service.status();
      expect(status.isAdmin, isFalse);
      expect(status.isTrusted, isFalse);
    });

    test('submit echoes back a report parsed from an empty object', () async {
      final service = FeedbackService(_client([
        jsonEncode({
          'id': 7,
          'kind': 'feature',
          'title': 't',
          'description': 'd',
          'device': 'web',
          'status': 'pending',
        })
      ]));
      final report = await service.submit(
        kind: 'feature',
        title: 't',
        description: 'd',
      );
      expect(report.id, 7);
    });

    test('approve and deny tolerate empty JSON without throwing', () async {
      final service = FeedbackService(_client(['{}', '{}']));
      final approved = await service.approve(1);
      final denied = await service.deny(1, 'why');
      expect(approved.id, 0);
      expect(denied.id, 0);
    });
  });
}
