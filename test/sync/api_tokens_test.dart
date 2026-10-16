import 'dart:convert';

import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Canned-route stub: records requests, serves (status, jsonBody) per
/// "METHOD path".
class _RouteStub extends http.BaseClient {
  final List<http.Request> requests = [];
  final Map<String, (int, Object)> routes;
  _RouteStub(this.routes);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    requests.add(req);
    // Match on path suffix: SyncClient resolves the base via
    // resolveAppServerBase (build-time SERVER_URL / Tailnet prefix), so
    // tests must not assume an exact host or subpath prefix.
    MapEntry<String, (int, Object)>? hit;
    for (final e in routes.entries) {
      final split = e.key.indexOf(' ');
      final method = e.key.substring(0, split);
      final suffix = e.key.substring(split + 1);
      if (req.method == method && req.url.path.endsWith(suffix)) {
        hit = e;
        break;
      }
    }
    final route = hit?.value;
    final status = route?.$1 ?? 404;
    final payload = route?.$2 ?? {'detail': 'no route'};
    final body = jsonEncode(payload);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

SyncClient _client(_RouteStub stub) => SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'tok',
      refreshAccessToken: () async => 'tok',
      client: stub,
    );

void main() {
  test('ApiToken.fromJson tolerates missing optional fields', () {
    final t = ApiToken.fromJson({'id': 7});
    expect(t.id, 7);
    expect(t.name, '');
    expect(t.prefix, '');
    expect(t.scopes, isEmpty);
    expect(t.review, isFalse);
  });

  test('listApiTokens hits GET /api/v1/tokens and parses metadata', () async {
    final stub = _RouteStub({
      'GET /api/v1/tokens': (
        200,
        [
          {
            'id': 1,
            'name': 'agent',
            'prefix': 'afm',
            'scopes': ['sync'],
            'review': true,
          },
          {'id': 2, 'name': '', 'prefix': 'afm', 'scopes': ['sync']},
        ],
      ),
    });
    final tokens = await _client(stub).listApiTokens();
    expect(stub.requests.single.method, 'GET');
    expect(stub.requests.single.url.path.endsWith('/api/v1/tokens'), isTrue);
    expect(tokens, hasLength(2));
    expect(tokens.first.review, isTrue);
    expect(tokens.last.review, isFalse);
    expect(tokens.first.scopes, ['sync']);
  });

  test('createApiToken posts name/scopes/review and returns the secret once',
      () async {
    final stub = _RouteStub({
      'POST /api/v1/tokens': (
        201,
        {
          'id': 3,
          'name': 'laptop',
          'prefix': 'afm',
          'scopes': ['sync'],
          'review': false,
          'token': 'afm_secret-once',
        },
      ),
    });
    final created = await _client(stub).createApiToken(
      name: 'laptop',
      review: false,
    );
    final req = stub.requests.single;
    expect(req.method, 'POST');
    final sent = jsonDecode(req.body) as Map<String, dynamic>;
    expect(sent['name'], 'laptop');
    expect(sent['scopes'], ['sync']);
    expect(sent['review'], isFalse);
    expect(created.info.id, 3);
    expect(created.token, 'afm_secret-once');
  });

  test('revokeApiToken DELETEs /api/v1/tokens/{id}', () async {
    final stub = _RouteStub({
      'DELETE /api/v1/tokens/42': (200, {}),
    });
    await _client(stub).revokeApiToken(42);
    expect(stub.requests.single.method, 'DELETE');
    expect(stub.requests.single.url.path.endsWith('/api/v1/tokens/42'), isTrue);
  });

  test('listApiTokens surfaces server errors as SyncException', () async {
    final stub = _RouteStub({
      'GET /api/v1/tokens': (401, {'detail': 'Invalid token'}),
    });
    final client = SyncClient(
      serverBase: () => 'http://localhost:8000',
      accessToken: () => 'bad',
      // Refresh fails -> client must throw, not retry forever.
      refreshAccessToken: () async => null,
      client: stub,
    );
    expect(() => client.listApiTokens(), throwsA(isA<SyncException>()));
  });
}
