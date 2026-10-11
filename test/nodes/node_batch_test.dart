import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node goalNode(String id) => Node(
      id: id,
      title: id,
      createdAt: DateTime(2026, 9, 1),
    );

PlannerEvent gEvent(
  String id, {
  String? seriesId,
  String? recurrenceRule,
  bool isTask = false,
}) =>
    PlannerEvent(
      id: 'gcal:f:$id',
      subject: 'Event $id',
      start: DateTime(2026, 9, 12, 9),
      end: DateTime(2026, 9, 12, 10),
      feedId: 'f',
      sourceUid: id,
      seriesId: seriesId,
      recurrenceRule: recurrenceRule ?? '',
      isTask: isTask,
    );

/// Repeating series with [count] instances under master `m`.
List<PlannerEvent> seriesEvents(int count) => [
      gEvent('m', recurrenceRule: 'FREQ=DAILY'),
      for (var i = 0; i < count; i++) gEvent('m_$i', seriesId: 'm'),
    ];

Future<void> flushEvents() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('CalendarCubit.updateEvents', () {
    test('replaces by id, keeps order and others', () {
      final calendar = CalendarCubit();
      final a = gEvent('a', isTask: true);
      final b = gEvent('b', isTask: true);
      calendar.addEvent(a);
      calendar.addEvent(b);
      calendar.updateEvents([b.copyWith(subject: 'B2')]);
      expect(calendar.state.map((e) => e.id), ['gcal:f:a', 'gcal:f:b']);
      expect(calendar.byId('gcal:f:b')?.subject, 'B2');
      expect(calendar.byId('gcal:f:a')?.subject, 'Event a');
    });

    test('emits once for many updates', () async {
      final calendar = CalendarCubit();
      for (final e in seriesEvents(30)) {
        calendar.addEvent(e);
      }
      var emits = 0;
      final sub = calendar.stream.listen((_) => emits++);
      calendar.updateEvents([
        for (final e in calendar.state) e.copyWith(isTask: true),
      ]);
      await flushEvents();
      await sub.cancel();
      expect(emits, 1);
      expect(calendar.state.every((e) => e.isTask), isTrue);
    });

    test('empty list emits nothing', () async {
      final calendar = CalendarCubit();
      calendar.addEvent(gEvent('a', isTask: true));
      var emits = 0;
      final sub = calendar.stream.listen((_) => emits++);
      calendar.updateEvents(const []);
      await flushEvents();
      await sub.cancel();
      expect(emits, 0);
    });

    test('records a single undo entry', () {
      UndoCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(gEvent('a', isTask: true));
      calendar.addEvent(gEvent('b', isTask: true));
      final undo = UndoCubit.instance!;
      final before = undo.state.undoStack.length;
      calendar.updateEvents([
        calendar.byId('gcal:f:a')!.copyWith(subject: 'A2'),
        calendar.byId('gcal:f:b')!.copyWith(subject: 'B2'),
      ]);
      expect(undo.state.undoStack.length, before + 1);
    });
  });

  group('NodeCubit.writeNodes', () {
    test('updates by id, adds missing, removes ids, single emit', () async {
      final nodes = NodeCubit();
      expect(nodes.addNode(goalNode('keep')), isNull);
      expect(nodes.addNode(goalNode('drop')), isNull);
      var emits = 0;
      final sub = nodes.stream.listen((_) => emits++);
      final errors = nodes.writeNodes(
        upserts: [
          nodes.byId('keep')!.copyWith(title: 'kept'),
          goalNode('new'),
        ],
        removeIds: {'drop'},
      );
      await flushEvents();
      await sub.cancel();
      expect(errors, isEmpty);
      expect(emits, 1);
      expect(nodes.byId('keep')?.title, 'kept');
      expect(nodes.byId('new'), isNotNull);
      expect(nodes.byId('drop'), isNull);
    });

    test('skips invalid nodes and reports them', () {
      final nodes = NodeCubit();
      expect(nodes.addNode(goalNode('goal')), isNull);
      // Self-parenting fails validation.
      final bad = goalNode('bad').copyWith(parentIds: ['bad']);
      final errors = nodes.writeNodes(upserts: [bad, goalNode('good')]);
      expect(errors['bad'], isNotNull);
      expect(nodes.byId('bad'), isNull);
      expect(nodes.byId('good'), isNotNull);
    });
  });

  group('NodeCubit batch equivalence with single writes', () {
    test('ensureNodesForFeedEvents matches sequential ensures', () {
      final base = seriesEvents(12);
      final events = [
        for (var i = 0; i < base.length; i++)
          i.isEven ? base[i] : base[i].copyWith(done: true),
      ];
      final batched = NodeCubit()..ensureNodesForFeedEvents(events);
      final sequential = NodeCubit();
      for (final e in events) {
        sequential.ensureNodeForFeedEvent(e);
      }
      expect(
        summarizeNodes(batched.state),
        summarizeNodes(sequential.state),
      );
    });

    test('upsertLinkedNodesForEvents matches sequential upserts', () {
      final events = [
        for (var i = 0; i < 8; i++)
          PlannerEvent(
            id: 'evt:$i',
            subject: 'E$i',
            start: DateTime(2026, 9, 12, 9),
            end: DateTime(2026, 9, 12, 10),
            isTask: true,
          ),
      ];
      final batched = NodeCubit();
      final batchedIds = batched.upsertLinkedNodesForEvents(events);
      final sequential = NodeCubit();
      final sequentialIds = <String, String>{};
      for (final e in events) {
        sequentialIds[e.id] = sequential.upsertLinkedNodeForEvent(e);
      }
      expect(batchedIds, sequentialIds);
      expect(
        summarizeNodes(batched.state),
        summarizeNodes(sequential.state),
      );
    });

    test('setDoneForEventIds matches sequential setDone', () {
      final batched = NodeCubit();
      final sequential = NodeCubit();
      for (var i = 0; i < 6; i++) {
        final event = gEvent('e$i');
        batched.ensureNodeForFeedEvent(event);
        sequential.ensureNodeForFeedEvent(event);
      }
      final ids = {'gcal:f:e0', 'gcal:f:e2', 'gcal:f:e4'};
      final at = DateTime(2026, 9, 13, 12);
      batched.setDoneForEventIds(ids, done: true, completedAt: at);
      for (final id in ids) {
        sequential.setDoneForEvent(id, done: true, completedAt: at);
      }
      expect(
        summarizeNodes(batched.state),
        summarizeNodes(sequential.state),
      );
    });
  });

  group('batched series assign (crash regression)', () {
    test('assigning a 40-member series emits a bounded number of times',
        () async {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goalNode('goal')), isNull);
      for (final e in seriesEvents(40)) {
        calendar.addEvent(e);
      }
      var calEmits = 0;
      var nodeEmits = 0;
      final sub1 = calendar.stream.listen((_) => calEmits++);
      final sub2 = nodes.stream.listen((_) => nodeEmits++);
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:m_0',
        'goal',
      );
      await flushEvents();
      await sub1.cancel();
      await sub2.cancel();
      expect(result.error, isNull);
      expect(result.assigned, 41);
      // One emit per phase (mark, shadows, parents) — never per member.
      // The old per-member loop emitted ~5x per occurrence and killed
      // the tab (Aw, Snap SIGILL) on large stores.
      expect(calEmits, lessThanOrEqualTo(2));
      expect(nodeEmits, lessThanOrEqualTo(3));
      for (final e in calendar.state) {
        expect(e.isTask, isTrue, reason: e.id);
        expect(
          NodeEventLink.backingNodeFor(nodes, calendar, e.id)?.parentIds,
          contains('goal'),
          reason: e.id,
        );
      }
    });

    test('assigning a 300-member series completes', () async {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      expect(nodes.addNode(goalNode('goal')), isNull);
      for (final e in seriesEvents(300)) {
        calendar.addEvent(e);
      }
      var calEmits = 0;
      var nodeEmits = 0;
      final sub1 = calendar.stream.listen((_) => calEmits++);
      final sub2 = nodes.stream.listen((_) => nodeEmits++);
      final result = NodeEventLink.assignEventToGoal(
        calendar,
        nodes,
        'gcal:f:m_0',
        'goal',
      );
      await flushEvents();
      await sub1.cancel();
      await sub2.cancel();
      expect(result.error, isNull);
      expect(result.assigned, 301);
      expect(calEmits, lessThanOrEqualTo(2));
      expect(nodeEmits, lessThanOrEqualTo(3));
    });
  });
}

/// Created-at-insensitive summary for equivalence checks (batched and
/// sequential runs mint different timestamps).
Map<String, String> summarizeNodes(List<Node> nodes) => {
      for (final n in nodes)
        n.id: '${n.status}|${n.title}|${n.completedAt}|'
            '${[...n.parentIds]..sort()}|${[...n.assignees.map((a) => a.id)]..sort()}|'
            '${n.schedule?.due}|${n.schedule?.start}|${n.schedule?.end}|'
            '${n.calendarEventId}|${n.sourceEventId}',
    };
