import 'package:a_fish_in_sea/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Fitness settings flow: a newcomer registers, opens Settings, and sees
/// the Garmin connect card added for issue #30.
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/fitness_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409.
void main() {
  patrolTest('settings shows the fitness watches card', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());
    expect($('Sign in to sync').visible, true);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-fitness-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    // Open the drawer and go to Settings.
    await $(Icons.menu).tap();
    await $.pumpAndSettle();
    await $('Settings').tap();
    await $.pumpAndSettle();

    // The card sits at the bottom of the settings ListView, which builds
    // lazily — scroll it into view before asserting.
    await $.tester.scrollUntilVisible(
      find.text('Fitness watches'),
      500,
    );
    await $.pumpAndSettle();
    expect($('Fitness watches').visible, true);
    expect($('Garmin (first provider)').visible, true);

    await $('How to connect').tap();
    await $.pumpAndSettle();
    expect($('Connect Garmin').visible, true);
    await $('Close').tap();
    await $.pumpAndSettle();
    expect($('Connect Garmin').visible, false);
  });
}
