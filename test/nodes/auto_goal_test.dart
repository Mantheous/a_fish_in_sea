import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/model/node_relations.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:flutter_test/flutter_test.dart';

final _monday = DateTime(2026, 10, 12);
final _sunday = DateTime(2026, 10, 18, 23, 59);

Node _node(
  String id, {
  List<String> parents = const [],
  AutoFacet? auto,
  ScheduleFacet? schedule,
  DateTime? actualStart,
  DateTime? actualEnd,
  List<TimeSession> sessions = const [],
  DateTime? completedAt,
  NodeStatus status = NodeStatus.open,
  String? classLabel,
  String? classId,
  bool homework = false,
  bool instanceOf = false,
}) => Node(
  id: id,
  title: id,
  parentIds: parents,
  auto: auto,
  schedule: schedule,
  actualStart: actualStart,
  actualEnd: actualEnd,
  sessions: sessions,
  completedAt: completedAt,
  status: status,
  classLabel: classLabel,
  classId: classId,
  sourceEventId: homework ? 'event:$id' : null,
  instanceOfId: instanceOf ? 'template' : null,
  createdAt: DateTime(2026, 9, 1),
);

void main() {
  group('AutoFacet persistence', () {
    test('round-trips every field', () {
      const facet = AutoFacet(
        source: AutoSource.tasks,
        metric: AutoMetric.percentDone,
        target: 100,
        comparison: AutoComparison.atLeast,
        period: TimeScale.biweekly,
        scope: AutoScope.all,
        homeworkOnly: true,
        classKeys: ['Physics', 'CS 101'],
        moneyCategories: ['Food'],
        horizonDays: 2,
      );
      expect(AutoFacet.fromJson(facet.toJson()), facet);
    });

    test('unknown enums and wrong types fall back instead of throwing', () {
      final parsed = AutoFacet.fromJson({
        'source': 'telepathy',
        'metric': 'vibes',
        'target': 'a lot',
        'comparison': 'maybe',
        'period': 'fortnight-ish',
        'scope': 'everything',
        'classKeys': ['Physics', 42, ''],
        'horizonDays': 'soon',
      });
      expect(parsed.source, AutoSource.tasks);
      expect(parsed.metric, AutoMetric.minutes);
      expect(parsed.target, 0);
      expect(parsed.comparison, AutoComparison.atLeast);
      expect(parsed.period, TimeScale.weekly);
      expect(parsed.scope, AutoScope.subtree);
      expect(parsed.classKeys, ['Physics']);
      expect(parsed.horizonDays, isNull);
    });

    test('automation implies a derived role and never an unbounded goal', () {
      final automated = Node(
        id: 'a',
        title: 'Automated',
        createdAt: _monday,
        auto: const AutoFacet(target: 10),
      );
      expect(roleOf(automated), NodeRole.derived);
      expect(validateUnbounded(automated), isNull);
      expect(
        validateUnbounded(automated.copyWith(isUnbounded: true)),
        isNotNull,
      );
    });

    test('node round-trips automation and legacy payloads load plain', () {
      final automated = Node(
        id: 'a',
        title: 'Scripture study',
        createdAt: _monday,
        auto: const AutoFacet(target: 420),
      );
      expect(Node.fromJson(automated.toJson()), automated);

      final legacy = automated.toJson()
        ..remove('auto')
        ..remove('metrics')
        ..remove('extraMetrics');
      expect(Node.fromJson(legacy).auto, isNull);
      final corrupt = automated.toJson()
        ..['auto'] = 'not-a-map'
        ..remove('metrics')
        ..remove('extraMetrics');
      expect(Node.fromJson(corrupt).id, 'a');
      expect(Node.fromJson(corrupt).auto, isNull);
    });
  });

  group('task goals', () {
    test('sums recorded minutes under the goal for a 7-hour week', () {
      final goal = _node(
        'scripture',
        auto: const AutoFacet(
          source: AutoSource.tasks,
          metric: AutoMetric.minutes,
          target: 420,
        ),
      );
      final week = [
        for (final (i, minutes) in [120, 120, 180].indexed)
          _node(
            'study$i',
            parents: const ['scripture'],
            actualStart: _monday.add(Duration(days: i, hours: 8)),
            actualEnd: _monday.add(
              Duration(days: i, hours: 8, minutes: minutes),
            ),
          ),
      ];
      final reading = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [goal, ...week],
      );
      expect(reading.actual, 420);
      expect(reading.progress, 1.0);
      expect(reading.satisfied, isTrue);
      expect(reading.matched, 3);
      expect(reading.summary, '7h / 7h');
    });

    test('counts recorded runs, not the gap between them', () {
      final goal = _node(
        'study',
        auto: const AutoFacet(
          source: AutoSource.tasks,
          metric: AutoMetric.minutes,
          target: 60,
        ),
      );
      final first = TimeSession(
        id: 's1',
        start: _monday.add(const Duration(hours: 9)),
        end: _monday.add(const Duration(hours: 9, minutes: 30)),
      );
      final second = TimeSession(
        id: 's2',
        start: _monday.add(const Duration(hours: 14)),
        end: _monday.add(const Duration(hours: 14, minutes: 30)),
      );
      final task = _node(
        'task',
        parents: const ['study'],
        sessions: [first, second],
        actualStart: first.start,
        actualEnd: second.end,
      );
      final reading = evaluateAutoGoal(
        goal,
        now: _monday.add(const Duration(hours: 18)),
        nodes: [goal, task],
      );
      expect(
        reading.actual,
        60,
        reason: 'the 4.5-hour gap between sessions is not work',
      );
      expect(reading.progress, 1.0);
    });

    for (final (label, spans, expected) in <(String, List<(int, int)>, double)>[
      ('multiple recorded days', [(9, 10), (33, 34)], 60),
      ('multiple runs on one day', [(9, 10), (14, 15)], 120),
      ('an overnight run', [(23, 25)], 60),
      ('a run ending at midnight', [(23, 24)], 60),
      ('a run clipped at the week start', [(-1, 1), (33, 34)], 60),
      ('a run clipped at the week end', [(167, 169)], 60),
      ('runs outside the week', [(-25, -24), (9, 10), (33, 34)], 60),
      ('no runs inside the week', [(-25, -24), (169, 170)], 0),
    ]) {
      test('average minutes counts days for $label', () {
        final goal = _node(
          'study',
          auto: const AutoFacet(metric: AutoMetric.averageMinutes, target: 90),
        );
        final sessions = [
          for (final (i, (start, end)) in spans.indexed)
            TimeSession(
              id: 's$i',
              start: _monday.add(Duration(hours: start)),
              end: _monday.add(Duration(hours: end)),
            ),
        ];
        final task = _node(
          'task',
          parents: const ['study'],
          sessions: sessions,
          actualStart: sessions.first.start,
          actualEnd: sessions.last.end,
          schedule: ScheduleFacet(
            start: _monday,
            end: _monday.add(const Duration(hours: 2)),
          ),
        );
        final reading = evaluateAutoGoal(
          goal,
          now: _sunday,
          nodes: [goal, task],
        );
        expect(reading.actual, expected);
        expect(reading.satisfied, expected >= 90);
        expect(reading.matched, expected > 0 ? 1 : 0);
        expect(reading.progress, closeTo((expected / 90).clamp(0, 1), 1e-9));
      });
    }

    test('average minutes deduplicates task days and keeps schedule fallback', () {
      final goal = _node(
        'study',
        auto: const AutoFacet(metric: AutoMetric.averageMinutes, target: 100),
      );
      final tasks = [
        for (final (i, hour) in [9, 14, 33].indexed)
          _node(
            'task$i',
            parents: const ['study'],
            actualStart: i == 0 ? _monday.add(Duration(hours: hour)) : null,
            actualEnd: i == 0 ? _monday.add(Duration(hours: hour + 1)) : null,
            schedule: ScheduleFacet(
              start: _monday.add(Duration(hours: hour)),
              end: _monday.add(Duration(hours: hour + 1)),
            ),
          ),
      ];
      final reading = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [goal, ...tasks],
      );
      expect(reading.actual, 90);
      expect(reading.matched, 3);
      expect(reading.satisfied, isFalse);
    });

    test('uses elapsed calendar blocks when nothing was recorded', () {
      final goal = _node('work', auto: const AutoFacet(target: 600));
      final shift = _node(
        'shift',
        parents: const ['work'],
        schedule: ScheduleFacet(
          start: _monday.add(const Duration(hours: 9)),
          end: _monday.add(const Duration(hours: 14)),
        ),
      );
      final future = _node(
        'future',
        parents: const ['work'],
        schedule: ScheduleFacet(
          start: _monday.add(const Duration(days: 5)),
          end: _monday.add(const Duration(days: 5, hours: 5)),
        ),
      );
      final reading = evaluateAutoGoal(
        goal,
        now: _monday.add(const Duration(hours: 18)),
        nodes: [goal, shift, future],
      );
      expect(reading.actual, 300, reason: 'only elapsed blocks count');
      expect(reading.progress, 0.5);
    });

    test('clips an overnight report at the week boundary', () {
      final goal = _node('work', auto: const AutoFacet(target: 120));
      final overnight = _node(
        'night',
        parents: const ['work'],
        actualStart: DateTime(2026, 10, 11, 23),
        actualEnd: DateTime(2026, 10, 12, 2),
      );
      final reading = evaluateAutoGoal(
        goal,
        now: DateTime(2026, 10, 12, 9),
        nodes: [goal, overnight],
      );
      expect(reading.actual, 120);
    });

    test('homework cap is satisfied under target and drops when over', () {
      final goal = _node(
        'homework',
        auto: const AutoFacet(
          source: AutoSource.tasks,
          metric: AutoMetric.minutes,
          target: 600,
          comparison: AutoComparison.atMost,
          scope: AutoScope.all,
          homeworkOnly: true,
        ),
      );
      final hw = _node(
        'hw',
        homework: true,
        actualStart: _monday.add(const Duration(hours: 8)),
        actualEnd: _monday.add(const Duration(hours: 12)),
      );
      final under = evaluateAutoGoal(goal, now: _sunday, nodes: [goal, hw]);
      expect(under.actual, 240);
      expect(under.satisfied, isTrue);
      expect(under.progress, 1.0);

      final heavy = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [
          goal,
          _node(
            'heavy',
            homework: true,
            actualStart: _monday.add(const Duration(hours: 8)),
            actualEnd: _monday.add(const Duration(hours: 20)),
          ),
        ],
      );
      expect(heavy.actual, 720);
      expect(heavy.satisfied, isFalse);
      expect(heavy.progress, closeTo(600 / 720, 1e-9));
    });

    test('class filter keeps one class and ignores personal work', () {
      final goal = _node(
        'physics',
        auto: const AutoFacet(
          metric: AutoMetric.minutes,
          target: 60,
          scope: AutoScope.all,
          homeworkOnly: true,
          classKeys: ['Physics'],
        ),
      );
      final physics = _node(
        'p',
        homework: true,
        classLabel: 'Physics',
        actualStart: _monday.add(const Duration(hours: 8)),
        actualEnd: _monday.add(const Duration(hours: 9)),
      );
      final math = _node(
        'm',
        homework: true,
        classLabel: 'Math',
        actualStart: _monday.add(const Duration(hours: 9)),
        actualEnd: _monday.add(const Duration(hours: 12)),
      );
      final personal = _node(
        'x',
        classLabel: 'Physics',
        actualStart: _monday.add(const Duration(hours: 12)),
        actualEnd: _monday.add(const Duration(hours: 15)),
      );
      final reading = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [goal, physics, math, personal],
      );
      expect(reading.actual, 60);
      expect(reading.matched, 1);
    });

    test('done percent checks the next N days of homework', () {
      final goal = _node(
        'ahead',
        auto: const AutoFacet(
          metric: AutoMetric.percentDone,
          target: 100,
          scope: AutoScope.all,
          homeworkOnly: true,
          horizonDays: 2,
        ),
      );
      final done = _node(
        'done',
        homework: true,
        status: NodeStatus.done,
        completedAt: DateTime(2026, 10, 17, 10),
        schedule: ScheduleFacet(due: DateTime(2026, 10, 18)),
      );
      final open = _node(
        'open',
        homework: true,
        schedule: ScheduleFacet(due: DateTime(2026, 10, 19)),
      );
      final after = _node(
        'after',
        homework: true,
        schedule: ScheduleFacet(due: DateTime(2026, 10, 21)),
      );
      final reading = evaluateAutoGoal(
        goal,
        now: DateTime(2026, 10, 17, 12),
        nodes: [goal, done, open, after],
      );
      expect(reading.matched, 2);
      expect(reading.actual, 50);
      expect(reading.satisfied, isFalse);
    });
  });

  group('completion and money goals', () {
    test('counts distinct completed run days', () {
      final goal = _node(
        'runs',
        auto: const AutoFacet(
          metric: AutoMetric.days,
          target: 5,
        ),
      );
      // Five completed run occurrences, two on one day: the goal counts
      // days, not duplicate activities.
      final runs = [
        for (final (i, day) in [12, 13, 14, 15, 16, 16].indexed)
          _node(
            'run$i',
            parents: const ['runs'],
            status: NodeStatus.done,
            completedAt: _monday.add(Duration(days: day - 12, hours: 7)),
            schedule: ScheduleFacet(
              due: _monday.add(Duration(days: day - 12)),
            ),
          ),
      ];
      final reading = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [goal, ...runs],
      );
      expect(reading.actual, 5);
      expect(reading.progress, 1.0);
    });

    test('sums only spending in the selected categories', () {
      final goal = _node(
        'food',
        auto: const AutoFacet(
          source: AutoSource.money,
          metric: AutoMetric.amount,
          target: 20,
          comparison: AutoComparison.atMost,
          scope: AutoScope.all,
          moneyCategories: ['Food'],
        ),
      );
      final txns = [
        Transaction(
          id: 't1',
          accountId: 'acct',
          amount: -12,
          date: DateTime(2026, 10, 13),
          name: 'Groceries',
          category: 'Food and Drink > Groceries',
        ),
        Transaction(
          id: 't2',
          accountId: 'acct',
          amount: -5.5,
          date: DateTime(2026, 10, 14),
          name: 'Cafe',
          category: 'Food and Drink > Coffee',
        ),
        Transaction(
          id: 't3',
          accountId: 'acct',
          amount: -40,
          date: DateTime(2026, 10, 15),
          name: 'Gas',
          category: 'Transportation > Gas',
        ),
        Transaction(
          id: 't4',
          accountId: 'acct',
          amount: 100,
          date: DateTime(2026, 10, 16),
          name: 'Paycheck',
          category: 'Income',
        ),
      ];
      final reading = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [goal],
        transactions: txns,
      );
      expect(reading.actual, 17.5);
      expect(reading.matched, 2);
      expect(reading.satisfied, isTrue);
      expect(reading.progress, 1.0);
    });

  });

  group('progress integration', () {
    test('automated goals feed parent progress and win over facets', () {
      final parent = _node('long-term');
      final autoHalf = _node(
        'auto-half',
        parents: const ['long-term'],
        auto: const AutoFacet(target: 10),
      );
      final autoFull = _node(
        'auto-full',
        parents: const ['long-term'],
        auto: const AutoFacet(target: 10),
      );
      final nodes = [parent, autoHalf, autoFull];
      final progress = progressForest(
        nodes,
        autoProgressByNodeId: {autoHalf.id: 0.5, autoFull.id: 1.0},
      );
      expect(progress['auto-half'], 0.5);
      expect(progress['auto-full'], 1.0);
      expect(progress['long-term'], 0.75);
    });

    test('at-most goals count as complete while under budget', () {
      final goal = _node(
        'food',
        auto: const AutoFacet(
          source: AutoSource.money,
          metric: AutoMetric.amount,
          target: 20,
          comparison: AutoComparison.atMost,
          scope: AutoScope.all,
        ),
      );
      final reading = evaluateAutoGoal(
        goal,
        now: _sunday,
        nodes: [goal],
        transactions: [
          Transaction(
            id: 't1',
            accountId: 'acct',
            amount: -3,
            date: DateTime(2026, 10, 13),
            name: 'Snack',
          ),
        ],
      );
      expect(reading.progress, 1.0);
      expect(reading.satisfied, isTrue);
    });
  });
}
