import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:a_fish_in_sea/sync/view/auth/auth_page.dart';
import 'package:flutter/gestures.dart';
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
  // The sign-in scene carries a looping fish, so pumpAndSettle never
  // settles; two frames are enough for autofocus to be requested.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
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

  testWidgets(
    'password tap accepts input on the focused connection and masks it',
    (tester) async {
      await pumpAuthPage(tester);
      await tester.enterText(find.byType(TextField).first, 'a@example.com');
      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      expect(hasFocus(tester, 1), isTrue);

      // Unlike tester.enterText, this does not focus the field for the test.
      // Input must reach the connection opened by the tap (refs #292).
      const password = 'password123';
      tester.testTextInput.enterText(password);
      await tester.pump(const Duration(seconds: 2));

      final editable = tester.widget<EditableText>(
        find.byType(EditableText).last,
      );
      expect(editable.controller.text, password);
      expect(editable.obscureText, isTrue);
      final rendered = tester
          .state<EditableTextState>(find.byType(EditableText).last)
          .renderEditable;
      expect(
        rendered.text!.toPlainText(),
        editable.obscuringCharacter * password.length,
      );
      expect(find.text('a@example.com'), findsOneWidget);
    },
  );

  testWidgets('tapping email accepts typing', (tester) async {
    await pumpAuthPage(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'a@example.com');
    await tester.pump();
    expect(find.text('a@example.com'), findsOneWidget);
  });

  testWidgets('first and repeated mouse clicks focus Password', (
    tester,
  ) async {
    // Match the reported desktop viewport, including the scrollable card.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpAuthPage(tester);
    final email = find.byType(TextField).first;
    final password = find.byType(TextField).last;
    final box = tester.getRect(password);

    for (final point in [
      tester.getCenter(find.byIcon(Icons.lock_outline)),
      box.center,
      Offset(box.right - 10, box.center.dy),
    ]) {
      // Exercise both directions without enterText forcing either field's
      // focus: browser typing must follow the most recent click (refs #299).
      await tester.tap(email, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(hasFocus(tester, 0), isTrue);
      tester.testTextInput.enterText('newcomer@example.com');
      await tester.pump();
      // Repeat the walk's two clicks (refs #304), without enterText or
      // requestFocus on Password hiding a broken focus transition.
      for (var click = 0; click < 2; click++) {
        await tester.tapAt(point, kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(hasFocus(tester, 1), isTrue);
        expect(hasFocus(tester, 0), isFalse);
        expect(tester.takeException(), isNull);
      }
      tester.testTextInput.enterText('password123');
      await tester.pump(const Duration(seconds: 2));
      final editable = tester.widget<EditableText>(
        find.byType(EditableText).last,
      );
      expect(editable.controller.text, 'password123');
      expect(editable.obscureText, isTrue);
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText).last)
            .renderEditable
            .text!
            .toPlainText(),
        editable.obscuringCharacter * 'password123'.length,
      );
      expect(
        tester.widget<TextField>(email).controller!.text,
        'newcomer@example.com',
      );
      expect(tester.takeException(), isNull);
    }
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
