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
        'next_cursor': 'opaque-page-2',
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
    expect(
      stub.requests.last.url.queryParameters['cursor'],
      'opaque-page-2',
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

  test('pull follows more than 25 keyset pages without advancing early', () async {
    final pages = List.generate(27, (index) {
      final hasMore = index < 26;
      return {
        'changes': [_record('e$index', '2026-10-11T10:00:00Z')],
        'server_time': '2026-10-11T10:00:01Z',
        'has_more': hasMore,
        if (hasMore) 'next_cursor': 'cursor-${index + 1}',
      };
    });
    final stub = _StubClient(pages);
    final client = SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: stub,
    );

    final result = await client.pull(since: '2026-10-11T09:00:00Z');

    expect(result.changes, hasLength(27));
    expect(result.changes.map((change) => change.itemId).toSet(), hasLength(27));
    expect(stub.requests, hasLength(27));
    expect(
      stub.requests.first.url.queryParameters['since'],
      '2026-10-11T09:00:00Z',
    );
    expect(stub.requests[1].url.queryParameters['cursor'], 'cursor-1');
    expect(stub.requests.last.url.queryParameters['cursor'], 'cursor-26');
  });

  test('pull rejects an empty incomplete page instead of returning a watermark',
      () async {
    final stub = _StubClient([
      {
        'changes': [],
        'server_time': '2026-10-11T10:00:01Z',
        'has_more': true,
      },
    ]);
    final client = SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: stub,
    );

    await expectLater(client.pull(), throwsA(isA<SyncException>()));
  });

  test('pull rejects an incomplete page without a keyset cursor', () async {
    final stub = _StubClient([
      {
        'changes': [_record('e1', '2026-10-11T10:00:00Z')],
        'server_time': '2026-10-11T10:00:01Z',
        'has_more': true,
      },
    ]);
    final client = SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: stub,
    );

    await expectLater(client.pull(), throwsA(isA<SyncException>()));
  });
}
