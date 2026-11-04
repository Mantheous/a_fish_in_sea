import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/view/auth/auth_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Seed behavioral test: a newcomer registers and lands in the planner.
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/auth_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409. Leaves one junk
/// account per run on the dev server (same as the UX walker).
void main() {
  patrolTest('auth errors are visible and good credentials open planner', ($) async {
    // The sign-in fish loops forever; let settle wait for requests instead.
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown($.tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());
    expect($('Sign in to sync').visible, true);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    // Tap the visible fields first (refs #17): typing must land in the
    // tapped field, not nowhere.
    await $(TextField).at(0).tap();
    final email = 'patrol-auth-$stamp@example.com';
    await $(TextField).at(0).enterText(email);
    await _tapAndTypePassword($, 'patrol-pass-1');
    await _tapAuthButton($, 'Create account');
    await $(HomePage).waitUntilVisible();
    await $.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(AuthPage), findsNothing);

    final context = $.tester.element(find.byType(HomePage));
    context.read<AuthCubit>().logout();
    await $.pumpAndSettle();
    await $(TextField).at(0).enterText(email);
    await $(TextField).at(1).enterText('wrong-password');
    await _tapAuthButton($, 'Sign in');
    await $('Invalid credentials').waitUntilVisible();
    expect(find.byType(HomePage), findsNothing);

    // A failed reply must leave both actions usable, including a second
    // sign-in attempt with the same credentials (refs #306).
    expect(
      $.tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Create account'),
          )
          .onPressed,
      isNotNull,
    );
    await _tapAuthButton($, 'Sign in');
    await $('Invalid credentials').waitUntilVisible();
    expect(
      $.tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'))
          .onPressed,
      isNotNull,
    );

    // Registration errors must be visible on the same card as well.
    await _tapAuthButton($, 'Create account');
    await $('Email already registered').waitUntilVisible();
    // Move off Password so the next tap opens a fresh input connection.
    await $(TextField).at(0).tap();
    await _tapAndTypePassword($, 'patrol-pass-1');
    expect($.tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'patrol-pass-1');
    await _tapAuthButton($, 'Sign in');
    await $(HomePage).waitUntilVisible();
    await $.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(AuthPage), findsNothing);
  });
}

Future<void> _tapAuthButton(PatrolIntegrationTester $, String label) async {
  if (!kIsWeb) {
    await $(label).tap();
    return;
  }
  // Exercise the browser's actual down/up sequence (refs #301), rather
  // than WidgetTester's gesture injection. The walk sent pointerup with
  // buttons: 1, which Flutter treats as a move with the button still held.
  final semantics = $.tester.ensureSemantics();
  try {
    await $.pump();
    await $.platform.web.tap(WebSelector(role: 'button', text: label));
    await $.pumpAndSettle();
    expect($.tester.takeException(), isNull);
  } finally {
    semantics.dispose();
  }
}

Future<void> _tapAndTypePassword(PatrolIntegrationTester $, String value) async {
  final email = $.tester.widget<TextField>(find.byType(TextField).first);
  final emailBeforeTyping = email.controller!.text;
  // Expose the fields for a real browser click (refs #297). Dispose before
  // Patrol checks for leaked handles at the end of the test body.
  final semantics = $.tester.ensureSemantics();
  try {
    await $.pump();
    // Check both the initial click and the retry reported in #304. Use real
    // browser events: MouseEvent('pointerdown') lacks required pointer data.
    for (var click = 0; click < 2; click++) {
      if (kIsWeb) {
        await $.platform.web.tap(WebSelector(label: 'Password (8+ characters)'));
      } else {
        await $(TextField).at(1).tap();
      }
      await $.pump();
      final field = $.tester.widget<EditableText>(find.byType(EditableText).last);
      expect(field.focusNode.hasFocus, isTrue);
      expect(email.focusNode!.hasFocus, isFalse);
      expect(email.controller!.text, emailBeforeTyping);
      expect($.tester.takeException(), isNull);
    }
    final editable = $.tester.widget<EditableText>(find.byType(EditableText).last);
    expect(editable.focusNode.hasFocus, isTrue);
    if (kIsWeb) {
      // Browser keystrokes must reach the connection opened by the tap. Using
      // enterText here would focus/attach a test connection and hide regressions.
      await $.platform.web.pressKeyCombo(keys: ['ControlOrMeta', 'A']);
      for (final character in value.split('')) {
        await $.platform.web.pressKey(key: character);
      }
    } else {
      await $(TextField).at(1).enterText(value);
    }
    await $.pump();
    expect(editable.controller.text, value);
    expect(editable.obscureText, isTrue);
    // The walk's malformed synthetic pointer events left focus on Email.
    // Real browser clicks must keep password keystrokes out of it (refs #299).
    expect(email.focusNode!.hasFocus, isFalse);
    expect(email.controller!.text, emailBeforeTyping);
    expect($.tester.takeException(), isNull);
  } finally {
    semantics.dispose();
  }
}
