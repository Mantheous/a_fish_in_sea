import 'package:a_fish_in_sea/demo/demo_cubit.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/view/auth/auth_gate.dart';
import 'package:a_fish_in_sea/sync/view/auth/auth_page.dart';
import 'package:a_fish_in_sea/sync/view/auth/login_wave.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

class _StubClient extends SyncClient {
  _StubClient()
    : super(
        serverBase: () => 'http://localhost:8000',
        accessToken: () => null,
        refreshAccessToken: () async => null,
      );
}

const _signedIn = AuthState(
  status: AuthStatus.signedIn,
  email: 'sea@example.com',
  accessToken: 'token',
  refreshToken: 'refresh',
);

void main() {
  late AuthCubit auth;
  late DemoCubit demo;

  setUp(() {
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    auth = AuthCubit(client: () => _StubClient());
    demo = DemoCubit();
  });

  tearDown(() async {
    await auth.close();
    await demo.close();
  });

  Future<void> pumpGate(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: auth),
          BlocProvider<DemoCubit>.value(value: demo),
        ],
        child: const MaterialApp(home: AuthGate(child: Text('APP HOME'))),
      ),
    );
    await tester.pump();
  }

  // Signing in is driven by the cubit; tests fire the same state the login
  // call emits. (emit is protected, but this is the state seam under test.)
  void signIn() =>
      auth.emit(_signedIn); // ignore: invalid_use_of_protected_member

  testWidgets('signed out shows the sign-in scene, not the app', (
    tester,
  ) async {
    await pumpGate(tester);
    expect(find.byType(AuthPage), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);
    expect(find.byKey(loginWaveOverlayKey), findsNothing);
  });

  testWidgets('signing in drops the wave, then reveals the app', (
    tester,
  ) async {
    await pumpGate(tester);
    signIn();
    await tester.pump();

    // The app is mounted underneath, the login scene and the wave are on top.
    expect(find.text('APP HOME'), findsOneWidget);
    expect(find.byType(AuthPage), findsOneWidget);
    expect(find.byKey(loginWaveOverlayKey), findsOneWidget);

    // 1100ms fall plus a frame to remove the overlay.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();

    expect(find.byKey(loginWaveOverlayKey), findsNothing);
    expect(find.byType(AuthPage), findsNothing);
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets('entering demo mode plays the same reveal', (tester) async {
    await pumpGate(tester);
    demo.entered();
    await tester.pump();

    expect(find.text('APP HOME'), findsOneWidget);
    expect(find.byKey(loginWaveOverlayKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(find.byKey(loginWaveOverlayKey), findsNothing);
    expect(find.byType(AuthPage), findsNothing);
  });

  testWidgets('signing out comes back to the sign-in scene', (tester) async {
    await pumpGate(tester);
    signIn();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(find.byType(AuthPage), findsNothing);

    auth.emit(const AuthState()); // ignore: invalid_use_of_protected_member
    // The provider notifies dependents after the frame, so the gate rebuilds
    // on the following pump.
    await tester.pump();
    await tester.pump();

    expect(find.byType(AuthPage), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);
    expect(find.byKey(loginWaveOverlayKey), findsNothing);
  });

  test('wave starts above the screen and ends below it', () {
    const size = Size(420, 820);
    final start = const WaveGeometry(size: size, progress: 0).topAt(210);
    final end = const WaveGeometry(size: size, progress: 1).topAt(210);
    expect(start, lessThan(0));
    expect(end, greaterThan(size.height));
  });
}
