import 'dart:async';
import 'dart:convert';

import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:a_fish_in_sea/planner/service/canvas_service.dart';
import 'package:a_fish_in_sea/planner/service/google_contacts_service.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

const _timeout = Duration(milliseconds: 10);

void main() {
  setUp(() {
    GoogleContactsService.clearSharedCache();
    SyncAuth.tokenProvider = null;
    SyncAuth.refreshTokenProvider = null;
  });
  tearDown(() {
    GoogleContactsService.clearSharedCache();
    SyncAuth.tokenProvider = null;
    SyncAuth.refreshTokenProvider = null;
  });

  group('SyncClient request bounds', () {
    final calls = <String, Future<dynamic> Function(SyncClient)>{
      'register': (c) => c.register('a@example.com', 'password'),
      'login': (c) => c.login('a@example.com', 'password'),
      'refresh': (c) => c.refresh('refresh'),
      'health': (c) => c.health(),
      'pull': (c) => c.pull(),
      'push': (c) => c.push([
        {'collection': 'events', 'item_id': 'e1'},
      ]),
      'delete': (c) => c.apiDelete('/api/v1/tokens/1'),
    };
    for (final entry in calls.entries) {
      test('${entry.key} times out without replaying a hung request', () async {
        var requests = 0;
        final client = SyncClient(
          serverBase: () => 'https://example.test',
          accessToken: () => 'a',
          refreshAccessToken: () async => 'b',
          requestTimeout: _timeout,
          client: MockClient((_) {
            requests++;
            return Completer<http.Response>().future;
          }),
        );
        await expectLater(
          entry.value(client),
          throwsA(isA<TimeoutException>()),
        );
        expect(requests, 1);
      });
    }

    test('response body and refresh callback are also bounded', () async {
      final stream = StreamController<List<int>>();
      final bodyClient = SyncClient(
        serverBase: () => 'https://example.test',
        accessToken: () => 'a',
        refreshAccessToken: () async => 'b',
        requestTimeout: _timeout,
        client: MockClient.streaming((_, __) async {
          return http.StreamedResponse(stream.stream, 200);
        }),
      );
      await expectLater(bodyClient.pull(), throwsA(isA<TimeoutException>()));
      await stream.close();

      var requests = 0;
      final refreshClient = SyncClient(
        serverBase: () => 'https://example.test',
        accessToken: () => 'a',
        refreshAccessToken: () => Completer<String?>().future,
        requestTimeout: _timeout,
        client: MockClient((_) async {
          requests++;
          return http.Response('{"detail":"Invalid token"}', 401);
        }),
      );
      await expectLater(refreshClient.pull(), throwsA(isA<TimeoutException>()));
      expect(requests, 1);
    });

    test(
      'auth refresh gate releases after timeout and retains tokens',
      () async {
        final storage = _Storage();
        when(() => storage.read(any())).thenReturn(null);
        when(() => storage.write(any(), any())).thenAnswer((_) async {});
        HydratedBloc.storage = storage;
        var attempts = 0;
        final client = SyncClient(
          serverBase: () => 'https://example.test',
          accessToken: () => 'a',
          refreshAccessToken: () async => null,
          requestTimeout: _timeout,
          client: MockClient((_) {
            attempts++;
            if (attempts == 1) return Completer<http.Response>().future;
            return Future.value(
              http.Response(
                '{"access_token":"fresh","refresh_token":"rotated"}',
                200,
              ),
            );
          }),
        );
        final auth = AuthCubit(client: () => client);
        auth.emit(
          const AuthState(
            status: AuthStatus.signedIn,
            email: 'a@example.com',
            accessToken: 'old',
            refreshToken: 'refresh',
          ),
        );
        final first = auth.refreshAccessToken();
        expect(identical(first, auth.refreshAccessToken()), isTrue);
        expect(await first, isNull);
        expect(auth.state.isSignedIn, isTrue);
        expect(auth.state.refreshToken, 'refresh');
        expect(await auth.refreshAccessToken(), 'fresh');
        expect(attempts, 2);
        await auth.close();
      },
    );
  });

  test('Canvas refreshes the app token once and re-reads the bearer', () async {
    var token = 'expired';
    var refreshes = 0;
    final headers = <String?>[];
    final service = CanvasService(
      baseUrl: () => 'https://example.test',
      userId: () => 'u',
      authToken: () => token,
      refreshAccessToken: () async {
        refreshes++;
        return token = 'fresh';
      },
      client: MockClient((request) async {
        headers.add(request.headers['Authorization']);
        return token == 'expired'
            ? http.Response('{"detail":"Invalid token"}', 401)
            : http.Response('{"submissions":[]}', 200);
      }),
    );
    expect(await service.fetchSubmissions(), isEmpty);
    expect(refreshes, 1);
    expect(headers, ['Bearer expired', 'Bearer fresh']);
  });

  test('Canvas provider failure never rotates the app session', () async {
    var refreshes = 0;
    final service = CanvasService(
      baseUrl: () => 'https://example.test',
      userId: () => 'u',
      refreshAccessToken: () async {
        refreshes++;
        return 'fresh';
      },
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'detail': {'error': 'Canvas revoked', 'needsReconnect': true},
          }),
          401,
        ),
      ),
    );
    await expectLater(
      service.fetchSubmissions(),
      throwsA(
        isA<CanvasException>().having(
          (e) => e.needsReconnect,
          'reconnect',
          true,
        ),
      ),
    );
    expect(refreshes, 0);
  });

  test(
    'Contacts retries app auth once without suggesting Google reconnect',
    () async {
      var refreshes = 0;
      var requests = 0;
      final service = GoogleContactsService(
        baseUrl: () => 'https://example.test',
        userId: () => 'u',
        refreshAccessToken: () async {
          refreshes++;
          return 'fresh';
        },
        client: MockClient((_) async {
          requests++;
          return http.Response('{"detail":"Invalid token"}', 401);
        }),
      );
      await expectLater(
        service.fetchContacts(),
        throwsA(
          isA<GoogleContactsException>().having(
            (e) => e.needsReconnect,
            'reconnect',
            false,
          ),
        ),
      );
      expect(requests, 2);
      expect(refreshes, 1);
    },
  );

  test('Contacts can fetch after one expired app token response', () async {
    var token = 'expired';
    final service = GoogleContactsService(
      baseUrl: () => 'https://example.test',
      userId: () => 'u',
      authToken: () => token,
      refreshAccessToken: () async => token = 'fresh',
      client: MockClient(
        (request) async => request.headers['Authorization'] == 'Bearer fresh'
            ? http.Response(
                '{"contacts":[{"id":"p1","displayName":"Amy"}]}',
                200,
              )
            : http.Response('{"detail":"Invalid token"}', 401),
      ),
    );
    expect((await service.fetchContacts()).single.id, 'p1');
  });

  test(
    'Plaid uses global refresh hook and preserves provider auth errors',
    () async {
      var token = 'expired';
      var refreshes = 0;
      var providerFailure = false;
      SyncAuth.tokenProvider = () => token;
      SyncAuth.refreshTokenProvider = () async {
        refreshes++;
        return token = 'fresh';
      };
      final service = PlaidService(
        baseUrl: 'https://example.test',
        userId: 'u',
        client: MockClient((request) async {
          if (providerFailure) {
            return http.Response(
              '{"error":{"message":"No bank account connected"}}',
              401,
            );
          }
          return request.headers['Authorization'] == 'Bearer fresh'
              ? http.Response('{"accounts":[]}', 200)
              : http.Response('{"detail":"Invalid token"}', 401);
        }),
      );
      expect(await service.getAccounts(), isEmpty);
      expect(refreshes, 1);
      providerFailure = true;
      await expectLater(
        service.getAccounts(),
        throwsA(
          isA<PlaidServiceException>().having(
            (e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(refreshes, 1);
      service.dispose();
    },
  );

  test(
    'Plaid bounds reads and writes without replaying a timed out write',
    () async {
      var requests = 0;
      final service = PlaidService(
        baseUrl: 'https://example.test',
        userId: 'u',
        requestTimeout: _timeout,
        client: MockClient((_) {
          requests++;
          return Completer<http.Response>().future;
        }),
      );
      final timeoutError = isA<PlaidServiceException>().having(
        (e) => e.message,
        'message',
        contains('timed out'),
      );
      await expectLater(service.getAccounts(), throwsA(timeoutError));
      await expectLater(
        service.exchangePublicToken('public'),
        throwsA(timeoutError),
      );
      expect(requests, 2);
      service.dispose();
    },
  );
}
