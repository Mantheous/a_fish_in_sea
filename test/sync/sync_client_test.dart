import 'dart:convert';

import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Serves canned pull pages in order and records every request.
class _StubClient extends http.BaseClient {
  final List<http.Request> requests = [];
  final List<Map<String, dynamic>> pages;
  _StubClient(this.pages);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    final body = jsonEncode(pages.removeAt(0));
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

Map<String, dynamic> _record(String id, String updatedAt) => {
      'collection': 'events',
      'item_id': id,
      'data': {'id': id},
      'deleted': false,
      'rev': 1,
      'updated_at': updatedAt,
    };

void main() {
  test('pull follows has_more pages and advances the cursor', () async {
    final stub = _StubClient([
      {
        'changes': [
          _record('e1', '2026-10-11T10:00:00Z'),
          _record('e2', '2026-10-11T10:00:01Z'),
        ],
        'server_time': '2026-10-11T10:00:02Z',
        'has_more': true,
      },
      {
        'changes': [_record('e3', '2026-10-11T10:00:03Z')],
        'server_time': '2026-10-11T10:00:04Z',
        'has_more': false,
      },
    ]);
    final client = SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: stub,
    );

    final result = await client.pull(since: '2026-10-11T09:00:00Z');

    expect(result.changes.map((c) => c.itemId), ['e1', 'e2', 'e3']);
    expect(result.serverTime, '2026-10-11T10:00:04Z');
    expect(stub.requests, hasLength(2));
    expect(
      stub.requests.first.url.queryParameters['since'],
      '2026-10-11T09:00:00Z',
    );
    // The second page continues from the last item of the first page, so a
    // client that fell far behind never silently skips changes.
    expect(
      stub.requests.last.url.queryParameters['since'],
      '2026-10-11T10:00:01.000Z',
    );
  });

  test('pull without has_more stops after one request', () async {
    final stub = _StubClient([
      {
        'changes': [_record('e1', '2026-10-11T10:00:00Z')],
        'server_time': '2026-10-11T10:00:01Z',
        'has_more': false,
      },
    ]);
    final client = SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: stub,
    );

    final result = await client.pull();
    expect(result.changes, hasLength(1));
    expect(stub.requests, hasLength(1));
    expect(stub.requests.single.url.queryParameters.containsKey('since'), isFalse);
  });
}
