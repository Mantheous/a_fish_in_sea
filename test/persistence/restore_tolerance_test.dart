import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/fitness/fitness_models.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/color_prefs.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

final _day = DateTime(2026, 9, 6, 9);

Map<String, dynamic> _withCorrupt(String key, Map<String, dynamic> good) => {
      key: [good, {'id': 42}, 'not-a-map'],
    };

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  FeedCubit makeFeedCubit() => FeedCubit(
        calendarCubit: CalendarCubit(),
        nodeCubit: NodeCubit(),
        icalService: IcalService(),
        googleService: GoogleCalendarService(
          baseUrl: () => '',
          userId: () => 'test',
        ),
        proxyBase: () => '',
      );

  group('restore tolerates corrupt entries', () {
    test('AssignmentEstimatesCubit keeps valid learned rows', () {
      final cubit = AssignmentEstimatesCubit();
      final good = AssignmentTypeEffort(
        feedId: 'math290',
        templateKey: 'video quiz',
        samples: 4,
        totalMinutes: 180,
        minutes: const [30, 45, 60, 45],
        startMinutes: const [19 * 60, 19 * 60, 18 * 60, 19 * 60],
        minMinutes: 30,
        maxMinutes: 60,
        updatedAt: DateTime(2026, 10, 1),
      );
      final restored = cubit.fromJson(_withCorrupt('efforts', good.toJson()));
      expect(restored, hasLength(1));
      expect(restored!.single.groupKey, 'math290|video quiz');
      expect(restored.single.estimateMinutes, 45);
      expect(restored.single.preferredStartMinute, 19 * 60);
    });

    test('AssignmentEstimatesCubit starts empty with no stored payload', () {
      // The learned index is derived data: no stored payload must mean
      // "nothing learned yet", never "refuse to boot".
      final cubit = AssignmentEstimatesCubit();
      expect(cubit.fromJson({}), isNull);
      expect(cubit.fromJson({'efforts': []}), isEmpty);
      expect(cubit.fromJson({'efforts': ['nope', 42, {}]}), isEmpty);
    });

    test('AssignmentRule payloads without estimateMinutes still load', () {
      final rule = AssignmentRule(
        id: 'r1',
        feedId: 'math290',
        templateKey: 'video quiz',
        displayName: 'Video Quiz',
        dueOffsetDays: -2,
        estimateMinutes: 45,
        createdAt: DateTime(2026, 10, 1),
      ).toJson();
      // The payload the app wrote before expected-time existed.
      rule.remove('estimateMinutes');
      final loaded = AssignmentRule.fromJson(rule);
      expect(loaded.estimateMinutes, isNull);
      expect(loaded.dueOffsetDays, -2);
      expect(loaded.id, 'r1');
    });

    test('CalendarCubit keeps valid events', () {
      final cubit = CalendarCubit();
      final good = PlannerEvent(
        id: 'e1',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('events', good));
      expect(restored?.map((e) => e.id), ['e1']);
    });

    test('CalendarCubit loads pre-tracking events and bad tracking dates', () {
      final cubit = CalendarCubit();
      final legacy = PlannerEvent(
        id: 'old',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
      ).toJson()
        ..remove('actualStart')
        ..remove('actualEnd')
        ..remove('timerStartedAt')
        ..remove('failed');
      final restoredLegacy = cubit.fromJson({
        'events': [legacy],
      });
      expect(restoredLegacy?.single.failed, isFalse);
      expect(restoredLegacy?.single.isTracking, isFalse);
      final corrupt = PlannerEvent(
        id: 'bad',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
      ).toJson()
        ..['actualStart'] = 'not-a-date'
        ..['timerStartedAt'] = 'not-a-date';
      final restoredCorrupt = cubit.fromJson({
        'events': [corrupt],
      });
      expect(restoredCorrupt?.map((e) => e.id), ['bad']);
      expect(restoredCorrupt?.single.actualStart, isNull);
      expect(restoredCorrupt?.single.isTracking, isFalse);
    });

    test('CalendarCubit loads pre-reminder events and bad reminders', () {
      final cubit = CalendarCubit();
      final legacy = PlannerEvent(
        id: 'old',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
      ).toJson()
        ..remove('reminderMinutesBefore');
      final restoredLegacy = cubit.fromJson({
        'events': [legacy],
      });
      expect(restoredLegacy?.single.reminderMinutesBefore, isNull);
      final corrupt = PlannerEvent(
        id: 'bad',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
      ).toJson()
        ..['reminderMinutesBefore'] = 'soon';
      final restoredCorrupt = cubit.fromJson({
        'events': [corrupt],
      });
      expect(restoredCorrupt?.map((e) => e.id), ['bad']);
      expect(restoredCorrupt?.single.reminderMinutesBefore, isNull);
    });

    test('FeedCubit keeps valid feeds', () {
      final cubit = makeFeedCubit();
      const good = Feed(id: 'f1', name: 'Class', url: 'https://x.test/f.ics');
      final restored = cubit.fromJson(_withCorrupt('feeds', good.toJson()));
      expect(restored?.map((f) => f.id), ['f1']);
    });

    test('CalendarVisibilityCubit keeps valid ids, drops garbage', () {
      final cubit = CalendarVisibilityCubit();
      final restored = cubit.fromJson(const {
        'hiddenIds': ['gcal:a', 42, '', null, 'group:google'],
      });
      expect(restored?.hiddenIds, {'gcal:a', 'group:google'});
      expect(cubit.fromJson({})?.hiddenIds, isEmpty);
      expect(
        cubit.fromJson(const {'hiddenIds': 'not-a-list'})?.hiddenIds,
        isEmpty,
      );
    });

    test('legacy finance payloads still parse for node import', () {
      // Retired cubits are gone; their on-disk format must still parse so
      // NodeLegacyMigration can adopt the data. Corrupt rows are skipped.
      final expenses = [
        Expense(id: 'x1', name: 'Food', amount: -12.5, date: _day).toJson(),
        {'id': 42},
        'not-a-map',
      ];
      final parsedExpenses = <Expense>[];
      for (final item in expenses) {
        if (item is! Map) continue;
        try {
          parsedExpenses.add(
              Expense.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {}
      }
      expect(parsedExpenses.map((e) => e.id), ['x1']);
      final budget = Budget(
        id: 'b1',
        name: 'Food',
        category: 'food',
        goalAmount: 400,
        period: TimeScale.monthly,
        startDate: _day,
      );
      expect(Budget.fromJson(budget.toJson()), budget);
      final rule = RecurringRule(
        id: 'r1',
        name: 'Rent',
        amount: -800,
        frequency: TimeScale.monthly,
        startDate: _day,
      );
      expect(RecurringRule.fromJson(rule.toJson()), rule);
    });

    test('TransactionsCubit keeps valid transactions', () {
      final cubit = TransactionsCubit();
      final good = Transaction(
        id: 'tx1',
        accountId: 'a1',
        amount: -5.0,
        date: _day,
        name: 'Coffee',
        pendingTransactionId: 'pending_tx0',
      ).toJson();
      final restored =
          cubit.fromJson(_withCorrupt('transactions', good));
      expect(restored?.map((t) => t.id), ['tx1']);
      expect(restored?.single.pendingTransactionId, 'pending_tx0');
    });

    test('transaction node links round-trip; pre-node payloads load', () {
      // Assigned + unassigned (reset) transactions must survive a restore.
      final assigned = Transaction(
        id: 'tx1',
        accountId: 'a1',
        amount: -62.40,
        date: _day,
        name: 'Groceries',
        assignedNodeId: 'node:food',
      );
      expect(Transaction.fromJson(assigned.toJson()), assigned);
      // Payloads written before node assignment existed carry no key.
      final preNode = assigned.toJson()..remove('assignedNodeId');
      expect(Transaction.fromJson(preNode).assignedNodeId, isNull);
      // A node paid by a transaction, and one reset after unlink, load too.
      final paid = Node(
        id: 'n1',
        title: 'Food',
        createdAt: _day,
        money: const MoneyFacet(
          targetAmount: 62.40,
          actualAmount: 62.40,
          status: MoneyStatus.paid,
          period: TimeScale.monthly,
          linkedTransactionIds: ['tx1'],
        ),
      );
      expect(Node.fromJson(paid.toJson()), paid);
      final reset = Node(
        id: 'n2',
        title: 'Old',
        createdAt: _day,
        money: const MoneyFacet(
          targetAmount: 62.40,
          status: MoneyStatus.projected,
        ),
      );
      expect(Node.fromJson(reset.toJson()), reset);
      final cubit = NodeCubit();
      final restored = cubit.fromJson({
        'nodes': [paid.toJson(), reset.toJson()],
      });
      expect(restored?.map((n) => n.id), ['n1', 'n2']);
    });

    test('PlacesCubit keeps valid places', () {
      final cubit = PlacesCubit();
      const good = Place(id: 'p1', name: 'Home', lat: 1.0, lng: 2.0);
      final restored = cubit.fromJson(_withCorrupt('places', good.toJson()));
      expect(restored?.map((p) => p.id), ['p1']);
    });

    test('TrackingCubit keeps valid points', () {
      final cubit = TrackingCubit();
      final good = TrackedPoint(
        id: 'tp1',
        timestamp: _day,
        lat: 1.0,
        lng: 2.0,
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('points', good));
      expect(restored?.points.map((p) => p.id), ['tp1']);
    });

    test('ReportingCubit keeps valid entries', () {
      final cubit = ReportingCubit();
      final good = ReportedEntry(
        id: 're1',
        title: 'Class',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
        status: ReportStatus.attended,
      ).toJson();
      final restored = cubit.fromJson({
        'days': {
          '2026-09-06': [good, {'id': 42}],
          'broken-day': 'not-a-list',
        },
      });
      expect(restored?['2026-09-06']?.map((e) => e.id), ['re1']);
      expect(restored?.containsKey('broken-day'), isFalse);
    });

    test('legacy goal payloads import into nodes without tags', () {
      final cubit = NodeCubit();
      final good = Goal(
        id: 'g1',
        title: 'Get an A',
        type: GoalType.checklist,
        tagIds: const ['intellectual'],
        startDate: _day,
        deadline: _day.add(const Duration(days: 30)),
        showInTasks: true,
      ).toJson();
      final id = cubit.importGoal(Goal.fromJson(good));
      expect(cubit.byId(id)?.title, 'Get an A');
      expect(cubit.byId(id)?.hasDue, isTrue);
    });

    test('NodeCubit keeps valid nodes, tolerates corrupt + pre-facet data',
        () {
      final cubit = NodeCubit();
      final good = Node(
        id: 'n1',
        title: 'Run',
        createdAt: _day,
        schedule: ScheduleFacet(due: _day),
        money: const MoneyFacet(targetAmount: 10),
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('nodes', good));
      expect(restored?.map((n) => n.id), ['n1']);
      final legacy = Map<String, dynamic>.from(good)
        ..remove('schedule')
        ..remove('money')
        ..remove('anki')
        ..remove('parentIds');
      final restoredLegacy = cubit.fromJson({
        'nodes': [legacy],
      });
      expect(restoredLegacy?.single.schedule, isNull);
      expect(restoredLegacy?.single.money, isNull);
      expect(restoredLegacy?.single.anki, isNull);
      expect(restoredLegacy?.single.parentIds, isEmpty);
    });

    test('NodeCubit tolerates corrupt anki facets, keeps the node', () {
      final cubit = NodeCubit();
      final good = Node(
        id: 'n9',
        title: 'Memorize',
        createdAt: _day,
        anki: const AnkiFacet(targetReviews: 50, deckName: 'Japanese'),
      ).toJson();
      final restored = cubit.fromJson({
        'nodes': [
          good,
          {...good, 'id': 'n10', 'anki': 'garbage'},
          {...good, 'id': 'n11', 'anki': {'targetReviews': 'lots'}},
        ],
      });
      expect(restored?.map((n) => n.id), ['n9', 'n10', 'n11']);
      expect(restored?[0].anki?.targetReviews, 50);
      expect(restored?[1].anki, isNull);
      expect(restored?[2].anki, isNull);
    });

    test('NodeCubit loads pre-flag nodes as bounded', () {
      final cubit = NodeCubit();
      final preFlag = Node(
        id: 'n2',
        title: 'Serve others',
        createdAt: _day,
      ).toJson()
        ..remove('isUnbounded');
      final restored = cubit.fromJson({
        'nodes': [preFlag],
      });
      expect(restored?.single.isUnbounded, isFalse);
      final unbounded = Node(
        id: 'n3',
        title: 'Serve others',
        createdAt: _day,
        isUnbounded: true,
      );
      expect(Node.fromJson(unbounded.toJson()), unbounded);
    });

    test('NodeCubit loads pre-favorite nodes as not favorite', () {
      final cubit = NodeCubit();
      final preFavorite = Node(
        id: 'n5',
        title: 'Run',
        createdAt: _day,
      ).toJson()
        ..remove('isFavorite');
      final restored = cubit.fromJson({
        'nodes': [preFavorite],
      });
      expect(restored?.single.isFavorite, isFalse);
      final corrupt = Map<String, dynamic>.from(preFavorite)
        ..['id'] = 'n6'
        ..['isFavorite'] = 'yes';
      final restoredCorrupt = cubit.fromJson({
        'nodes': [corrupt],
      });
      expect(restoredCorrupt?.single.isFavorite, isFalse);
      final starred = Node(
        id: 'n7',
        title: 'Starred',
        createdAt: _day,
        isFavorite: true,
      );
      expect(Node.fromJson(starred.toJson()), starred);
      final restoredStarred = cubit.fromJson({
        'nodes': [starred.toJson()],
      });
      expect(restoredStarred?.single.isFavorite, isTrue);
    });

    test('NodeCubit loads pre-fitness nodes as plain non-workouts', () {
      final cubit = NodeCubit();
      final preFitness = Node(
        id: 'n4',
        title: 'Sleep 8h',
        createdAt: _day,
        fitness: const FitnessFacet(
          metric: FitnessMetric.sleepMinutes,
          targetValue: 480,
        ),
        isWorkout: true,
      ).toJson()
        ..remove('fitness')
        ..remove('isWorkout');
      final restored = cubit.fromJson({
        'nodes': [preFitness],
      });
      expect(restored?.single.fitness, isNull);
      expect(restored?.single.isWorkout, isFalse);
      final corrupt = Map<String, dynamic>.from(preFitness)
        ..['fitness'] = {'metric': 'renamed-value', 'targetValue': 60};
      final restoredCorrupt = cubit.fromJson({
        'nodes': [corrupt],
      });
      expect(restoredCorrupt?.single.fitness?.metric,
          FitnessMetric.activityMinutes);
    });

    test('fitness provider tolerates old and unknown values', () {
      final cubit = NodeCubit();
      // Payload written by the old Garmin scaffold: stays garmin, never
      // silently rewritten to the new connector on load.
      final legacy = Node(
        id: 'n5',
        title: 'Run 30 min',
        createdAt: _day,
        fitness: const FitnessFacet(
          provider: FitnessProvider.garmin,
          metric: FitnessMetric.activityMinutes,
          targetValue: 30,
        ),
      ).toJson();
      expect(
        cubit.fromJson({
          'nodes': [legacy],
        })?.single.fitness?.provider,
        FitnessProvider.garmin,
      );
      // Unknown provider strings fall back instead of throwing.
      final unknown = Map<String, dynamic>.from(legacy)
        ..['fitness'] = {
          'metric': 'activityMinutes',
          'targetValue': 30,
          'provider': 'renamed-watch',
        };
      expect(
        cubit.fromJson({
          'nodes': [unknown],
        })?.single.fitness?.provider,
        FitnessProvider.strava,
      );
    });

    test('applyJson with garbage does not throw', () {
      final cubit = NodeCubit();
      expect(() => cubit.applyJson({'nodes': 'not-a-list'}), returnsNormally);
      expect(cubit.state, isEmpty);
    });
  });

  group('writes round-trip cleanly', () {
    test('planner models', () {
      final task = Task(
        id: 't1',
        title: 'Read',
        plannedStart: _day,
        plannedEnd: _day.add(const Duration(hours: 1)),
        actualStart: _day.add(const Duration(minutes: 5)),
        actualEnd: _day.add(const Duration(minutes: 50)),
        failed: true,
        assignees: const [
          TaskAssignee(
            id: 'people/1',
            displayName: 'Amy',
            email: 'amy@test.com',
            placeId: 'home-amy',
          ),
        ],
      );
      expect(Task.fromJson(task.toJson()), task);
      const assignee = TaskAssignee(id: 'people/2', displayName: 'Rory');
      expect(TaskAssignee.fromJson(assignee.toJson()), assignee);
      final event = PlannerEvent(
        id: 'e1',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
        actualStart: _day.add(const Duration(minutes: 5)),
        actualEnd: _day.add(const Duration(minutes: 50)),
        timerStartedAt: _day.add(const Duration(minutes: 2)),
        failed: true,
        reminderMinutesBefore: 30,
      );
      expect(PlannerEvent.fromJson(event.toJson()).toJson(), event.toJson());
      const feed = Feed(id: 'f1', name: 'Class', url: 'https://x.test/f.ics');
      expect(Feed.fromJson(feed.toJson()), feed);
      final visibility = CalendarVisibilityCubit();
      visibility.setLeafVisible('gcal:a', false);
      final visibilityRestored =
          visibility.fromJson(visibility.toJson(visibility.state));
      expect(visibilityRestored?.hiddenIds, {'gcal:a'});
    });

    test('finance models', () {
      final expense = Expense(
        id: 'x1',
        name: 'Food',
        amount: -12.5,
        date: _day,
      );
      expect(Expense.fromJson(expense.toJson()), expense);
      final budget = Budget(
        id: 'b1',
        name: 'Food',
        category: 'food',
        goalAmount: 400,
        period: TimeScale.monthly,
        startDate: _day,
      );
      expect(Budget.fromJson(budget.toJson()), budget);
      final rule = RecurringRule(
        id: 'r1',
        name: 'Rent',
        amount: -800,
        frequency: TimeScale.monthly,
        startDate: _day,
      );
      expect(RecurringRule.fromJson(rule.toJson()), rule);
      final txn = Transaction(
        id: 'tx1',
        accountId: 'a1',
        amount: -5.0,
        date: _day,
        name: 'Coffee',
        pendingTransactionId: 'pending_tx0',
      );
      expect(Transaction.fromJson(txn.toJson()), txn);
    });

    test('reporting models', () {
      const place = Place(id: 'p1', name: 'Home', lat: 1.0, lng: 2.0);
      expect(Place.fromJson(place.toJson()), place);
      final point = TrackedPoint(
        id: 'tp1',
        timestamp: _day,
        lat: 1.0,
        lng: 2.0,
      );
      expect(TrackedPoint.fromJson(point.toJson()), point);
      final entry = ReportedEntry(
        id: 're1',
        title: 'Class',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
        status: ReportStatus.attended,
      );
      expect(ReportedEntry.fromJson(entry.toJson()), entry);
    });

    test('unified nodes round-trip', () {
      final node = Node(
        id: 'n1',
        title: 'Food month',
        parentIds: const ['groceries'],
        createdAt: _day,
        schedule: ScheduleFacet(due: _day, isFixed: true),
        money: const MoneyFacet(
          targetAmount: 400,
          direction: MoneyDirection.spend,
          period: TimeScale.monthly,
          isRecurring: true,
        ),
        effort: const EffortFacet(targetMinutes: 30),
        anki: const AnkiFacet(targetReviews: 50, deckName: 'Japanese'),
      );
      expect(Node.fromJson(node.toJson()), node);
    });

    test('timer fields tolerate pre-offset strings and UTC round-trips', () {
      // Payloads written before timer fields carried an offset parse to
      // the same instant; newly written payloads carry the offset.
      final nodeJson = Node(
        id: 'n1',
        title: 'Run',
        createdAt: _day,
        timerStartedAt: _day,
        actualStart: _day,
        actualEnd: _day.add(const Duration(minutes: 30)),
      ).toJson();
      expect((nodeJson['timerStartedAt'] as String).endsWith('Z'), isTrue);
      final legacyNode = Map<String, dynamic>.from(nodeJson)
        ..['timerStartedAt'] = _day.toIso8601String()
        ..['actualEnd'] = _day.add(const Duration(minutes: 30)).toIso8601String();
      expect(Node.fromJson(legacyNode).timerStartedAt, _day);

      final taskJson = Task(
        id: 't1',
        title: 'Read',
        timerStartedAt: _day,
        actualStart: _day,
        actualEnd: _day.add(const Duration(minutes: 30)),
      ).toJson();
      expect((taskJson['timerStartedAt'] as String).endsWith('Z'), isTrue);
      final legacyTask = Map<String, dynamic>.from(taskJson)
        ..['timerStartedAt'] = _day.toIso8601String();
      expect(Task.fromJson(legacyTask).timerStartedAt, _day);
      expect(Task.fromJson(taskJson).timerStartedAt, _day);

      final eventJson = PlannerEvent(
        id: 'e1',
        subject: 'Lecture',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
        timerStartedAt: _day,
      ).toJson();
      expect((eventJson['timerStartedAt'] as String).endsWith('Z'), isTrue);
      final legacyEvent = Map<String, dynamic>.from(eventJson)
        ..['timerStartedAt'] = _day.toIso8601String();
      expect(PlannerEvent.fromJson(legacyEvent).timerStartedAt, _day);
    });

    test('unknown enum values fall back instead of throwing', () {
      final rule = RecurringRule(
        id: 'r1',
        name: 'Rent',
        amount: -800,
        frequency: TimeScale.monthly,
        startDate: _day,
      );
      final ruleJson = rule.toJson()..['frequency'] = 'renamed-value';
      expect(
        RecurringRule.fromJson(ruleJson).frequency,
        TimeScale.monthly,
      );
      final entry = ReportedEntry(
        id: 're1',
        title: 'Class',
        start: _day,
        end: _day.add(const Duration(hours: 1)),
        status: ReportStatus.attended,
      );
      final entryJson = entry.toJson()..['status'] = 'renamed-value';
      expect(
        ReportedEntry.fromJson(entryJson).status,
        ReportStatus.partial,
      );
    });

    test('undo after a simulated pull round-trips both items (issue #55)', () {
      final undo = UndoCubit();
      final cubit = NodeCubit();
      cubit.addNode(Node(id: 't1', title: 'original', createdAt: _day));
      cubit.updateNode(cubit.byId('t1')!.copyWith(title: 'edited'));
      // Background pull: merged state applied without an undo record.
      final pulled = Node(id: 't2', title: 'from sync', createdAt: _day);
      cubit.applyJson({
        'nodes': [
          ...((cubit.toJson(cubit.state)['nodes']) as List),
          pulled.toJson(),
        ],
      });
      undo.undo();
      expect(cubit.byId('t1')?.title, 'original');
      expect(cubit.byId('t2')?.title, 'from sync');
      // The merged result persists and restores intact.
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.map((n) => n.id), ['t1', 't2']);
      expect(restored?.firstWhere((n) => n.id == 't1').title, 'original');
      expect(restored?.firstWhere((n) => n.id == 't2').title, 'from sync');
    });

    test('SettingsCubit keeps valid color choices around corrupt entries', () {
      final cubit = SettingsCubit();
      final restored = cubit.fromJson({
        'snapMinutes': 20,
        'colors': {
          'homework': 0xFF6A8FB5,
          'personal': 'not-a-color',
          'classes': {
            'STAT 230-002': 0xFFB2706B,
            'WRTG 150': [1, 2],
          },
          'applyToCalendar': false,
        },
      });
      expect(restored, isNotNull);
      expect(restored!.snapMinutes, 20);
      expect(restored.colors.homework, 0xFF6A8FB5);
      expect(restored.colors.personal, isNull);
      expect(restored.colors.classes, {'STAT 230-002': 0xFFB2706B});
      expect(restored.colors.applyToCalendar, isFalse);
      expect(restored.colors.applyToTaskLists, isTrue);

      // A colors blob of the wrong type cannot wipe the other settings.
      final wrongType = cubit.fromJson({
        'defaultEventFeedId': 'feed-1',
        'colors': 'garbage',
      });
      expect(wrongType?.defaultEventFeedId, 'feed-1');
      expect(wrongType?.colors, const ColorPrefs());
    });
  });
}
