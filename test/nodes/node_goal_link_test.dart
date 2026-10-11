import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node goal(String id, {List<String> parents = const []}) => Node(
      id: id,
      title: id,
      parentIds: parents,
      createdAt: DateTime(2026, 9, 1),
    );

PlannerEvent event(
  String id, {
  bool isTask = true,
  String recurrenceRule = '',
  String? seriesId,
  String? feedId,
  String? sourceUid,
}) =>
    PlannerEvent(
      id: id,
      subject: 'Event $id',
      start: DateTime(2026, 9, 12, 9),
      end: DateTime(2026, 9, 12, 10),
      recurrenceRule: recurrenceRule,
      seriesId: seriesId,
      feedId: feedId,
      sourceUid: sourceUid,
      isTask: isTask,
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

  group('assignEventToGoal', () {
    test('personal task parents its backing node under the goal', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event('evt:1'));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'evt:1',
        'goal',
      );
      expect(result.error, isNull);
      expect(result.assigned, 1);
      final backing = NodeEventLink.backingNodeFor(nodes, calendar, 'evt:1');
      expect(backing, isNotNull);
      expect(backing!.parentIds, contains('goal'));
      expect(calendar.byId('evt:1')?.isTask, isTrue);
    });

    test('non-task event is marked as a task first', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event('evt:plain', isTask: false));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'evt:plain',
        'goal',
      );
      expect(result.error, isNull);
      expect(result.assigned, 1);
      expect(calendar.byId('evt:plain')?.isTask, isTrue);
      expect(
        NodeEventLink.backingNodeFor(nodes, calendar, 'evt:plain')?.parentIds,
        contains('goal'),
      );
    });

    test('feed event gets a homework shadow parented to the goal', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event(
        'gcal:f:abc',
        isTask: false,
        feedId: 'f',
        sourceUid: 'abc',
      ));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:abc',
        'goal',
      );
      expect(result.error, isNull);
      expect(result.assigned, 1);
      expect(nodes.byId('gcal:f:abc')?.parentIds, contains('goal'));
    });

    test('re-assign is a no-op success', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event('evt:1'));
      expect(
        NodeEventLink.assignEventToGoal(calendar, nodes, 'evt:1', 'goal')
            .assigned,
        1,
      );
      final again =
          NodeEventLink.assignEventToGoal(calendar, nodes, 'evt:1', 'goal');
      expect(again.error, isNull);
      expect(again.assigned, 0);
    });

    test('series assigns every occurrence', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event(
        'gcal:f:m',
        recurrenceRule: 'FREQ=WEEKLY',
        feedId: 'f',
        sourceUid: 'master-1',
      ));
      calendar.addEvent(event(
        'gcal:f:i1',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260915T090000',
      ));
      calendar.addEvent(event(
        'gcal:f:i2',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260922T090000',
      ));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:i1',
        'goal',
      );
      expect(result.error, isNull);
      expect(result.assigned, 3);
      for (final id in ['gcal:f:m', 'gcal:f:i1', 'gcal:f:i2']) {
        expect(nodes.byId(id)?.parentIds, contains('goal'));
      }
    });

    test('cycle is rejected', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('child')), isNull);
      expect(nodes.addNode(goal('goal', parents: ['child'])), isNull);
      calendar.addEvent(event('evt:1'));
      // Backing node for evt:1 is fresh; parenting goal under it is fine,
      // but parenting the backing under its own descendant must fail.
      // First assign the event to child, then try to assign a task backed
      // by `goal`... simpler: assign child-backed event under goal's
      // descendant.
      expect(
        NodeEventLink.assignEventToGoal(calendar, nodes, 'evt:1', 'child')
            .error,
        isNull,
      );
      // Now make `child` a parent-chain trap: goal descends from child, so
      // assigning anything parented under goal... craft directly:
      final backing =
          NodeEventLink.backingNodeFor(nodes, calendar, 'evt:1')!;
      // backing is under child; assigning backing under goal is fine
      // (goal also under child — DAG, no cycle). Force a real cycle by
      // trying to parent `child`'s own node under its descendant `goal`
      // via the node-level helper.
      expect(
        NodeEventLink.assignNodeToGoal(nodes, 'child', 'goal'),
        isNotNull,
        reason: 'child -> goal would cycle (goal already under child)',
      );
      expect(backing.parentIds, isNot(contains('goal')));
    });

    test('generated instances cannot be goals', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('tmpl')), isNull);
      expect(
        nodes.addNode(Node(
          id: 'inst',
          title: 'inst',
          parentIds: ['tmpl'],
          createdAt: DateTime(2026, 9, 1),
          instanceOfId: 'tmpl',
          schedule: ScheduleFacet(due: DateTime(2026, 9, 12)),
        )),
        isNull,
      );
      calendar.addEvent(event('evt:1'));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'evt:1',
        'inst',
      );
      expect(result.error, isNotNull);
      expect(result.assigned, 0);
    });

    test('missing event and goal report errors', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      expect(
        NodeEventLink.assignEventToGoal(calendar, nodes, 'nope', 'goal').error,
        isNotNull,
      );
      calendar.addEvent(event('evt:1'));
      expect(
        NodeEventLink.assignEventToGoal(calendar, nodes, 'evt:1', 'nope')
            .error,
        isNotNull,
      );
    });
  });

  group('assignNodeToGoal / unassignNodeFromGoal', () {
    test('round-trip parents and unparents', () {
      final nodes = NodeCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      expect(nodes.addNode(goal('task')), isNull);
      expect(NodeEventLink.assignNodeToGoal(nodes, 'task', 'goal'), isNull);
      expect(nodes.byId('task')?.parentIds, contains('goal'));
      expect(NodeEventLink.unassignNodeFromGoal(nodes, 'task', 'goal'), isNull);
      expect(nodes.byId('task')?.parentIds, isNot(contains('goal')));
    });
  });
}
