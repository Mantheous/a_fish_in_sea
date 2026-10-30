import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

const authResponseError =
    'The server did not complete sign-in. Please try again.';

void main() {
  setUp(() {
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  for (final register in [false, true]) {
    final action = register ? 'register' : 'login';
    test('$action accepts the server token pair', () async {
      final client = SyncClient(
        serverBase: () => '',
        accessToken: () => null,
        refreshAccessToken: () async => null,
        client: MockClient(
          (_) async => http.Response(
            '{"access_token":"access","refresh_token":"refresh","token_type":"bearer"}',
            register ? 201 : 200,
          ),
        ),
      );
      final auth = AuthCubit(client: () => client);
      addTearDown(auth.close);
      expect(
        await (register ? auth.register : auth.login)(
          'newcomer@example.com',
          'password123',
        ),
        isTrue,
      );
      expect(auth.state.isSignedIn, isTrue);
      expect(auth.state.accessToken, 'access');
      expect(auth.state.refreshToken, 'refresh');
      expect(auth.state.error, isNull);
    });
    for (final body in [
      '',
      '<html>proxy fallback</html>',
      '{}',
      '[]',
      '{"access_token":"","refresh_token":"refresh"}',
      '{"access_token":"access","refresh_token":null}',
      '{"access_token":42,"refresh_token":"refresh"}',
    ]) {
      test('$action rejects incomplete success response $body', () async {
        final client = SyncClient(
          serverBase: () => '',
          accessToken: () => null,
          refreshAccessToken: () async => null,
          client: MockClient((request) async {
            expect(request.url.path, '/api/v1/auth/$action');
            return http.Response(body, register ? 201 : 200);
          }),
        );
        final auth = AuthCubit(client: () => client);
        addTearDown(auth.close);
        final ok = await (register ? auth.register : auth.login)(
          'newcomer@example.com',
          'password123',
        );
        expect(ok, isFalse);
        expect(auth.state.status, AuthStatus.signedOut);
        expect(auth.state.error, authResponseError);
        expect(auth.state.accessToken, isNull);
      });
    }
  }
}
