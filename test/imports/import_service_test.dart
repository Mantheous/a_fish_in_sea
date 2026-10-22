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

  group('withWarningsFrom fills warnings the server omitted', () {
    ImportBatch batchOf(List<Map<String, dynamic>> items) =>
        ImportBatch.fromJson({
          'id': 7,
          'source': 'Email forward',
          'status': 'pending',
          'created_at': '2026-10-11T10:00:00Z',
          'items': items,
        });

    Map<String, dynamic> item(
      String id, {
      String status = 'pending',
      Map<String, dynamic>? existing,
      bool existingDeleted = false,
    }) =>
        {
          'collection': 'nodes',
          'item_id': id,
          'data': {
            'id': id,
            'title': 'T $id',
            'schedule': {'due': '2026-10-20T23:59:00'}
          },
          'status': status,
          if (existing != null) 'existing': existing,
          'existing_deleted': existingDeleted,
        };

    Map<String, dynamic> live(String id) => {
          'id': id,
          'title': 'T $id',
          'schedule': {'due': '2026-10-15T23:59:00'}
        };

    test('inherits missing existing from the previous batch', () {
      final previous = batchOf([
        item('fresh'),
        item('collide', existing: live('collide')),
      ]);
      // Server decided fresh but dropped collide's conflict context.
      final updated = batchOf([
        item('fresh', status: 'approved'),
        item('collide'),
      ]);

      final merged = updated.withWarningsFrom(previous);

      expect(merged.items[0].status, 'approved');
      expect(merged.items[0].existing, isNull);
      expect(merged.items[1].isUpdate, isTrue);
      expect(merged.items[1].existing!['schedule']['due'],
          '2026-10-15T23:59:00');
      // The decided row keeps its own (lack of) warning.
      expect(merged, isNot(same(updated)));
    });

    test('inherits existing_deleted restore flag', () {
      final previous = batchOf([
        item('gone', existing: live('gone'), existingDeleted: true),
      ]);
      final updated = batchOf([item('gone')]);

      final merged = updated.withWarningsFrom(previous);

      expect(merged.items.single.existingDeleted, isTrue);
      expect(merged.items.single.existing, isNotNull);
    });

    test('a fresh server warning wins over the stale one', () {
      final previous = batchOf([
        item('collide', existing: live('collide')),
      ]);
      final newerLive = {
        'id': 'collide',
        'title': 'T collide',
        'schedule': {'due': '2026-10-16T23:59:00'}
      };
      final updated = batchOf([
        item('collide', existing: newerLive),
      ]);

      final merged = updated.withWarningsFrom(previous);

      expect(
          merged.items.single.existing!['schedule']['due'],
          '2026-10-16T23:59:00');
      expect(merged, same(updated));
    });

    test('no warnings anywhere returns the same batch', () {
      final previous = batchOf([item('a')]);
      final updated = batchOf([item('a', status: 'approved')]);

      expect(updated.withWarningsFrom(previous), same(updated));
    });
  });
}
