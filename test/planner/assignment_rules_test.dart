import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

AssignmentRule rule({
  String id = 'ar-1',
  String feedId = 'math290',
  String templateKey = 'video quiz',
  int offset = -2,
}) =>
    AssignmentRule(
      id: id,
      feedId: feedId,
      templateKey: templateKey,
      displayName: 'Video Quiz',
      dueOffsetDays: offset,
      createdAt: DateTime(2030, 1, 1),
      classLabel: 'MATH 290',
    );

PlannerEvent event(String uid, String subject, DateTime due) => PlannerEvent(
      id: 'hw:math290:$uid',
      subject: subject,
      start: due,
      end: due,
      sourceUid: uid,
    );

const feed = Feed(
  id: 'math290',
  name: 'MATH 290',
  url: 'https://example.com/feed.ics',
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

  group('matching', () {
    test('exact key equality inside one feed', () {
      final r = rule();
      expect(
          assignmentRuleMatches(r,
              feedId: 'math290', classId: null, title: 'Video Quiz 3.1'),
          isTrue);
      // Cross-feed never matches.
      expect(
          assignmentRuleMatches(r,
              feedId: 'stat230', classId: null, title: 'Video Quiz 3.1'),
          isFalse);
      // Substring lookalikes never match.
      expect(
          assignmentRuleMatches(r,
              feedId: 'math290', classId: null, title: 'Video Quiz Retake 1'),
          isFalse);
      expect(
          assignmentRuleMatches(r,
              feedId: 'math290', classId: null, title: 'Quiz 1'),
          isFalse);
    });

    test('offsetFor falls back to 0', () {
      expect(
          assignmentOffsetFor([rule()],
              feedId: 'math290', title: 'Video Quiz 9.9'),
          -2);
      expect(
          assignmentOffsetFor([rule()],
              feedId: 'math290', title: 'Midterm exam'),
          0);
    });

    test('labels', () {
      expect(describeDueOffset(-2), '2 days early');
      expect(describeDueOffset(0), 'On time');
      expect(describeDueOffset(1), '1 day late');
      expect(compactDueOffset(-2), '−2d');
    });
  });

  group('AssignmentRule json', () {
    test('round-trips', () {
      final r = rule();
      expect(AssignmentRule.fromJson(r.toJson()), r);
    });

    test('rejects missing keys, clamps offsets', () {
      expect(() => AssignmentRule.fromJson({}), throwsFormatException);
      final r = AssignmentRule.fromJson({
        'id': 'x',
        'feedId': 'f',
        'templateKey': 'k',
        'dueOffsetDays': 99,
      });
      expect(r.dueOffsetDays, 30);
    });
  });

  group('AssignmentRulesCubit', () {
    test('create/ruleFor/delete + corrupt tolerance', () {
      final cubit = AssignmentRulesCubit();
      final created = cubit.createRule(
        feedId: 'math290',
        templateKey: 'video quiz',
        displayName: 'Video Quiz',
        dueOffsetDays: -2,
        classLabel: 'MATH 290',
      );
      expect(
          cubit.ruleFor(
              feedId: 'math290', classId: null, title: 'Video Quiz 3.1'),
          created);
      // Same template reuses the id (edit, not duplicate).
      final again = cubit.createRule(
        feedId: 'math290',
        templateKey: 'video quiz',
        displayName: 'Video Quiz',
        dueOffsetDays: -3,
      );
      expect(again.id, created.id);
      expect(cubit.state, hasLength(1));

      final restored =
          cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);

      final tolerant = cubit.fromJson({
        'rules': [created.toJson(), {'id': 42}, 'nope', {'id': 'x'}],
      });
      expect(tolerant?.map((r) => r.id), [created.id]);

      expect(cubit.fromJson({}), isNull);
      cubit.deleteRule(created.id);
      expect(cubit.state, isEmpty);
    });
  });

  group('NodeCubit rule application', () {
    test('fresh imports shift by the rule', () {
      UndoCubit();
      final nodes = NodeCubit();
      final rules = AssignmentRulesCubit()
        ..createRule(
          feedId: 'math290',
          templateKey: 'video quiz',
          displayName: 'Video Quiz',
          dueOffsetDays: -2,
        );
      final due = DateTime(2030, 2, 7, 9);
      nodes.importFromFeed(
        [event('event-assignment-1', 'Video Quiz 3.1', due)],
        feed,
        assignmentRules: rules.state,
      );
      expect(nodes.state, hasLength(1));
      final n = nodes.state.single;
      // Planned deadline moved early; feed window kept as truth.
      expect(n.schedule?.due, due.subtract(const Duration(days: 2)));
      expect(n.schedule?.start, due);
    });

    test('retarget applies, migrates, reverts; manual edits survive', () {
      UndoCubit();
      final nodes = NodeCubit();
      final base = DateTime(2030, 2, 7, 9);
      nodes.importFromFeed(
        [
          event('event-assignment-1', 'Video Quiz 3.1', base),
          event('event-assignment-2', 'Video Quiz 3.2',
              base.add(const Duration(days: 7))),
          event('event-assignment-9', 'Midterm exam',
              base.add(const Duration(days: 14))),
        ],
        feed,
      );
      // Hand-edit one quiz due (simulates a manual move).
      final manualId = 'hw:math290:event-assignment-2';
      final manual = nodes.byId(manualId)!;
      nodes.updateNode(manual.copyWith(
        schedule: manual.schedule!
            .copyWith(due: base.add(const Duration(days: 30))),
      ));

      // Apply −2 to the two quizzes; manual + midterm untouched.
      final applied = nodes.retargetAssignmentDues(
        feedId: 'math290',
        templateKey: 'video quiz',
        newOffsetDays: -2,
      );
      expect(applied, 1);
      expect(nodes.byId('hw:math290:event-assignment-1')?.schedule?.due,
          base.subtract(const Duration(days: 2)));
      expect(nodes.byId(manualId)?.schedule?.due,
          base.add(const Duration(days: 30)));

      // Edit −2 → −3 migrates the applied one, still skips the manual.
      final migrated = nodes.retargetAssignmentDues(
        feedId: 'math290',
        templateKey: 'video quiz',
        newOffsetDays: -3,
        fromOffsets: const [0, -2],
      );
      expect(migrated, 1);
      expect(nodes.byId('hw:math290:event-assignment-1')?.schedule?.due,
          base.subtract(const Duration(days: 3)));

      // Delete moves it back to the feed date.
      final reverted = nodes.retargetAssignmentDues(
        feedId: 'math290',
        templateKey: 'video quiz',
        newOffsetDays: 0,
        fromOffsets: const [-3],
      );
      expect(reverted, 1);
      expect(nodes.byId('hw:math290:event-assignment-1')?.schedule?.due,
          base);
    });
  });

  group('Learning Suite exclusive-end windows', () {
    const lsFeed = Feed(
      id: 'math290',
      name: 'MATH 290',
      url: 'https://example.com/feed.ics',
      kind: FeedKind.learningSuite,
    );

    PlannerEvent window(String uid, String subject) => PlannerEvent(
          id: 'hw:math290:$uid',
          subject: subject,
          notes: 'Before doing the quiz, watch the video',
          start: DateTime(2026, 10, 12),
          end: DateTime(2026, 10, 15),
          allDay: true,
          sourceUid: uid,
        );

    test('fresh window imports are due on the inclusive end', () {
      UndoCubit();
      final nodes = NodeCubit();
      nodes.importFromFeed(
        [window('wq-17-18', 'Video Quiz Sections 17 and 18')],
        lsFeed,
      );
      expect(nodes.state, hasLength(1));
      // DTSTART Oct 12 DTEND Oct 15 (exclusive) → due Oct 14.
      expect(nodes.state.single.schedule?.due, DateTime(2026, 10, 14));
      expect(nodes.state.single.schedule?.start, DateTime(2026, 10, 12));
      expect(nodes.state.single.schedule?.end, DateTime(2026, 10, 15));
    });

    test('resync heals old exclusive-end dues, spares hand edits', () {
      UndoCubit();
      final nodes = NodeCubit();
      final ev = window('wq-17-18', 'Video Quiz Sections 17 and 18');
      nodes.importFromFeed([ev], lsFeed);
      // Simulate a pre-fix import sitting on the exclusive end (Oct 15).
      final wrong = nodes.byId('hw:math290:wq-17-18')!;
      nodes.updateNode(wrong.copyWith(
        schedule: wrong.schedule!.copyWith(due: DateTime(2026, 10, 15)),
      ));
      // Hand-edited item far from either base.
      final hand = PlannerEvent(
        id: 'hw:math290:hand-1',
        subject: 'Video Quiz Section 19',
        notes: 'Before doing the quiz, watch the video',
        start: DateTime(2026, 10, 14),
        end: DateTime(2026, 10, 17),
        allDay: true,
        sourceUid: 'hand-1',
      );
      nodes.importFromFeed([hand], lsFeed);
      final handNode = nodes.byId('hw:math290:hand-1')!;
      nodes.updateNode(handNode.copyWith(
        schedule: handNode.schedule!
            .copyWith(due: DateTime(2026, 11, 1)),
      ));

      nodes.importFromFeed([ev, hand], lsFeed);
      expect(nodes.byId('hw:math290:wq-17-18')?.schedule?.due,
          DateTime(2026, 10, 14));
      expect(nodes.byId('hw:math290:hand-1')?.schedule?.due,
          DateTime(2026, 11, 1));
    });
  });
}
