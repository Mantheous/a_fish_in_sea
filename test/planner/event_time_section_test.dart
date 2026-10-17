import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_time_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

PlannerEvent plain(String id) {
  final now = DateTime(2026, 10, 17, 9);
  return PlannerEvent(
    id: id,
    subject: 'Plain $id',
    start: now,
    end: now.add(const Duration(hours: 1)),
    isTask: false,
  );
}

Future<void> pumpSection(
  WidgetTester tester,
  NodeCubit nodes,
  CalendarCubit calendar,
  PlannerEvent event,
) async {
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<NodeCubit>.value(value: nodes),
        BlocProvider<CalendarCubit>.value(value: calendar),
      ],
      child: MaterialApp(
        home: Scaffold(body: TimeReportSection(event: event)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('starting a plain event stops the running node timer',
      (tester) async {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    addTearDown(() async {
      await nodes.close();
      await calendar.close();
    });
    nodes.addNode(
        Node(id: 'n1', title: 'task', createdAt: DateTime(2026, 10, 1)));
    final event = plain('plain');
    calendar.addEvent(event);
    NodeEventLink.startNodeTracking(nodes, calendar, 'n1');
    expect(nodes.byId('n1')?.isTracking, isTrue);

    await pumpSection(tester, nodes, calendar, event);
    await tester.tap(find.text('Start'));
    await tester.pump(const Duration(milliseconds: 200));

    // Single active timer: the event records, the node saved its interval.
    expect(calendar.byId('plain')?.isTracking, isTrue);
    expect(nodes.byId('n1')?.isTracking, isFalse);
    expect(nodes.byId('n1')?.hasReported, isTrue);
  });

  testWidgets('stopping a plain event saves its reported interval',
      (tester) async {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    addTearDown(() async {
      await nodes.close();
      await calendar.close();
    });
    final event = plain('plain');
    calendar.addEvent(event);
    NodeEventLink.startEventTracking(nodes, calendar, 'plain');
    expect(calendar.byId('plain')?.isTracking, isTrue);

    await pumpSection(tester, nodes, calendar, event);
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(milliseconds: 200));

    final done = calendar.byId('plain')!;
    expect(done.isTracking, isFalse);
    expect(done.hasReported, isTrue);
  });

  test('starting a plain event via the link stops a running node (unit)',
      () {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    addTearDown(() async {
      await nodes.close();
      await calendar.close();
    });
    nodes.addNode(
        Node(id: 'n1', title: 'task', createdAt: DateTime(2026, 10, 1)));
    calendar.addEvent(plain('plain'));
    NodeEventLink.startNodeTracking(nodes, calendar, 'n1',
        now: DateTime(2026, 10, 17, 9, 5));
    NodeEventLink.startEventTracking(nodes, calendar, 'plain',
        now: DateTime(2026, 10, 17, 9, 10));
    expect(calendar.byId('plain')?.isTracking, isTrue);
    expect(nodes.byId('n1')?.isTracking, isFalse);
    expect(nodes.byId('n1')?.hasReported, isTrue);
  });
}
