import 'package:a_fish_in_sea/feedback/view/feedback_page.dart';
import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Feedback tab end-to-end: a newcomer registers, opens Feedback from the
/// drawer, sees an empty state (no "Signed out" error card), files a bug,
/// and sees it under My reports.
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/feedback_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409. Leaves one junk
/// account plus one junk bug report per run on the dev server.
void main() {
  patrolTest('feedback tab files a bug without error cards', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-feedback-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);

    await $(Icons.menu).tap();
    await $.pumpAndSettle();
    await $('Feedback').tap();
    await $.pumpAndSettle();

    expect(find.byType(FeedbackPage), findsOneWidget);
    expect($('Signed out').visible, false);
    expect($('My reports (0)').visible, true);

    await $(TextField).at(0).enterText('Patrol demo bug $stamp');
    await $(TextField).at(1).enterText('filed by the headless patrol run');
    await $('Submit bug (auto-fixed)').tap();
    await $.pumpAndSettle();

    await $('My reports (1)').scrollTo();
    expect($('My reports (1)').visible, true);
  });
}
