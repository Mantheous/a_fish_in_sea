import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:a_fish_in_sea/sync/view/auth_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockSyncEngine extends Mock implements SyncEngine {}

/// Never touches the network; focus tests never submit successfully.
class _StubClient extends SyncClient {
  _StubClient()
      : super(
          serverBase: () => 'http://localhost:8000',
          accessToken: () => null,
          refreshAccessToken: () async => null,
        );
}

Future<void> pumpAuthPage(WidgetTester tester) async {
  final engine = MockSyncEngine();
  when(() => engine.syncNow()).thenAnswer((_) async {});
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthCubit>(
            create: (_) => AuthCubit(client: () => _StubClient())),
        BlocProvider<SyncMetaCubit>(create: (_) => SyncMetaCubit()),
      ],
      child: RepositoryProvider<SyncEngine>.value(
        value: engine,
        child: const MaterialApp(home: AuthPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool hasFocus(WidgetTester tester, int index) {
  final editable =
      tester.widget<EditableText>(find.byType(EditableText).at(index));
  return editable.focusNode.hasFocus;
}

/// Regression coverage for the first-run sign-in focus finding (refs #17):
/// tapping a visible field must focus it, the Email field is ready on
/// arrival, and the keyboard Next/Done actions walk the form.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('email field is focused on first run', (tester) async {
    await pumpAuthPage(tester);
    expect(hasFocus(tester, 0), isTrue);
  });

  testWidgets('tapping the password field focuses it', (tester) async {
    await pumpAuthPage(tester);
    await tester.tap(find.byType(TextField).at(1));
    await tester.pump();
    expect(hasFocus(tester, 1), isTrue);
  });

  testWidgets('tapping email accepts typing', (tester) async {
    await pumpAuthPage(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'a@example.com');
    await tester.pump();
    expect(find.text('a@example.com'), findsOneWidget);
  });

  testWidgets('Next moves from email to password, Done validates',
      (tester) async {
    await pumpAuthPage(tester);
    await tester.enterText(find.byType(TextField).first, 'a@example.com');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(hasFocus(tester, 1), isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // Password is empty, so the form validates instead of calling sync.
    expect(find.text('Enter an email and password.'), findsOneWidget);
  });
}
