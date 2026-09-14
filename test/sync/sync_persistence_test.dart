import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

SyncClient _dummyClient() => SyncClient(
      serverBase: () => '',
      accessToken: () => null,
      refreshAccessToken: () async => null,
    );

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  test('AuthCubit round-trips tokens', () {
    final cubit = AuthCubit(client: _dummyClient);
    final json = cubit.toJson(const AuthState(
      status: AuthStatus.signedIn,
      email: 'a@example.com',
      accessToken: 'at',
      refreshToken: 'rt',
    ));
    final restored = cubit.fromJson(json)!;
    expect(restored.email, 'a@example.com');
    expect(restored.accessToken, 'at');
    expect(restored.isSignedIn, isTrue);
  });

  test('AuthCubit tolerates corrupt payloads (never wipes to signed-in)',
      () {
    final cubit = AuthCubit(client: _dummyClient);
    expect(cubit.fromJson({}), isNotNull);
    expect(cubit.fromJson({})!.isSignedIn, isFalse);
    // Tokens without a signed-in marker stay signed out.
    final restored = cubit.fromJson({
      'status': 'bogus-status',
      'email': 'a@example.com',
      'accessToken': 'at',
    })!;
    expect(restored.isSignedIn, isFalse);
    expect(cubit.fromJson({'status': 42}), isNotNull);
  });

  test('SyncMetaCubit round-trips cursor and item meta', () {
    final cubit = SyncMetaCubit();
    cubit.save(
      cursor: '2026-09-12T00:00:00Z',
      upsert: {
        'tasks/t1': const ItemMeta(hash: 'ab', serverTime: '2026-09-12T00:00:00Z')
      },
    );
    final restored = cubit.fromJson(cubit.toJson(cubit.state))!;
    expect(restored.cursor, '2026-09-12T00:00:00Z');
    expect(restored.items['tasks/t1']?.hash, 'ab');
  });

  test('SyncMetaCubit tolerates corrupt entries', () {
    final cubit = SyncMetaCubit();
    final restored = cubit.fromJson({
      'cursor': 'x',
      'items': {
        'good': {'hash': 'h', 'serverTime': 't'},
        'bad': 'not-a-map',
        'alsobad': {'hash': 42},
      },
    })!;
    expect(restored.items.keys, contains('good'));
    expect(restored.items.keys, isNot(contains('bad')));
    // Wrong-typed entries are skipped per-item, never fatal.
    expect(restored.items.keys, isNot(contains('alsobad')));
  });
}
