import 'dart:convert';

import 'package:a_fish_in_sea/fitness/bloc/fitness_cubit.dart';
import 'package:a_fish_in_sea/fitness/fitness_service.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late NodeCubit nodes;

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
  });

  tearDown(() async {
    await nodes.close();
  });

  FitnessCubit build(
    Future<http.Response> Function(http.Request request) handler, {
    Future<String?> Function()? refreshAccessToken,
    String? token = 'jwt',
  }) {
    final client = MockClient(handler);
    return FitnessCubit(
      service: FitnessService(
        baseUrl: () => 'http://localhost:1',
        authToken: () => token,
        refreshAccessToken: refreshAccessToken,
        client: client,
      ),
      nodes: nodes,
    );
  }

  test('connected status syncs activities into workout actuals', () async {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day, 7);
    final end = start.add(const Duration(minutes: 30));
    nodes.emitSilent([
      Node(
        id: 'w1',
        title: 'Morning run',
        createdAt: start,
        schedule: ScheduleFacet(due: start),
        isWorkout: true,
      ),
    ]);

    final cubit = build((request) async {
      final path = request.url.path;
      if (path.endsWith('/status')) {
        return http.Response(
          jsonEncode({
            'connected': true,
            'configured': true,
            'athlete': 'Ash Runner',
            'supportsSleep': false,
          }),
          200,
        );
      }
      if (path.endsWith('/activities')) {
        return http.Response(
          jsonEncode({
            'connected': true,
            'activities': [
              {
                'id': 'strava:1',
                'type': 'run',
                'start': start.toUtc().toIso8601String(),
                'end': end.toUtc().toIso8601String(),
                'provider': 'strava',
              },
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'sleep': [], 'supported': false}), 200);
    });
    addTearDown(cubit.close);

    await cubit.refresh();

    expect(cubit.state.link, FitnessLink.connected);
    expect(cubit.state.athlete, 'Ash Runner');
    expect(cubit.state.activities, hasLength(1));
    expect(nodes.state.single.hasReported, isTrue);
    expect(nodes.state.single.reportedDuration?.inMinutes, 30);
  });

  test('unconfigured server exposes the callback URL for setup', () async {
    final cubit = build((request) async {
      if (request.url.path.endsWith('/auth_url')) {
        return http.Response(
          jsonEncode({
            'detail': {
              'error': 'Server is missing STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET',
              'needsSetup': true,
              'redirectUri':
                  'https://example.test/fish/api/fitness/callback',
            }
          }),
          503,
        );
      }
      return http.Response(
        jsonEncode({
          'connected': false,
          'configured': false,
          'redirectUri': 'https://example.test/fish/api/fitness/callback',
          'supportsSleep': false,
        }),
        200,
      );
    });
    addTearDown(cubit.close);

    await cubit.refresh();
    expect(cubit.state.link, FitnessLink.unconfigured);
    expect(cubit.state.redirectUri,
        'https://example.test/fish/api/fitness/callback');

    final url = await cubit.connectUrl();
    expect(url, isNull);
    expect(cubit.state.link, FitnessLink.unconfigured);
    expect(cubit.state.error, contains('STRAVA_CLIENT_ID'));
  });

  test('revoked Strava grant drops to disconnected without a JWT refresh',
      () async {
    var refreshed = false;
    final cubit = build(
      (request) async {
        if (request.url.path.endsWith('/activities')) {
          return http.Response(
            jsonEncode({
              'detail': {
                'error': 'Strava connection needs renewal',
                'needsReconnect': true,
              }
            }),
            401,
          );
        }
        return http.Response(
          jsonEncode({
            'connected': true,
            'configured': true,
            'athlete': 'Ash',
            'supportsSleep': false,
          }),
          200,
        );
      },
      refreshAccessToken: () async {
        refreshed = true;
        return 'fresh';
      },
    );
    addTearDown(cubit.close);

    await cubit.refresh();

    expect(cubit.state.link, FitnessLink.disconnected);
    expect(cubit.state.error, contains('needs renewal'));
    // A dead Strava token must not churn the app's own JWT.
    expect(refreshed, isFalse);
  });

  test('app session expiry refreshes the JWT once and retries', () async {
    var attempts = 0;
    final cubit = build(
      (request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response(jsonEncode({'detail': 'Invalid token'}), 401);
        }
        return http.Response(
          jsonEncode({
            'connected': false,
            'configured': true,
            'supportsSleep': false,
          }),
          200,
        );
      },
      refreshAccessToken: () async => 'fresh',
    );
    addTearDown(cubit.close);

    await cubit.refresh();

    expect(attempts, 2);
    expect(cubit.state.link, FitnessLink.disconnected);
  });

  test('signed-out refreshOnce does not touch the server', () async {
    var called = false;
    final cubit = build(
      (request) async {
        called = true;
        return http.Response('{}', 200);
      },
      token: null,
    );
    addTearDown(cubit.close);

    await cubit.refreshOnce();

    expect(called, isFalse);
    expect(cubit.state.link, FitnessLink.unknown);
  });

  test('disconnect clears derived activities', () async {
    final cubit = build((request) async {
      if (request.method == 'POST') {
        return http.Response(jsonEncode({'status': 'disconnected'}), 200);
      }
      if (request.url.path.endsWith('/activities')) {
        return http.Response(
          jsonEncode({
            'connected': true,
            'activities': [
              {
                'id': 'strava:9',
                'type': 'ride',
                'start': '2026-10-20T13:00:00Z',
                'end': '2026-10-20T14:00:00Z',
                'provider': 'strava',
              }
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/status')) {
        return http.Response(
          jsonEncode({
            'connected': true,
            'configured': true,
            'athlete': 'Ash',
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'sleep': []}), 200);
    });
    addTearDown(cubit.close);

    await cubit.refresh();
    expect(cubit.state.activities, hasLength(1));

    await cubit.disconnect();
    expect(cubit.state.link, FitnessLink.disconnected);
    expect(cubit.state.activities, isEmpty);
    expect(cubit.state.athlete, isNull);
  });
}
