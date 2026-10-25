import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_recording_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Widget _app(NodeCubit nodes, CalendarCubit calendar) => MultiBlocProvider(
  providers: [
    BlocProvider.value(value: nodes),
    BlocProvider.value(value: calendar),
  ],
  child: MaterialApp(
    home: Scaffold(body: RecordingBannerSlot(onOpen: (_) {})),
  ),
);

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('shows a recording started on a goal node', (tester) async {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    nodes.addNode(
      Node(id: 'n1', title: 'Buy groceries', createdAt: DateTime(2026, 10, 25)),
    );
    nodes.startTracking('n1');

    await tester.pumpWidget(_app(nodes, calendar));
    await tester.pump();

    expect(find.textContaining('Recording ·'), findsOneWidget);
    expect(find.text('Buy groceries'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();

    expect(nodes.byId('n1')?.isTracking, isFalse);
    expect(find.textContaining('Recording ·'), findsNothing);
  });

  testWidgets('shows a recording owned by a plain calendar event', (
    tester,
  ) async {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    calendar.addEvent(
      PlannerEvent(
        id: 'e1',
        subject: 'Deep work',
        start: DateTime(2026, 10, 25, 9),
        end: DateTime(2026, 10, 25, 10),
      ),
    );
    calendar.startTracking('e1');

    await tester.pumpWidget(_app(nodes, calendar));
    await tester.pump();

    expect(find.textContaining('Recording ·'), findsOneWidget);
    expect(find.text('Deep work'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();

    expect(calendar.byId('e1')?.isTracking, isFalse);
  });

  testWidgets('collapses when nothing is recording', (tester) async {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();

    await tester.pumpWidget(_app(nodes, calendar));
    await tester.pump();

    expect(find.text('Stop'), findsNothing);
  });
}
