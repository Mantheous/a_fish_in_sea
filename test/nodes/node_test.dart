import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_feed.dart';
import 'package:a_fish_in_sea/nodes/service/node_legacy_migration.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/nodes/service/node_tracking.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node node(
  String id, {
  List<String> parents = const [],
  NodeStatus status = NodeStatus.open,
  ScheduleFacet? schedule,
  MoneyFacet? money,
  EffortFacet? effort,
  NodeRecurrence? recurrence,
  RuleFacet? rule,
  String? instanceOfId,
  String? classId,
  String? sourceEventId,
  DateTime? actualStart,
  DateTime? actualEnd,
}) =>
    Node(
      id: id,
      title: id,
      parentIds: parents,
      status: status,
      createdAt: DateTime(2026, 9, 1),
      schedule: schedule,
      money: money,
      effort: effort,
      recurrence: recurrence,
      rule: rule,
      instanceOfId: instanceOfId,
      classId: classId,
      sourceEventId: sourceEventId,
      actualStart: actualStart,
      actualEnd: actualEnd,
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

  group('DAG validation', () {
    test('single + multiple parents accepted', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('a')), isNull);
      expect(cubit.addNode(node('b')), isNull);
      expect(cubit.addNode(node('c', parents: ['a', 'b'])), isNull);
      expect(cubit.childrenOf('a').map((n) => n.id), ['c']);
      expect(cubit.childrenOf('b').map((n) => n.id), ['c']);
    });

    test('self, missing, duplicate, and cycle parents rejected', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('a')), isNull);
      expect(cubit.addNode(node('b', parents: ['a'])), isNull);
      expect(
          cubit.addNode(node('self', parents: ['self'])), isNotNull);
      expect(cubit.addNode(node('ghost', parents: ['nope'])), isNotNull);
      expect(cubit.addNode(node('dup', parents: ['a', 'a'])), isNotNull);
      // a <- b exists; reparenting a under b would cycle.
      expect(cubit.reparent('a', ['b']), isNotNull);
      // Deeper cycle: c under b, then a under c.
      expect(cubit.addNode(node('c', parents: ['b'])), isNull);
      expect(cubit.reparent('a', ['c']), isNotNull);
    });

    test('delete keeps shared children, cascades fully-orphaned ones', () {
      final cubit = NodeCubit();
      cubit.addNode(node('a'));
      cubit.addNode(node('b'));
      cubit.addNode(node('shared', parents: ['a', 'b']));
      cubit.addNode(node('only-a', parents: ['a']));
      cubit.deleteNode('a');
      expect(cubit.byId('a'), isNull);
      expect(cubit.byId('only-a'), isNull);
      expect(
          cubit.byId('shared')?.parentIds, ['b'],
          reason: 'shared child survives under its other parent');
    });
  });

  group('facets drive views, undated stays valid', () {
    test('undated node valid and invisible to all views', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('idea')), isNull);
      expect(calendarNodes(cubit.state), isEmpty);
      expect(priorityQueue(cubit.state, DateTime(2026, 9, 12)), isEmpty);
      expect(ledgerNodes(cubit.state), isEmpty);
    });

    test('scheduled node appears on calendar + queue; money on ledger', () {
      final cubit = NodeCubit();
      final day = DateTime(2026, 9, 12, 9);
      cubit.addNode(node('hw',
          schedule: ScheduleFacet(
            due: day,
            start: day,
            end: day.add(const Duration(hours: 1)),
          ),
          money: const MoneyFacet(targetAmount: 20)));
      expect(calendarNodes(cubit.state).map((n) => n.id), ['hw']);
      expect(
          priorityQueue(cubit.state, DateTime(2026, 9, 10)).map((n) => n.id),
          ['hw']);
      expect(ledgerNodes(cubit.state).map((n) => n.id), ['hw']);
    });

    test('queue sorts overdue first, then earliest due', () {
      final cubit = NodeCubit();
      cubit.addNode(node('later',
          schedule: ScheduleFacet(due: DateTime(2026, 9, 20))));
      cubit.addNode(node('over',
          schedule: ScheduleFacet(due: DateTime(2026, 9, 1))));
      cubit.addNode(node('soon',
          schedule: ScheduleFacet(due: DateTime(2026, 9, 13))));
      final queue = priorityQueue(cubit.state, DateTime(2026, 9, 12));
      expect(queue.map((n) => n.id), ['over', 'soon', 'later']);
    });
  });

  group('example: run every day', () {
    test('template generates daily instances, edits preserved', () {
      final cubit = NodeCubit();
      cubit.addNode(node('run',
          effort: const EffortFacet(targetMinutes: 30),
          recurrence:
              const NodeRecurrence(frequency: TimeScale.daily)));
      final made = cubit.generateInstances(
        templateId: 'run',
        from: DateTime(2026, 9, 12),
        horizon: DateTime(2026, 9, 14, 23, 59),
      );
      expect(made, 3);
      expect(cubit.instancesOf('run').length, 3);
      // Re-running is a no-op (user edits preserved).
      expect(
          cubit.generateInstances(
            templateId: 'run',
            from: DateTime(2026, 9, 12),
            horizon: DateTime(2026, 9, 14, 23, 59),
          ),
          0);
      final first = cubit.byId('run@2026-09-12')!;
      expect(first.parentIds, ['run']);
      expect(first.instanceOfId, 'run');
      expect(first.hasDue, isTrue);
      // Complete one day; template progress reflects 1/3.
      cubit.toggleDone('run@2026-09-12');
      final progress = progressForest(cubit.state);
      expect(progress['run'], closeTo(1 / 3, 0.001));
    });
  });

  group('example: spend less than X on food', () {
    test('subtree sums toward the cap; linking reports it', () {
      final cubit = NodeCubit();
      cubit.addNode(node('food',
          money: const MoneyFacet(
              targetAmount: 400, direction: MoneyDirection.spend)));
      cubit.addNode(node('groceries',
          parents: ['food'],
          schedule: ScheduleFacet(due: DateTime(2026, 9, 12)),
          money: const MoneyFacet(
              targetAmount: 62.40, direction: MoneyDirection.spend)));
      cubit.linkTransaction(
          nodeId: 'groceries',
          transactionId: 'plaid-1',
          transactionAmount: -62.40);
      final groceries = cubit.byId('groceries')!;
      expect(groceries.money?.status, MoneyStatus.paid);
      expect(
          moneyActualForNode(cubit.byId('food')!, cubit.state), 62.40);
      final progress = progressForest(cubit.state,
          moneyActualByNodeId: {
            'groceries': 62.40,
          });
      expect(progress['food'], closeTo(62.40 / 400, 0.001));
    });

    test('smaller transaction subdivides with a remainder', () {
      final cubit = NodeCubit();
      cubit.addNode(node('gas',
          schedule: ScheduleFacet(due: DateTime(2026, 9, 12)),
          money: const MoneyFacet(
              targetAmount: 50, direction: MoneyDirection.spend)));
      cubit.linkTransaction(
          nodeId: 'gas', transactionId: 'plaid-2', transactionAmount: -45);
      expect(cubit.byId('gas')?.money?.actualAmount, 45);
      expect(cubit.byId('gas')?.money?.status, MoneyStatus.paid);
      final remainder =
          cubit.state.where((n) => n.title.contains('remainder'));
      expect(remainder.length, 1);
      expect(remainder.single.money?.targetAmount, closeTo(5, 0.001));
    });

    test('larger transaction logs actual without touching the target', () {
      final cubit = NodeCubit();
      cubit.addNode(node('dining',
          money: const MoneyFacet(
              targetAmount: 50, direction: MoneyDirection.spend)));
      cubit.linkTransaction(
          nodeId: 'dining', transactionId: 'plaid-3', transactionAmount: -70);
      final dining = cubit.byId('dining')!;
      expect(dining.money?.actualAmount, 70);
      expect(dining.money?.targetAmount, 50);
      expect(leafProgress(dining, moneyActual: 70), 1.0);
    });

    test('subdivide + merge round-trip', () {
      final cubit = NodeCubit();
      cubit.addNode(node('x',
          money: const MoneyFacet(
              targetAmount: 100, direction: MoneyDirection.spend)));
      cubit.subdivideNode('x', 60);
      expect(cubit.byId('x')?.money?.targetAmount, 60);
      final remId =
          cubit.state.firstWhere((n) => n.title.contains('remainder')).id;
      cubit.mergeNodes('x', remId);
      expect(cubit.byId('x')?.money?.targetAmount, 100);
      expect(cubit.byId(remId), isNull);
    });
  });

  group('example: three days ahead on homework', () {
    List<Node> homeworkSet() => [
          node('hw1',
              classId: 'stat230',
              status: NodeStatus.done,
              schedule: ScheduleFacet(due: DateTime(2026, 9, 13))),
          node('hw2',
              classId: 'stat230',
              schedule: ScheduleFacet(due: DateTime(2026, 9, 14))),
          node('later',
              classId: 'stat230',
              schedule: ScheduleFacet(due: DateTime(2026, 9, 30))),
        ];

    test('unsatisfied while anything due soon is open', () {
      final result = evaluateHomeworkAhead(
          all: homeworkSet(), now: DateTime(2026, 9, 12), horizonDays: 3);
      expect(result.dueSoon.map((n) => n.id), ['hw1', 'hw2']);
      expect(result.satisfied, isFalse);
      expect(result.doneCount, 1);
    });

    test('satisfied once the window is done; far tasks ignored', () {
      final all = homeworkSet()
          .map((n) => n.id == 'hw2'
              ? n.copyWith(status: NodeStatus.done)
              : n)
          .toList();
      final result = evaluateHomeworkAhead(
          all: all, now: DateTime(2026, 9, 12), horizonDays: 3);
      expect(result.satisfied, isTrue);
    });

    test('rule node carries the horizon definition', () {
      final cubit = NodeCubit();
      cubit.addNode(node('ahead',
          rule: const RuleFacet(
              kind: NodeRuleKind.homeworkAhead, horizonDays: 3)));
      expect(cubit.byId('ahead')?.rule?.horizonDays, 3);
      expect(
          Node.fromJson(cubit.byId('ahead')!.toJson()).rule?.kind,
          NodeRuleKind.homeworkAhead);
    });
  });

  group('example: buy a house + never go negative', () {
    test('income projections fund the goal; actuals replace estimates', () {
      final cubit = NodeCubit();
      cubit.addNode(node('house',
          schedule: ScheduleFacet(due: DateTime(2036, 6, 1)),
          money: const MoneyFacet(
              targetAmount: 40000, direction: MoneyDirection.save)));
      cubit.addNode(node('pay',
          parents: ['house'],
          money: const MoneyFacet(
              targetAmount: 2100,
              direction: MoneyDirection.income,
              isRecurring: true),
          recurrence: const NodeRecurrence(
              frequency: TimeScale.biweekly)));
      final made = cubit.generateInstances(
        templateId: 'pay',
        from: DateTime(2026, 9, 18),
        horizon: DateTime(2026, 10, 16),
      );
      expect(made, 3); // 9/18, 10/2, 10/16
      final first = cubit.byId('pay@2026-09-18')!;
      expect(first.money?.status, MoneyStatus.projected);
      // Payday arrives: hypothetical becomes real, template untouched.
      cubit.linkTransaction(
          nodeId: first.id,
          transactionId: 'plaid-pay-1',
          transactionAmount: 2132.10);
      expect(cubit.byId(first.id)?.money?.actualAmount, 2132.10);
      expect(cubit.byId(first.id)?.money?.status, MoneyStatus.paid);
      expect(cubit.byId('pay')?.money?.targetAmount, 2100);
    });

    test('solvency finds the first negative spot', () {
      final nodes = [
        node('rent',
            schedule: ScheduleFacet(
                due: DateTime(2026, 10, 1), isFixed: true),
            money: const MoneyFacet(
                targetAmount: 900,
                direction: MoneyDirection.spend,
                isFixed: true)),
        node('pay',
            schedule: ScheduleFacet(due: DateTime(2026, 10, 2)),
            money: const MoneyFacet(
                targetAmount: 800, direction: MoneyDirection.income)),
      ];
      final broke = simulateSolvency(
          all: nodes,
          startingBalance: 500,
          from: DateTime(2026, 9, 12));
      expect(broke.staysNonNegative, isFalse);
      expect(broke.firstNegativeDate, DateTime(2026, 10, 1));
      final fine = simulateSolvency(
          all: nodes,
          startingBalance: 5000,
          from: DateTime(2026, 9, 12));
      expect(fine.staysNonNegative, isTrue);
    });

    test('fixed contract segment + estimate tail coexist', () {
      final cubit = NodeCubit();
      cubit.addNode(node('housing-fixed',
          schedule: ScheduleFacet(
              due: DateTime(2026, 9, 1), isFixed: true),
          money: const MoneyFacet(
              targetAmount: 900,
              direction: MoneyDirection.spend,
              isFixed: true)));
      cubit.addNode(node('housing-est',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 1)),
          money: const MoneyFacet(
              targetAmount: 950, direction: MoneyDirection.spend)));
      expect(cubit.byId('housing-fixed')?.money?.isFixed, isTrue);
      expect(cubit.byId('housing-est')?.money?.isFixed, isFalse);
      expect(cubit.byId('housing-est')?.schedule?.isFixed, isFalse);
    });
  });

  group('estimate calibration', () {
    test('planned vs actual per template, outliers flagged', () {
      final day = DateTime(2026, 9, 12, 9);
      final all = [
        node('hw-template'),
        node('i1',
            instanceOfId: 'hw-template',
            parents: ['hw-template'],
            schedule: ScheduleFacet(
                start: day, end: day.add(const Duration(minutes: 60))),
            actualStart: day,
            actualEnd: day.add(const Duration(minutes: 70))),
        node('i2',
            instanceOfId: 'hw-template',
            parents: ['hw-template'],
            schedule: ScheduleFacet(
                start: day, end: day.add(const Duration(minutes: 60))),
            actualStart: day,
            actualEnd: day.add(const Duration(minutes: 120))),
      ];
      final stats = estimateStatsForTemplate('hw-template', all);
      expect(stats.count, 2);
      expect(stats.medianPlanned, 60);
      expect(stats.outlierNodeIds, ['i2']);
    });
  });

  group('tracking', () {
    test('single active timer; stop records actuals', () {
      final cubit = NodeCubit();
      cubit.addNode(node('a'));
      cubit.addNode(node('b'));
      final t0 = DateTime(2026, 9, 12, 9);
      cubit.startTracking('a', now: t0);
      cubit.startTracking('b', now: t0.add(const Duration(minutes: 5)));
      expect(cubit.byId('a')?.isTracking, isFalse);
      expect(cubit.byId('a')?.hasReported, isTrue);
      expect(cubit.byId('b')?.isTracking, isTrue);
      cubit.stopTracking('b',
          now: t0.add(const Duration(minutes: 35)));
      expect(cubit.byId('b')?.reportedDuration, const Duration(minutes: 30));
    });
  });

  group('legacy importers', () {
    test('goal / task / budget / expense / rule import without loss', () {
      final cubit = NodeCubit();
      final goalId = cubit.importGoal(Goal(
        id: 'g1',
        title: 'Food month',
        type: GoalType.financial,
        startDate: DateTime(2026, 9, 1),
        deadline: DateTime(2026, 9, 30),
        targetAmount: 400,
        period: TimeScale.monthly,
        showInTasks: true,
      ));
      expect(cubit.byId(goalId)?.money?.targetAmount, 400);
      expect(cubit.byId(goalId)?.hasDue, isTrue);

      final taskId = cubit.importTask(Task(
        id: 't1',
        title: 'Essay',
        due: DateTime(2026, 9, 15),
        sourceEventId: 'evt-1',
        classId: 'eng',
      ));
      expect(cubit.byId(taskId)?.isHomework, isTrue);

      final budgetId = cubit.importBudget(Budget(
        id: 'b1',
        name: 'Food',
        category: 'food',
        goalAmount: 400,
        period: TimeScale.monthly,
        startDate: DateTime(2026, 9, 1),
      ));
      expect(cubit.byId(budgetId)?.isTemplate, isTrue);

      final expenseId = cubit.importExpense(Expense(
        id: 'x1',
        name: 'Groceries',
        amount: -62.40,
        date: DateTime(2026, 9, 12),
      ));
      expect(
          cubit.byId(expenseId)?.money?.targetAmount, closeTo(62.4, 0.001));

      final ruleId = cubit.importRecurringRule(RecurringRule(
        id: 'r1',
        name: 'Paycheck',
        amount: 2100,
        frequency: TimeScale.biweekly,
        startDate: DateTime(2026, 9, 18),
      ));
      expect(cubit.byId(ruleId)?.money?.direction, MoneyDirection.income);
    });
  });

  group('persistence', () {
    test('round-trips all facets', () {
      final full = Node(
        id: 'full',
        title: 'Full',
        notes: 'notes',
        parentIds: const ['p'],
        status: NodeStatus.done,
        completedAt: DateTime(2026, 9, 12),
        createdAt: DateTime(2026, 9, 1),
        schedule: ScheduleFacet(
            due: DateTime(2026, 9, 30),
            start: DateTime(2026, 9, 12, 9),
            end: DateTime(2026, 9, 12, 10),
            isFixed: true),
        money: const MoneyFacet(
            targetAmount: 400,
            direction: MoneyDirection.spend,
            status: MoneyStatus.projected,
            period: TimeScale.monthly,
            isRecurring: true,
            autoRollover: true,
            rolloverAmount: 10,
            isFixed: false,
            linkedTransactionIds: ['tx1']),
        effort: const EffortFacet(targetMinutes: 60),
        recurrence:
            const NodeRecurrence(frequency: TimeScale.daily),
        rule: const RuleFacet(kind: NodeRuleKind.homeworkAhead),
        instanceOfId: 'tmpl',
        overriddenFields: const {'money.targetAmount'},
      );
      expect(Node.fromJson(full.toJson()), full);
    });

    test('unknown enums fall back; corrupt entries skipped', () {
      final full = node('a',
          schedule: ScheduleFacet(due: DateTime(2026, 9, 30)),
          money:
              const MoneyFacet(targetAmount: 10));
      final bad = full.toJson()
        ..['status'] = 'renamed'
        ..['money'] = {'direction': 'renamed', 'targetAmount': 10};
      expect(Node.fromJson(bad).status, NodeStatus.open);
      expect(Node.fromJson(bad).money?.direction, MoneyDirection.spend);

      final cubit = NodeCubit();
      final restored = cubit.fromJson({
        'nodes': [full.toJson(), {'id': 42}, 'nope', {'title': 'no-id'}],
      });
      expect(restored?.map((n) => n.id), ['a']);
    });

    test('pre-facet payloads load with empty facets', () {
      final cubit = NodeCubit();
      final legacy = {
        'id': 'old',
        'title': 'Old',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      };
      final restored = cubit.fromJson({
        'nodes': [legacy]
      });
      expect(restored?.single.schedule, isNull);
      expect(restored?.single.money, isNull);
      expect(restored?.single.parentIds, isEmpty);
    });
  });

  group('feed import', () {
    const canvas = Feed(
      id: 'canvas',
      name: 'Canvas',
      url: 'https://x.test/f.ics',
      kind: FeedKind.canvas,
    );

    test('canvas assignments become nodes, sessions do not', () {
      final cubit = NodeCubit();
      final now = DateTime.now();
      final a = PlannerEvent(
        id: 'hw:canvas:a1',
        subject: 'Exit Quiz [STAT 230-002]',
        start: DateTime(2030, 1, 1, 9),
        end: DateTime(2030, 1, 1, 10),
        feedId: 'canvas',
        sourceUid: 'event-assignment-1',
        classLabel: 'STAT 230-002',
      );
      final session = PlannerEvent(
        id: 'hw:canvas:s1',
        subject: 'Lecture',
        start: DateTime(2030, 1, 1, 9),
        end: DateTime(2030, 1, 1, 10),
        feedId: 'canvas',
        sourceUid: 'event-session-1',
      );
      expect(isNodeCandidate(a, canvas, now), isTrue);
      expect(isNodeCandidate(session, canvas, now), isFalse);
      cubit.importFromFeed([a, session], canvas);
      expect(cubit.byId('hw:canvas:a1')?.sourceEventId, 'hw:canvas:a1');
      expect(cubit.byId('hw:canvas:s1'), isNull);
      // Re-import preserves completion.
      cubit.toggleDone('hw:canvas:a1');
      cubit.importFromFeed([a], canvas);
      expect(cubit.byId('hw:canvas:a1')?.isDone, isTrue);
      // Feed removal cleans its nodes.
      cubit.removeImportedNodesFor('canvas');
      expect(cubit.byId('hw:canvas:a1'), isNull);
    });

    test('learning suite commentary is not an assignment', () {
      expect(
          looksLikeLearningSuiteAssignment('England', 'England discussion notes'),
          isFalse);
      expect(looksLikeLearningSuiteAssignment('Homework 5', 'Solve 1-10'), isTrue);
      expect(looksLikeLearningSuiteAssignment('Quiz 1', null), isTrue);
    });
  });

  group('event links', () {
    PlannerEvent event(String id) => PlannerEvent(
          id: id,
          subject: 'Event $id',
          start: DateTime(2026, 9, 12, 9),
          end: DateTime(2026, 9, 12, 10),
        );

    test('personal link round-trips and mirrors completion', () {
      final cubit = NodeCubit();
      final id = cubit.upsertLinkedNodeForEvent(event('evt:1'));
      expect(cubit.byId(id)?.calendarEventId, 'evt:1');
      expect(cubit.byId(id)?.schedule?.due, DateTime(2026, 9, 12, 9));
      cubit.setDoneForEvent('evt:1',
          done: true, completedAt: DateTime(2026, 9, 12, 11));
      expect(cubit.byId(id)?.isDone, isTrue);
      cubit.setFailedForEvent('evt:1', true);
      expect(cubit.byId(id)?.status, NodeStatus.failed);
      cubit.removeNodesForEvent('evt:1');
      expect(cubit.byId(id), isNull);
    });

    test('feed shadow uses the event id', () {
      final cubit = NodeCubit();
      cubit.ensureNodeForFeedEvent(PlannerEvent(
        id: 'evt:2',
        subject: 'Physics HW',
        start: DateTime(2026, 9, 12, 9),
        end: DateTime(2026, 9, 12, 10),
        feedId: 'f1',
        classLabel: 'Physics',
      ));
      final shadow = cubit.byId('evt:2');
      expect(shadow?.sourceEventId, 'evt:2');
      expect(shadow?.classLabel, 'Physics');
    });
  });

  group('tracking selection', () {
    test('recording + neighbours split as before', () {
      final now = DateTime(2026, 9, 12, 10);
      final nodes = [
        node('rec',
            schedule: ScheduleFacet(
              start: DateTime(2026, 9, 12, 9),
              end: DateTime(2026, 9, 12, 11),
            )),
        node('later',
            schedule: ScheduleFacet(
              start: DateTime(2026, 9, 12, 12),
              end: DateTime(2026, 9, 12, 13),
            )),
        node('plain',
            schedule: ScheduleFacet(due: DateTime(2026, 9, 13))),
      ];
      final sel = selectNodeTracking(nodes, now);
      expect(sel.current.map((n) => n.id), ['rec']);
      expect(sel.next.map((n) => n.id), ['later']);
      expect(sel.unscheduled.map((n) => n.id), ['plain']);
    });
  });

  group('legacy migration', () {
    test('importPayloads adopts goals, tasks, budgets, expenses, rules', () {
      final cubit = NodeCubit();
      final made = NodeLegacyMigration.importPayloads(
        cubit,
        goals: [
          Goal(
            id: 'g1',
            title: 'Goal',
            type: GoalType.checklist,
            startDate: DateTime(2026, 1, 1),
            deadline: DateTime(2026, 12, 31),
          ).toJson(),
        ],
        tasks: [
          Task(id: 't1', title: 'Task', due: DateTime(2026, 9, 15)).toJson(),
        ],
        budgets: [
          Budget(
            id: 'b1',
            name: 'Food',
            category: 'food',
            goalAmount: 400,
            period: TimeScale.monthly,
            startDate: DateTime(2026, 9, 1),
          ).toJson(),
        ],
        expenses: [
          Expense(
            id: 'x1',
            name: 'Groceries',
            amount: -62.40,
            date: DateTime(2026, 9, 12),
          ).toJson(),
        ],
        rules: [
          RecurringRule(
            id: 'r1',
            name: 'Pay',
            amount: 2100,
            frequency: TimeScale.biweekly,
            startDate: DateTime(2026, 9, 18),
          ).toJson(),
        ],
      );
      expect(made, 5);
      expect(cubit.byId('node:g1'), isNotNull);
      expect(cubit.byId('node:t1')?.hasDue, isTrue);
      expect(cubit.byId('node:b1')?.isTemplate, isTrue);
      expect(cubit.byId('node:x1')?.money?.targetAmount, closeTo(62.4, 0.001));
      expect(cubit.byId('node:r1')?.money?.direction, MoneyDirection.income);
      // Idempotent reruns.
      expect(
          NodeLegacyMigration.importPayloads(
            cubit,
            goals: [
              Goal(
                id: 'g1',
                title: 'Goal',
                type: GoalType.checklist,
                startDate: DateTime(2026, 1, 1),
                deadline: DateTime(2026, 12, 31),
              ).toJson(),
            ],
          ),
          0);
    });
  });
}
