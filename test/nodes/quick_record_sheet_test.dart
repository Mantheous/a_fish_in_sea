import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/view/quick_record_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required NodeCubit nodes,
  required CalendarCubit calendar,
}) async {
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<NodeCubit>.value(value: nodes),
        BlocProvider<CalendarCubit>.value(value: calendar),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQuickRecordSheet(context),
              child: const Text('open quick record'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late NodeCubit nodes;
  late CalendarCubit calendar;

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
    calendar = CalendarCubit();
  });

  tearDown(() async {
    await nodes.close();
    await calendar.close();
  });

  testWidgets('naming a task starts its recording right away', (tester) async {
    await _pumpLauncher(tester, nodes: nodes, calendar: calendar);
    await tester.tap(find.text('open quick record'));
    await tester.pumpAndSettle();

    expect(find.text('Record something'), findsOneWidget);
    expect(find.text('Start recording'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Lunch with Sam');
    await tester.tap(find.text('Start recording'));
    await tester.pumpAndSettle();

    expect(find.text('Record something'), findsNothing);
    expect(nodes.state, hasLength(1));
    final node = nodes.state.single;
    expect(node.title, 'Lunch with Sam');
    expect(node.isTask, isTrue);
    expect(node.isTracking, isTrue);
    expect(node.parentIds, isEmpty);
  });

  testWidgets('submitting an empty name keeps the sheet open', (tester) async {
    await _pumpLauncher(tester, nodes: nodes, calendar: calendar);
    await tester.tap(find.text('open quick record'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start recording'));
    await tester.pump();

    expect(find.text('Name it first.'), findsOneWidget);
    expect(find.text('Record something'), findsOneWidget);
    expect(nodes.state, isEmpty);
  });
}
