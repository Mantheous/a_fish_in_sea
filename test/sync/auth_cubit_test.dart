import 'dart:io';

import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

// A transport whose /auth/refresh behavior is scripted per test, so each
// failure mode in the #60 contract gets its own case.
class _ScriptedRefreshClient extends SyncClient {
  Future<Map<String, dynamic>> Function()? onRefresh;

  _ScriptedRefreshClient()
      : super(
          serverBase: () => '',
          accessToken: () => null,
          refreshAccessToken: () async => null,
        );

  @override
  Future<Map<String, dynamic>> refresh(String refreshToken) =>
      onRefresh!();
}

const _signedIn = AuthState(
  status: AuthStatus.signedIn,
  email: 'a@example.com',
  accessToken: 'at-1',
  refreshToken: 'rt-1',
);

void main() {
  late Storage storage;
  late _ScriptedRefreshClient client;
  late AuthCubit cubit;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    client = _ScriptedRefreshClient();
    cubit = AuthCubit(client: () => client);
    cubit.emit(_signedIn);
  });

  tearDown(() => cubit.close());

  test('transient SocketException keeps the user signed in (refs #60)',
      () async {
    client.onRefresh = () => throw const SocketException(
          'network unreachable',
        );
    expect(await cubit.refreshAccessToken(), isNull);
    expect(cubit.state.isSignedIn, isTrue);
    expect(cubit.state.accessToken, 'at-1');
    expect(cubit.state.refreshToken, 'rt-1');
  });

  test('refresh timeout keeps the user signed in (refs #60)', () async {
    client.onRefresh = () => throw const SyncException(
          0,
          'Request timed out after 30s',
        );
    expect(await cubit.refreshAccessToken(), isNull);
    expect(cubit.state.isSignedIn, isTrue);
    expect(cubit.state.accessToken, 'at-1');
    expect(cubit.state.refreshToken, 'rt-1');
  });

  test('refresh 5xx keeps the user signed in (refs #60)', () async {
    client.onRefresh = () => throw const SyncException(
          500,
          'Internal Server Error',
        );
    expect(await cubit.refreshAccessToken(), isNull);
    expect(cubit.state.isSignedIn, isTrue);
    expect(cubit.state.accessToken, 'at-1');
    expect(cubit.state.refreshToken, 'rt-1');
  });

  test('refresh 401 signs out and clears tokens (refs #60)', () async {
    client.onRefresh = () => throw const SyncException(
          401,
          'Invalid refresh token',
        );
    expect(await cubit.refreshAccessToken(), isNull);
    expect(cubit.state.isSignedIn, isFalse);
    expect(cubit.state.status, AuthStatus.signedOut);
    expect(cubit.state.accessToken, isNull);
    expect(cubit.state.refreshToken, isNull);
  });

  test('refresh 403 signs out and clears tokens (refs #60)', () async {
    client.onRefresh = () => throw const SyncException(
          403,
          'Refresh token revoked',
        );
    expect(await cubit.refreshAccessToken(), isNull);
    expect(cubit.state.isSignedIn, isFalse);
    expect(cubit.state.status, AuthStatus.signedOut);
    expect(cubit.state.accessToken, isNull);
    expect(cubit.state.refreshToken, isNull);
  });

  test(
      'empty refresh token signs out cleanly instead of wedging signed-in '
      '(refs #60)', () async {
    cubit.emit(const AuthState(
      status: AuthStatus.signedIn,
      email: 'a@example.com',
      accessToken: 'at-1',
    ));
    expect(cubit.state.isSignedIn, isTrue);

    expect(await cubit.refreshAccessToken(), isNull);
    expect(cubit.state.status, AuthStatus.signedOut);
    expect(cubit.state.accessToken, isNull);
    expect(cubit.state.refreshToken, isNull);
  });

  test('working status is never restored across restarts (refs #60)', () {
    const working = AuthState(
      status: AuthStatus.working,
      email: 'a@example.com',
      accessToken: 'at-1',
      refreshToken: 'rt-1',
    );

    // toJson never persists working: an interrupted login/refresh restores
    // as signed-in, never wedged in working.
    final persisted = cubit.toJson(working);
    expect(persisted['status'], AuthStatus.signedIn.name);
    expect(cubit.fromJson(persisted)!.status, AuthStatus.signedIn);

    // Older snapshots that wrote working directly recover the same way.
    final legacy = cubit.fromJson({
      ...persisted,
      'status': AuthStatus.working.name,
    })!;
    expect(legacy.status, AuthStatus.signedIn);

    // Working without tokens restores signed out.
    expect(
      cubit.fromJson({
        'status': AuthStatus.working.name,
        'email': 'a@example.com',
      })!.status,
      AuthStatus.signedOut,
    );
  });
}
