import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:flutter/material.dart';
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
  patrolTest('register flows into the planner', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());
    expect($('Sign in to sync').visible, true);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-auth-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
  });
}
