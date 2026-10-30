import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('a recording made before Task promotion can still be resized', (
    $,
  ) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidgetAndSettle(const MyApp());
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-promoted-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    await $(Icons.menu).tap();
    await $('Calendar').tap();
    await $.pumpAndSettle();

    final context = $.tester.element(find.byType(CalendarPage));
    final calendar = context.read<CalendarCubit>();
    final nodes = context.read<NodeCubit>();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9);
    final end = start.add(const Duration(minutes: 45));
    // Reproduce a stopped recording predating the task, using real actions.
    calendar.addEvent(
      PlannerEvent(
        id: 'promoted',
        subject: 'Recorded before Task',
        start: start,
        end: end,
      ),
    );
    calendar.startTracking('promoted', now: start);
    calendar.stopTracking('promoted', now: end);
    NodeEventLink.markEventAsNode(calendar, nodes, 'promoted');
    expect(
      NodeEventLink.backingNodeFor(
        nodes,
        calendar,
        'promoted',
      )!.recordedSessions,
      isEmpty,
    );
    await $.pumpAndSettle();
    await $('Plan + Report').tap();
    await $.pumpAndSettle();
    final chip = find.byKey(
      const ValueKey('report-chip:report:timer:promoted'),
    );
    await $.tester.tap(chip);
    await $.pumpAndSettle();
    final before = $.tester.getRect(chip);
    final handle = find.byWidgetPredicate(
      (w) =>
          w is Semantics && w.properties.label == 'Drag to adjust report end',
    );
    await $.tester.drag(handle, const Offset(0, 40));
    await $.pumpAndSettle();
    final saved = calendar.byId('promoted')!.recordedSessions.single;
    expect(saved.start, start);
    expect(saved.end.isAfter(end), isTrue);
    expect($.tester.getRect(chip).height, greaterThan(before.height));
    expect(find.textContaining('Reported time updated'), findsOneWidget);
  });
}
