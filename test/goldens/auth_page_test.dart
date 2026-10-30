import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/view/auth/auth_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

void main() {
  for (final scenario in [
    (
      name: 'bad_password',
      button: 'Sign in',
      status: 401,
      body: '{"detail":"Invalid credentials"}',
      error: 'Invalid credentials',
    ),
    (
      name: 'duplicate_account',
      button: 'Create account',
      status: 409,
      body: '{"detail":"Email already registered"}',
      error: 'Email already registered',
    ),
    (
      name: 'invalid_response',
      button: 'Sign in',
      status: 200,
      body: '<html>proxy fallback</html>',
      error: 'The server did not complete sign-in. Please try again.',
    ),
  ]) {
    testWidgets('${scenario.name} stays visible on sign-in card', (
      tester,
    ) async {
      final storage = _Storage();
      when(() => storage.read(any())).thenReturn(null);
      when(() => storage.write(any(), any())).thenAnswer((_) async {});
      HydratedBloc.storage = storage;
      final auth = AuthCubit(
        client: () => SyncClient(
          serverBase: () => '',
          accessToken: () => null,
          refreshAccessToken: () async => null,
          client: MockClient(
            (_) async => http.Response(scenario.body, scenario.status),
          ),
        ),
      );
      addTearDown(auth.close);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        BlocProvider.value(
          value: auth,
          child: const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: AuthPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'newcomer@example.com',
      );
      await tester.enterText(find.byType(TextField).last, 'password123');
      await tester.tap(find.text(scenario.button));
      await tester.pumpAndSettle();
      expect(find.text(scenario.error), findsOneWidget);
      expect(auth.state.status, AuthStatus.signedOut);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'))
            .onPressed,
        isNotNull,
      );
      await expectLater(
        find.byType(AuthPage),
        matchesGoldenFile('auth_page_test.${scenario.name}.png'),
      );
    });
  }
}
