import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

Node _openNode(String id, String title) => Node(
      id: id,
      title: title,
      createdAt: DateTime(2026),
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

  group('NodeCubit bulk writes', () {
    test('setDoneMany marks many done in one emit', () {
      final nodes = NodeCubit();
      addTearDown(nodes.close);
      nodes.addNode(_openNode('a', 'A'));
      nodes.addNode(_openNode('b', 'B'));
      nodes.addNode(_openNode('c', 'C'));

      final changed =
          nodes.setDoneMany({'a', 'b'}, done: true, now: DateTime(2026));
      expect(changed, 2);
      expect(nodes.byId('a')!.isDone, isTrue);
      expect(nodes.byId('b')!.isDone, isTrue);
      expect(nodes.byId('c')!.isDone, isFalse);

      // Already-done nodes are skipped and reported as unchanged.
      expect(nodes.setDoneMany({'a', 'b'}, done: true), 0);

      // Reopening clears completion.
      expect(nodes.setDoneMany({'a'}, done: false), 1);
      expect(nodes.byId('a')!.isOpen, isTrue);
      expect(nodes.byId('a')!.completedAt, isNull);

      expect(nodes.setDoneMany(const {}, done: true), 0);
    });

    test('deleteNodes removes many at once', () {
      final nodes = NodeCubit();
      addTearDown(nodes.close);
      nodes.addNode(_openNode('a', 'A'));
      nodes.addNode(_openNode('b', 'B'));
      nodes.addNode(_openNode('c', 'C'));

      expect(nodes.deleteNodes({'a', 'b'}), 2);
      expect(nodes.byId('a'), isNull);
      expect(nodes.byId('b'), isNull);
      expect(nodes.byId('c'), isNotNull);
      expect(nodes.deleteNodes(const {'missing'}), 0);
    });
  });

  group('NodeEventLink bulk writes', () {
    test('setNodesDone mirrors completion onto linked events', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      addTearDown(() async {
        await nodes.close();
        await calendar.close();
      });
      final at = DateTime(2026, 5, 1, 9);
      nodes.addNode(Node(
        id: 'node:e1',
        title: 'Linked',
        createdAt: DateTime(2026),
        calendarEventId: 'e1',
      ));
      nodes.addNode(_openNode('plain', 'Plain'));
      calendar.addEvent(PlannerEvent(
        id: 'e1',
        subject: 'Linked',
        start: at,
        end: at.add(const Duration(hours: 1)),
        isTask: true,
        taskId: 'node:e1',
      ));

      final changed = NodeEventLink.setNodesDone(
        nodes,
        calendar,
        {'node:e1', 'plain'},
        done: true,
      );
      expect(changed, 2);
      expect(nodes.byId('node:e1')!.isDone, isTrue);
      expect(nodes.byId('plain')!.isDone, isTrue);
      expect(calendar.byId('e1')!.done, isTrue);
    });

    test('deleteNodesAndUnlink keeps events but clears their task links',
        () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      addTearDown(() async {
        await nodes.close();
        await calendar.close();
      });
      final at = DateTime(2026, 5, 1, 9);
      nodes.addNode(Node(
        id: 'node:e1',
        title: 'Linked',
        createdAt: DateTime(2026),
        calendarEventId: 'e1',
      ));
      calendar.addEvent(PlannerEvent(
        id: 'e1',
        subject: 'Linked',
        start: at,
        end: at.add(const Duration(hours: 1)),
        isTask: true,
        taskId: 'node:e1',
      ));

      expect(
        NodeEventLink.deleteNodesAndUnlink(nodes, calendar, {'node:e1'}),
        1,
      );
      expect(nodes.byId('node:e1'), isNull);
      // Event survives, unlinked — same as the single-delete behaviour.
      expect(calendar.byId('e1'), isNotNull);
      expect(calendar.byId('e1')!.isTask, isFalse);
      expect(calendar.byId('e1')!.taskId, isNull);
    });
  });

  group('TasksPage multi-select', () {
    Future<({NodeCubit nodes, CalendarCubit calendar})> pumpTasks(
      WidgetTester tester, {
      List<Node> seed = const [],
    }) async {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      final navigation = NavigationCubit();
      final drafts = CalendarDraftCubit();
      final feeds = FeedCubit(
        calendarCubit: calendar,
        nodeCubit: nodes,
        icalService: IcalService(),
        googleService: MockGoogleService(),
        proxyBase: () => '',
      );
      for (final n in seed) {
        nodes.addNode(n);
      }
      addTearDown(() async {
        await nodes.close();
        await calendar.close();
        await navigation.close();
        await drafts.close();
        await feeds.close();
      });
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => UndoCubit()),
            BlocProvider.value(value: navigation),
            BlocProvider.value(value: calendar),
            BlocProvider.value(value: drafts),
            BlocProvider.value(value: nodes),
            BlocProvider.value(value: feeds),
          ],
          child: const MaterialApp(home: TasksPage()),
        ),
      );
      await tester.pumpAndSettle();
      return (nodes: nodes, calendar: calendar);
    }

    testWidgets('long-press selects, tap adds, Mark done completes both',
        (tester) async {
      final cubits = await pumpTasks(
        tester,
        seed: [_openNode('a', 'Task A'), _openNode('b', 'Task B')],
      );

      // No selection UI until the user long-presses a task.
      expect(find.text('Select all'), findsNothing);
      expect(find.text('Mark done'), findsNothing);

      await tester.longPress(find.text('Task A'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsWidgets);

      await tester.tap(find.text('Task B'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsWidgets);

      await tester.tap(find.text('Mark done'));
      await tester.pumpAndSettle();
      expect(find.text('2 tasks marked done'), findsOneWidget);
      expect(cubits.nodes.byId('a')!.isDone, isTrue);
      expect(cubits.nodes.byId('b')!.isDone, isTrue);
      // Bulk action exits selection mode.
      expect(find.text('Mark done'), findsNothing);
    });

    testWidgets('Select all header selects the whole visible list',
        (tester) async {
      final cubits = await pumpTasks(
        tester,
        seed: [_openNode('a', 'Task A'), _openNode('b', 'Task B')],
      );

      await tester.longPress(find.text('Task A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsWidgets);

      await tester.tap(find.text('Mark done'));
      await tester.pumpAndSettle();
      expect(cubits.nodes.byId('a')!.isDone, isTrue);
      expect(cubits.nodes.byId('b')!.isDone, isTrue);
    });

    testWidgets('Delete selected removes the bunch with undo', (tester) async {
      final cubits = await pumpTasks(
        tester,
        seed: [_openNode('a', 'Task A'), _openNode('b', 'Task B')],
      );

      await tester.longPress(find.text('Task A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete selected'));
      await tester.pumpAndSettle();
      expect(find.text('1 task deleted'), findsOneWidget);
      expect(cubits.nodes.byId('a'), isNull);
      expect(cubits.nodes.byId('b'), isNotNull);
    });

    testWidgets('close button clears the selection without changes',
        (tester) async {
      final cubits = await pumpTasks(
        tester,
        seed: [_openNode('a', 'Task A')],
      );

      await tester.longPress(find.text('Task A'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsWidgets);

      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();
      expect(find.text('Mark done'), findsNothing);
      expect(find.text('Tasks'), findsOneWidget);
      expect(cubits.nodes.byId('a')!.isOpen, isTrue);
    });
  });
}
