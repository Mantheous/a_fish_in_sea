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
  DateTime? start,
}) =>
    PlannerEvent(
      id: id,
      subject: 'Event $id',
      start: start ?? DateTime(2026, 9, 12, 9),
      end: (start ?? DateTime(2026, 9, 12, 9))
          .add(const Duration(hours: 1)),
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
        // Before every occurrence: the whole series is future.
        now: DateTime(2026, 9, 1),
      );
      expect(result.error, isNull);
      expect(result.assigned, 3);
      for (final id in ['gcal:f:m', 'gcal:f:i1', 'gcal:f:i2']) {
        expect(nodes.byId(id)?.parentIds, contains('goal'));
      }
    });

    test('series assign skips past occurrences', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      final past = DateTime(2026, 9, 10, 9);
      final futureSeed = DateTime(2026, 9, 20, 9);
      final futureLater = DateTime(2026, 9, 27, 9);
      calendar.addEvent(event(
        'gcal:f:m',
        recurrenceRule: 'FREQ=WEEKLY',
        feedId: 'f',
        sourceUid: 'master-1',
        isTask: false,
        start: past,
      ));
      calendar.addEvent(event(
        'gcal:f:past',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260910T090000',
        isTask: false,
        start: past,
      ));
      calendar.addEvent(event(
        'gcal:f:seed',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260920T090000',
        isTask: false,
        start: futureSeed,
      ));
      calendar.addEvent(event(
        'gcal:f:later',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260927T090000',
        isTask: false,
        start: futureLater,
      ));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:seed',
        'goal',
        now: DateTime(2026, 9, 12),
      );
      expect(result.error, isNull);
      // Seed + later future occurrence only: past master/instance untouched.
      expect(result.assigned, 2);
      expect(calendar.byId('gcal:f:seed')?.isTask, isTrue);
      expect(calendar.byId('gcal:f:later')?.isTask, isTrue);
      expect(calendar.byId('gcal:f:past')?.isTask, isFalse);
      expect(calendar.byId('gcal:f:m')?.isTask, isFalse);
      expect(nodes.byId('gcal:f:seed')?.parentIds, contains('goal'));
      expect(nodes.byId('gcal:f:later')?.parentIds, contains('goal'));
      expect(nodes.byId('gcal:f:past'), isNull);
    });

    test('past seed still assigns itself plus future occurrences', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      final past = DateTime(2026, 9, 10, 9);
      final future = DateTime(2026, 9, 20, 9);
      calendar.addEvent(event(
        'gcal:f:past',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260910T090000',
        isTask: false,
        start: past,
      ));
      calendar.addEvent(event(
        'gcal:f:future',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260920T090000',
        isTask: false,
        start: future,
      ));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:past',
        'goal',
        now: DateTime(2026, 9, 12),
      );
      expect(result.error, isNull);
      expect(result.assigned, 2);
      expect(calendar.byId('gcal:f:past')?.isTask, isTrue);
      expect(calendar.byId('gcal:f:future')?.isTask, isTrue);
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

  group('futureSeriesMembers', () {
    test('non-series event targets itself alone', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(event('evt:1', isTask: false));
      final seed = calendar.byId('evt:1')!;
      expect(
        NodeEventLink.futureSeriesMembers(
          calendar,
          seed,
          now: DateTime(2026, 9, 12),
        ).map((e) => e.id),
        ['evt:1'],
      );
      expect(nodes.state, isEmpty);
    });

    test('isFutureOccurrence treats today as future', () {
      final now = DateTime(2026, 9, 12, 15);
      final todayMorning = event(
        'today',
        isTask: false,
        start: DateTime(2026, 9, 12, 9),
      );
      final yesterday = event(
        'yesterday',
        isTask: false,
        start: DateTime(2026, 9, 11, 9),
      );
      final tomorrow = event(
        'tomorrow',
        isTask: false,
        start: DateTime(2026, 9, 13, 9),
      );
      expect(NodeEventLink.isFutureOccurrence(todayMorning, now), isTrue);
      expect(NodeEventLink.isFutureOccurrence(tomorrow, now), isTrue);
      expect(NodeEventLink.isFutureOccurrence(yesterday, now), isFalse);
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

  group('assignEventToGoal includeSeries=false', () {
    test('single occurrence only parents the seed', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event(
        'gcal:f:m',
        recurrenceRule: 'FREQ=WEEKLY',
        feedId: 'f',
        sourceUid: 'master-1',
        start: DateTime(2026, 9, 20, 9),
      ));
      calendar.addEvent(event(
        'gcal:f:i1',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260920T090000',
        isTask: false,
        start: DateTime(2026, 9, 20, 9),
      ));
      calendar.addEvent(event(
        'gcal:f:i2',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260927T090000',
        isTask: false,
        start: DateTime(2026, 9, 27, 9),
      ));
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:i1',
        'goal',
        includeSeries: false,
        now: DateTime(2026, 9, 12),
      );
      expect(result.error, isNull);
      expect(result.assigned, 1);
      expect(nodes.byId('gcal:f:i1')?.parentIds, contains('goal'));
      expect(nodes.byId('gcal:f:i2'), isNull);
    });
  });

  group('unassignEventFromGoal', () {
    test('single occurrence removes only the seed', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event(
        'gcal:f:i1',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260920T090000',
        start: DateTime(2026, 9, 20, 9),
      ));
      calendar.addEvent(event(
        'gcal:f:i2',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260927T090000',
        start: DateTime(2026, 9, 27, 9),
      ));
      expect(
        NodeEventLink.assignEventToGoal(
          calendar,
          nodes,
          'gcal:f:i1',
          'goal',
          now: DateTime(2026, 9, 12),
        ).assigned,
        2,
      );
      final removed = NodeEventLink.unassignEventFromGoal(
        calendar,
        nodes,
        'gcal:f:i1',
        'goal',
        includeSeries: false,
      );
      expect(removed.error, isNull);
      expect(removed.removed, 1);
      expect(nodes.byId('gcal:f:i1')?.parentIds, isNot(contains('goal')));
      expect(nodes.byId('gcal:f:i2')?.parentIds, contains('goal'));
    });

    test('series removes this and future instances', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event(
        'gcal:f:i1',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260920T090000',
        start: DateTime(2026, 9, 20, 9),
      ));
      calendar.addEvent(event(
        'gcal:f:i2',
        seriesId: 'master-1',
        feedId: 'f',
        sourceUid: 'master-1_20260927T090000',
        start: DateTime(2026, 9, 27, 9),
      ));
      expect(
        NodeEventLink.assignEventToGoal(
          calendar,
          nodes,
          'gcal:f:i1',
          'goal',
          now: DateTime(2026, 9, 12),
        ).assigned,
        2,
      );
      final removed = NodeEventLink.unassignEventFromGoal(
        calendar,
        nodes,
        'gcal:f:i1',
        'goal',
        includeSeries: true,
        now: DateTime(2026, 9, 12),
      );
      expect(removed.error, isNull);
      expect(removed.removed, 2);
      expect(nodes.byId('gcal:f:i1')?.parentIds, isNot(contains('goal')));
      expect(nodes.byId('gcal:f:i2')?.parentIds, isNot(contains('goal')));
    });

    test('already-removed is a no-op success', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goal('goal')), isNull);
      calendar.addEvent(event('evt:1'));
      final removed = NodeEventLink.unassignEventFromGoal(
        calendar,
        nodes,
        'evt:1',
        'goal',
      );
      expect(removed.error, isNull);
      expect(removed.removed, 0);
    });
  });
}
