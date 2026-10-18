import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/nodes/service/recurring_goal_coordinator.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/nodes/service/recurring_goal_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late NodeCubit nodes;
  late CalendarCubit calendar;
  final day = DateTime(2027, 2, 10);

  PlannerEvent event(
    String id, {
    String feed = 'personal-calendar',
    int offset = 0,
    bool done = false,
    String series = 'scripture',
  }) => PlannerEvent(
    id: id,
    subject: 'Scripture Study',
    start: day.add(Duration(days: offset, hours: 6)),
    end: day.add(Duration(days: offset, hours: 7)),
    feedId: feed,
    seriesId: series,
    isTask: true,
    done: done,
    completedAt: done ? day.add(const Duration(hours: 7)) : null,
  );

  void seed({bool assigned = true}) {
    nodes.addNode(
      Node(
        id: 'goal',
        title: 'Daily Scripture Study',
        createdAt: day,
        effort: const EffortFacet(targetMinutes: 60),
        recurrence: const NodeRecurrence(frequency: TimeScale.daily),
      ),
    );
    nodes.generateInstances(
      templateId: 'goal',
      from: day,
      horizon: day.add(const Duration(days: 2)),
    );
    calendar.addEvent(event('e1'));
    nodes.ensureNodeForFeedEvent(calendar.byId('e1')!);
    if (assigned) nodes.reparent('e1', ['goal']);
  }

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

  test(
    'assigned calendar series uses one goal occurrence and archives originals',
    () {
      seed();
      final original = nodes.byId('e1')!;
      final occurrence = nodes.instancesOf('goal').first;
      expect(RecurringGoalLink.reconcile(calendar, nodes), 1);
      final linked = nodes.byId(occurrence.id)!;
      expect(nodes.byId('e1'), isNull);
      expect(linked.title, 'Daily Scripture Study');
      expect(linked.instanceOfId, 'goal');
      expect(linked.parentIds, ['goal']);
      expect(linked.sourceEventId, 'e1');
      expect(linked.hasCalendarBlock, isTrue);
      expect(linked.schedule!.start, calendar.byId('e1')!.start);
      expect(linked.calendarLink!.records['e1'], original.toJson());
      expect(linked.calendarLink!.records[occurrence.id], occurrence.toJson());
      expect(calendar.byId('e1')!.taskId, occurrence.id);
      expect(
        NodeEventLink.backingNodeFor(nodes, calendar, 'e1')!.id,
        occurrence.id,
      );
      expect(isGoalNode(linked), isTrue);
      expect(linked.isHomework, isFalse);
      expect(
        nodes.openNodes.where((n) => n.schedule?.due?.day == day.day),
        hasLength(1),
      );
    },
  );

  test('reconciliation is idempotent including differing notes', () {
    seed();
    nodes.updateNode(nodes.byId('e1')!.copyWith(notes: 'Calendar notes'));
    final instance = nodes.instancesOf('goal').first;
    nodes.updateNode(instance.copyWith(notes: 'Goal notes'));
    RecurringGoalLink.reconcile(calendar, nodes);
    final firstNodes = nodes.state;
    final firstEvents = calendar.state;
    expect(RecurringGoalLink.reconcile(calendar, nodes), 0);
    expect(identical(firstNodes, nodes.state), isTrue);
    expect(identical(firstEvents, calendar.state), isTrue);
    expect(nodes.byId(instance.id)!.notes, contains('Calendar notes'));
  });

  test('completion mirrors from either screen on the same occurrence', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes);
    final id = calendar.byId('e1')!.taskId!;
    NodeEventLink.toggleNodeDone(nodes, calendar, id);
    expect(calendar.byId('e1')!.done, isTrue);
    NodeEventLink.toggleEventDone(calendar, nodes, 'e1');
    expect(nodes.byId(id)!.isDone, isFalse);
    expect(RecurringGoalLink.reconcile(calendar, nodes), 0);
  });

  test('existing completion and reported time survive consolidation', () {
    seed();
    final start = day.add(const Duration(hours: 6));
    final end = start.add(const Duration(hours: 1));
    nodes.updateNode(
      nodes
          .byId('e1')!
          .copyWith(
            status: NodeStatus.done,
            completedAt: end,
            actualStart: start,
            actualEnd: end,
          ),
    );
    RecurringGoalLink.reconcile(calendar, nodes);
    final linked = NodeEventLink.backingNodeFor(nodes, calendar, 'e1')!;
    expect(linked.isDone, isTrue);
    expect(linked.actualStart, start);
    expect(linked.actualEnd, end);
    expect(calendar.byId('e1')!.actualEnd, end);
    expect(calendar.byId('e1')!.done, isTrue);
  });

  test('conflicting reports remain separate', () {
    seed();
    final instance = nodes.instancesOf('goal').first;
    nodes.updateNode(
      instance.copyWith(
        actualStart: day,
        actualEnd: day.add(const Duration(hours: 1)),
      ),
    );
    nodes.updateNode(
      nodes
          .byId('e1')!
          .copyWith(
            actualStart: day.add(const Duration(hours: 6)),
            actualEnd: day.add(const Duration(hours: 7)),
          ),
    );
    RecurringGoalLink.reconcile(calendar, nodes);
    expect(nodes.byId('e1'), isNotNull);
    expect(nodes.byId(instance.id)!.calendarLink, isNull);
  });

  test(
    'ambiguous same-day events and unrelated goals never merge by title',
    () {
      seed(assigned: false);
      expect(RecurringGoalLink.reconcile(calendar, nodes), 0);
      expect(nodes.byId('e1'), isNotNull);
      nodes.reparent('e1', ['goal']);
      calendar.addEvent(event('e2'));
      RecurringGoalLink.reconcile(calendar, nodes);
      expect(nodes.byId('e1'), isNotNull);
      expect(nodes.instancesOf('goal').first.calendarLink, isNull);
    },
  );

  test(
    'future feed refresh uses linked identity without recreating shadows',
    () {
      seed();
      RecurringGoalLink.reconcile(calendar, nodes);
      final id = calendar.byId('e1')!.taskId!;
      final feed = Feed(
        id: 'personal-calendar',
        name: 'mantheous',
        url: 'https://example.test/feed.ics',
        kind: FeedKind.google,
      );
      nodes.importFromFeed([calendar.byId('e1')!], feed);
      expect(nodes.byId('e1'), isNull);
      calendar.addEvent(event('next', offset: 1));
      nodes.importFromFeed([calendar.byId('next')!], feed);
      RecurringGoalLink.reconcile(calendar, nodes);
      expect(nodes.byId('next'), isNull);
      expect(calendar.byId('next')!.taskId, isNot(id));
      expect(nodes.nodesForEventId('next'), hasLength(1));
      expect(nodes.nodesForEventId('next').single.instanceOfId, 'goal');
    },
  );

  test('rescheduling follows the event identity across days', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes);
    final id = calendar.byId('e1')!.taskId!;
    final moved = calendar
        .byId('e1')!
        .copyWith(
          start: day.add(const Duration(days: 1, hours: 9)),
          end: day.add(const Duration(days: 1, hours: 10)),
        );
    calendar.updateEvent(moved);
    RecurringGoalLink.reconcile(calendar, nodes);
    expect(calendar.byId('e1')!.taskId, id);
    expect(nodes.byId(id)!.schedule!.start, moved.start);
    expect(nodes.byId(id)!.schedule!.due, moved.start);
  });

  test('matching source UIDs in another calendar do not get linked', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes);
    calendar.addEvent(event('other-calendar', feed: 'unrelated', offset: 1));
    RecurringGoalLink.reconcile(calendar, nodes);
    expect(calendar.byId('other-calendar')!.taskId, isNull);
  });

  test('referenced nodes and multi-parent work are retained', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes, protectedNodeIds: {'e1'});
    expect(nodes.byId('e1'), isNotNull);
    expect(nodes.instancesOf('goal').first.sourceEventId, isNull);
  });

  test('explicit assignment establishes a durable series binding', () {
    seed(assigned: false);
    final result = NodeEventLink.assignEventToGoal(
      calendar,
      nodes,
      'e1',
      'goal',
      now: day,
    );
    expect(result.error, isNull);
    RecurringGoalLink.reconcile(calendar, nodes);
    expect(nodes.byId('e1'), isNull);
    expect(
      NodeEventLink.backingNodeFor(nodes, calendar, 'e1')!.instanceOfId,
      'goal',
    );
  });
  test(
    'unlinking one occurrence keeps history and survives reconciliation',
    () {
      seed();
      RecurringGoalLink.reconcile(calendar, nodes);
      final id = calendar.byId('e1')!.taskId!;
      final result = NodeEventLink.unassignEventFromGoal(
        calendar,
        nodes,
        'e1',
        'goal',
        includeSeries: false,
      );
      expect(result.error, isNull);
      expect(result.removed, 1);
      expect(nodes.byId(id)!.sourceEventId, isNull);
      expect(nodes.byId(id)!.calendarLink!.records, isNotEmpty);
      expect(
        nodes.byId('goal')!.calendarLink!.excludedEventIds,
        contains('e1'),
      );
      RecurringGoalLink.reconcile(calendar, nodes);
      expect(calendar.byId('e1')!.taskId, isNot(id));
      expect(nodes.byId(id)!.sourceEventId, isNull);
      expect(nodes.byId('e1')!.parentIds, isEmpty);
      final assigned = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'e1',
        'goal',
        now: day,
      );
      expect(assigned.error, isNull);
      RecurringGoalLink.reconcile(calendar, nodes);
      expect(calendar.byId('e1')!.taskId, id);
    },
  );

  test('unmark and calendar deletion retain the completed goal record', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes);
    final id = calendar.byId('e1')!.taskId!;
    NodeEventLink.toggleNodeDone(nodes, calendar, id);
    NodeEventLink.unmarkEventAsNode(calendar, nodes, 'e1');
    expect(nodes.byId(id)!.isDone, isTrue);
    expect(nodes.byId(id)!.sourceEventId, isNull);
    expect(nodes.byId(id)!.hasCalendarBlock, isFalse);
    RecurringGoalLink.reconcile(calendar, nodes);
    expect(calendar.byId('e1')!.isTask, isFalse);
    NodeEventLink.deleteEventAndNodes(calendar, nodes, 'e1');
    expect(nodes.byId(id)!.isDone, isTrue);
    expect(calendar.byId('e1'), isNull);
  });

  test(
    'two goals claiming a series cannot steal or duplicate its sessions',
    () {
      seed();
      RecurringGoalLink.reconcile(calendar, nodes);
      nodes.addNode(
        Node(
          id: 'other',
          title: 'Different goal',
          createdAt: day,
          recurrence: const NodeRecurrence(frequency: TimeScale.daily),
          calendarLink: nodes.byId('goal')!.calendarLink,
        ),
      );
      nodes.generateInstances(
        templateId: 'other',
        from: day,
        horizon: day.add(const Duration(days: 2)),
      );
      calendar.addEvent(event('next', offset: 1));
      RecurringGoalLink.reconcile(calendar, nodes);
      expect(calendar.byId('next')!.taskId, isNull);
    },
  );

  test('calendar editor upsert preserves the goal occurrence title', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes);
    final id = calendar.byId('e1')!.taskId!;
    nodes.upsertLinkedNodeForEvent(
      calendar.byId('e1')!.copyWith(subject: 'New calendar label'),
    );
    expect(nodes.byId(id)!.title, 'Daily Scripture Study');
  });
  test('unassigning the series prevents new imports from reattaching', () {
    seed();
    RecurringGoalLink.reconcile(calendar, nodes);
    NodeEventLink.unassignEventFromGoal(
      calendar,
      nodes,
      'e1',
      'goal',
      now: day,
    );
    expect(nodes.byId('goal')!.calendarLink!.isEnabled, isFalse);
    calendar.addEvent(event('next', offset: 1));
    RecurringGoalLink.reconcile(calendar, nodes);
    expect(calendar.byId('next')!.taskId, isNull);
  });
  test(
    'coordinator connects hydrated work and later calendar arrivals',
    () async {
      seed();
      final transactions = TransactionsCubit();
      final coordinator = RecurringGoalCoordinator(
        nodes,
        calendar,
        transactions,
      );
      await Future<void>.delayed(Duration.zero);
      expect(nodes.byId('e1'), isNull);
      expect(calendar.byId('e1')!.taskId, isNotNull);
      calendar.addEvent(event('next', offset: 1));
      await Future<void>.delayed(Duration.zero);
      expect(calendar.byId('next')!.taskId, isNotNull);
      expect(nodes.nodesForEventId('next'), hasLength(1));
      coordinator.dispose();
      await transactions.close();
    },
  );
}
