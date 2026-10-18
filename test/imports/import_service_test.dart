import 'dart:convert';

import 'package:a_fish_in_sea/imports/import_service.dart';
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
  group('pending treats invalid JSON as empty', () {
    test('empty body', () async {
      final service = ImportService(_client(['']));
      expect(await service.pending(), equals(const <ImportBatch>[]));
    });

    test('proxy HTML', () async {
      final service = ImportService(_client(['<html>captive portal</html>']));
      expect(await service.pending(), equals(const <ImportBatch>[]));
    });

    test('non-list JSON', () async {
      final service = ImportService(_client(['42', '{"not": "a list}']));
      expect(await service.pending(), equals(const <ImportBatch>[]));
    });

    test('real list still parses', () async {
      final service = ImportService(_client([
        jsonEncode([
          {
            'id': 1,
            'source': 's',
            'status': 'pending',
            'created_at': '2026-10-11T10:00:00Z',
            'items': []
          }
        ])
      ]));
      final batches = await service.pending();
      expect(batches, hasLength(1));
      expect(batches.first.id, 1);
    });
  });

  group('write endpoints tolerate empty JSON', () {
    test('approve / discard / reject on empty body', () async {
      final service = ImportService(_client(['{}', '{}', '{}']));
      final batch = await service.approve(1);
      expect(batch.id, 0);
      await service.discard(1, const []);
      await service.reject(1);
    });
  });
}
