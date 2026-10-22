import 'package:a_fish_in_sea/demo/demo_cubit.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/feedback/view/feedback_page.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// SyncClient stub that counts calls and never touches the network.
class _RecordingClient extends SyncClient {
  int getCount = 0;
  int postCount = 0;
  bool throwOnGet = false;

  _RecordingClient()
      : super(
          serverBase: () => 'http://localhost:8000',
          accessToken: () => null,
          refreshAccessToken: () async => null,
        );

  @override
  Future<dynamic> apiGet(String path, [Map<String, String>? query]) async {
    getCount++;
    if (throwOnGet) throw const SyncException(401, 'Signed out');
    return null;
  }

  @override
  Future<dynamic> apiPost(String path, Map<String, dynamic> body) async {
    postCount++;
    return null;
  }
}

Future<SyncClient> pumpPage(
  WidgetTester tester, {
  required bool demo,
  bool throwOnGet = false,
}) async {
  DemoMode.isActive = demo;
  final client = _RecordingClient()..throwOnGet = throwOnGet;
  // Tall surface so every card (including My reports below the fold) is
  // rendered and findable without scrolling.
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthCubit>(create: (_) => AuthCubit(client: () => client)),
        BlocProvider<NavigationCubit>(create: (_) => NavigationCubit()),
        BlocProvider<DemoCubit>(create: (_) => DemoCubit()),
      ],
      child: const MaterialApp(home: FeedbackPage()),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

void main() {
  late MockStorage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    DemoMode.isActive = false;
  });

  tearDown(() {
    DemoMode.isActive = false;
  });

  testWidgets('demo mode shows seeded reports without calling the server',
      (tester) async {
    final client = await pumpPage(tester, demo: true) as _RecordingClient;

    expect(find.text('My reports (2)'), findsOneWidget);
    expect(find.text('Nothing submitted yet.'), findsNothing);
    expect(find.text('Review queue'), findsNothing);
    expect(find.text('Signed out'), findsNothing);
    // No server calls: the demo tab is fully offline.
    expect(client.getCount, 0);
  });

  testWidgets('submit is read-only in demo mode and calls no server',
      (tester) async {
    final client = await pumpPage(tester, demo: true) as _RecordingClient;

    await tester.enterText(find.byType(TextField).at(0), 'Demo bug');
    await tester.enterText(find.byType(TextField).at(1), 'demo steps');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('Read-only in demo mode'), findsOneWidget);
    expect(client.postCount, 0);
    expect(find.text('My reports (2)'), findsOneWidget);
  });

  testWidgets('out of demo mode the server is still called', (tester) async {
    final client = await pumpPage(tester, demo: false) as _RecordingClient;
    expect(client.getCount, greaterThan(0));
  });

  testWidgets('out of demo mode a 401 still surfaces the error card',
      (tester) async {
    await pumpPage(tester, demo: false, throwOnGet: true);
    expect(find.text('SyncException(401): Signed out'), findsOneWidget);
  });
}
