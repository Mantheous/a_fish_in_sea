import 'dart:async';
import 'dart:convert';

import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

http.Response _ok() => http.Response(
  jsonEncode({
    'applied': [],
    'event': {
      'id': 'private-event',
      'summary': 'A appointment',
      'start': '2030-01-01T09:00:00Z',
      'end': '2030-01-01T10:00:00Z',
    },
  }),
  200,
);

http.Response _expired() => http.Response('{"detail":"Invalid token"}', 401);

List<Map<String, dynamic>> _changes(int count) => List.generate(
  count,
  (i) => {
    'collection': 'nodes',
    'item_id': 'a-$i',
    'data': {'title': 'A private task $i'},
  },
);

/// Uses the real auth/transport code; only the HTTP server is substituted.
class _Transport {
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? onLogin;
  Future<http.Response> Function(http.Request)? onWrite;
  Completer<http.Response>? refreshResponse;
  final refreshStarted = Completer<void>();
  late final SyncClient sync;
  late final AuthCubit auth;
  late final PlaidService bank;
  late final GoogleCalendarService google;

  _Transport() {
    final client = MockClient((request) async {
      requests.add(request);
      switch (request.url.path) {
        case '/api/v1/auth/login':
          if (onLogin != null) return onLogin!(request);
          final email = jsonDecode(request.body)['email'] as String;
          final account = email.split('@').first;
          return http.Response(
            jsonEncode({
              'access_token': '$account-access',
              'refresh_token': '$account-refresh',
            }),
            200,
          );
        case '/api/v1/auth/logout':
          return http.Response('{}', 200);
        case '/api/v1/auth/refresh':
          refreshStarted.complete();
          final token = jsonDecode(request.body)['refresh_token'] as String;
          final account = token.split('-').first;
          return refreshResponse?.future ??
              Future.value(
                http.Response(
                  jsonEncode({
                    'access_token': '$account-fresh',
                    'refresh_token': '$account-next',
                  }),
                  200,
                ),
              );
        default:
          return onWrite?.call(request) ?? Future.value(_ok());
      }
    });
    sync = SyncClient(
      serverBase: () => 'https://app.test',
      accessToken: () => auth.state.accessToken,
      refreshAccessToken: () => auth.refreshAccessToken(),
      sessionGeneration: () => auth.sessionGeneration,
      client: client,
    );
    auth = AuthCubit(client: () => sync);
    // Exercise the global hooks used by bank services built inside cubits.
    SyncAuth.tokenProvider = () => auth.state.accessToken;
    SyncAuth.refreshProvider = () => auth.refreshAccessToken();
    SyncAuth.sessionGenerationProvider = () => auth.sessionGeneration;
    bank = PlaidService(
      baseUrl: 'https://app.test',
      userId: 'device',
      client: client,
    );
    google = GoogleCalendarService(
      baseUrl: () => 'https://app.test',
      userId: () => 'device',
      authToken: () => auth.state.accessToken,
      refreshAccessToken: () => auth.refreshAccessToken(),
      sessionGeneration: () => auth.sessionGeneration,
      client: client,
    );
    addTearDown(auth.close);
    addTearDown(client.close);
  }

  List<http.Request> get writes =>
      requests.where((r) => !r.url.path.startsWith('/api/v1/auth/')).toList();

  List<http.Request> get refreshes =>
      requests.where((r) => r.url.path == '/api/v1/auth/refresh').toList();

  Future<void> login(String account) async {
    expect(await auth.login('$account@example.com', 'password123'), isTrue);
  }
}

void main() {
  setUp(() {
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() {
    SyncAuth.tokenProvider = null;
    SyncAuth.refreshProvider = null;
    SyncAuth.sessionGenerationProvider = null;
  });

  final event = PlannerEvent(
    id: 'a-event',
    subject: 'A appointment',
    start: DateTime.utc(2030, 1, 1, 9),
    end: DateTime.utc(2030, 1, 1, 10),
  );
  final operations = <String, Future<dynamic> Function(_Transport)>{
    'sync upload': (t) => t.sync.push(_changes(1)),
    'sync delete': (t) => t.sync.apiDelete('/api/v1/tokens/7'),
    'bank exchange': (t) => t.bank.exchangePublicToken('a-public-token'),
    'bank disconnect': (t) => t.bank.disconnect(),
    'Google create': (t) => t.google.createEvent(
      calendarId: 'primary',
      feedId: 'a-feed',
      event: event,
    ),
    'Google update': (t) => t.google.updateEvent(
      calendarId: 'primary',
      feedId: 'a-feed',
      eventId: 'a-event',
      event: event,
    ),
    'Google delete': (t) =>
        t.google.deleteEvent(calendarId: 'primary', eventId: 'a-event'),
  };
  final sessionError = anyOf(
    isA<SyncException>(),
    isA<PlaidServiceException>(),
    isA<GoogleCalendarException>(),
  );

  for (final account in ['a', 'b']) {
    test(
      'upload stops between 400-item batches after sign-out and $account login',
      () async {
        final t = _Transport();
        await t.login('a');
        final firstBatch = Completer<http.Response>();
        final started = Completer<void>();
        t.onWrite = (_) {
          if (t.writes.length > 1) return Future.value(_ok());
          started.complete();
          return firstBatch.future;
        };
        final upload = t.sync.push(_changes(801));
        final aborted = expectLater(upload, throwsA(sessionError));
        await started.future;
        expect(jsonDecode(t.writes.single.body)['changes'], hasLength(400));
        t.auth.logout();
        await t.login(account);
        firstBatch.complete(_ok());
        await aborted;
        expect(t.writes, hasLength(1));
        expect(t.writes.single.headers['Authorization'], 'Bearer a-access');
        expect(t.refreshes, isEmpty);
        expect(t.auth.state.email, '$account@example.com');
      },
    );
  }

  for (final operation in operations.entries) {
    test(
      '${operation.key}: delayed A 401 cannot refresh or retry as B',
      () async {
        final t = _Transport();
        await t.login('a');
        final response = Completer<http.Response>();
        final started = Completer<void>();
        t.onWrite = (_) {
          if (t.writes.length > 1) return Future.value(_ok());
          started.complete();
          return response.future;
        };
        final write = operation.value(t);
        final aborted = expectLater(write, throwsA(sessionError));
        await started.future;
        t.auth.logout();
        await t.login('b');
        response.complete(_expired());
        await aborted;
        expect(t.writes, hasLength(1));
        expect(t.writes.single.headers['Authorization'], 'Bearer a-access');
        expect(t.refreshes, isEmpty);
        expect(t.auth.state.accessToken, 'b-access');
      },
    );

    test(
      '${operation.key}: login completion invalidates interim requests',
      () async {
        final t = _Transport();
        await t.login('a');
        final loginResponse = Completer<http.Response>();
        t.onLogin = (_) => loginResponse.future;
        final signingIn = t.auth.login('b@example.com', 'password123');
        expect(t.auth.state.status, AuthStatus.working);
        final response = Completer<http.Response>();
        final started = Completer<void>();
        t.onWrite = (_) {
          if (t.writes.length > 1) return Future.value(_ok());
          started.complete();
          return response.future;
        };
        final write = operation.value(t);
        final aborted = expectLater(write, throwsA(sessionError));
        await started.future;
        loginResponse.complete(
          http.Response(
            '{"access_token":"b-access","refresh_token":"b-refresh"}',
            200,
          ),
        );
        expect(await signingIn, isTrue);
        response.complete(_expired());
        await aborted;
        expect(t.writes, hasLength(1));
        expect(t.writes.single.headers['Authorization'], 'Bearer a-access');
        expect(t.refreshes, isEmpty);
        expect(t.auth.state.accessToken, 'b-access');
      },
    );

    test(
      '${operation.key}: account change during refresh prevents retry',
      () async {
        final t = _Transport();
        await t.login('a');
        t.refreshResponse = Completer<http.Response>();
        t.onWrite = (_) async => t.writes.length == 1 ? _expired() : _ok();
        final write = operation.value(t);
        final aborted = expectLater(write, throwsA(sessionError));
        await t.refreshStarted.future;
        t.auth.logout();
        await t.login('b');
        t.refreshResponse!.complete(
          http.Response(
            '{"access_token":"a-fresh","refresh_token":"a-next"}',
            200,
          ),
        );
        await aborted;
        expect(t.writes, hasLength(1));
        expect(t.refreshes, hasLength(1));
        expect(
          jsonDecode(t.refreshes.single.body)['refresh_token'],
          'a-refresh',
        );
        expect(t.auth.state.accessToken, 'b-access');
        expect(t.auth.state.refreshToken, 'b-refresh');
      },
    );

    test(
      '${operation.key}: ordinary same-account refresh still retries',
      () async {
        final t = _Transport();
        await t.login('a');
        final generation = t.auth.sessionGeneration;
        t.onWrite = (_) async => t.writes.length == 1 ? _expired() : _ok();
        await operation.value(t);
        expect(t.writes.map((r) => r.headers['Authorization']), [
          'Bearer a-access',
          'Bearer a-fresh',
        ]);
        expect(t.refreshes, hasLength(1));
        expect(t.auth.sessionGeneration, generation);
      },
    );
  }

  test('same-account refresh permits all upload batches', () async {
    final t = _Transport();
    await t.login('a');
    t.onWrite = (_) async => t.writes.length == 1 ? _expired() : _ok();
    await t.sync.push(_changes(801));
    expect(t.writes.map((r) => r.headers['Authorization']), [
      'Bearer a-access',
      'Bearer a-fresh',
      'Bearer a-fresh',
      'Bearer a-fresh',
    ]);
    expect(
      t.writes.map((r) => (jsonDecode(r.body)['changes'] as List).length),
      [400, 400, 400, 1],
    );
    expect(t.refreshes, hasLength(1));
  });
}
