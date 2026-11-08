import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

import '../test/planner/dst_drag_scenario.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('DST sideways drops keep 9 AM in Day and Week', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    // The autofocus cursor keeps scheduling frames on web: wait for the
    // controls instead of waiting for the sign-in screen to stop animating.
    await $.pumpWidget(const MyApp());
    await $(TextField).at(0).waitUntilVisible();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await $(TextField)
        .at(0)
        .enterText(
          'patrol-dst-$stamp@example.com',
          settlePolicy: SettlePolicy.noSettle,
        );
    await $(
      TextField,
    ).at(1).enterText('patrol-pass-1', settlePolicy: SettlePolicy.noSettle);
    FocusManager.instance.primaryFocus?.unfocus();
    await $('Create account').tap(settlePolicy: SettlePolicy.noSettle);
    await $(HomePage).waitUntilVisible(timeout: const Duration(seconds: 30));
    await $.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    await $(Icons.menu).tap();
    await $('Calendar').tap();
    await $.pumpAndSettle();
    for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
      for (final view in ['Day', 'Week']) {
        await verifyDstCalendarDrag($.tester, day, view: view);
      }
    }
  });
}
