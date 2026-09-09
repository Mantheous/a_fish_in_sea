import 'package:a_fish_in_sea/common/undo/change_record.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/goals/bloc/goal_cubit.dart';
import 'package:a_fish_in_sea/goals/bloc/tag_cubit.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/goals/model/tag.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
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
        taskCubit: TaskCubit(),
        icalService: IcalService(),
        googleService: GoogleCalendarService(
          baseUrl: () => '',
          userId: () => 'test',
        ),
        proxyBase: () => '',
      );

  group('restore tolerates corrupt entries', () {
    test('TaskCubit keeps valid tasks', () {
      final cubit = TaskCubit();
      final good =
          const Task(id: 't1', title: 'Read').toJson();
      final restored = cubit.fromJson(_withCorrupt('tasks', good));
      expect(restored?.map((t) => t.id), ['t1']);
    });

    test('TaskCubit loads pre-tracking tasks and bad tracking dates', () {
      final cubit = TaskCubit();
      final legacy = const Task(id: 'old', title: 'Read').toJson()
        ..remove('plannedStart')
        ..remove('plannedEnd')
        ..remove('actualStart')
        ..remove('actualEnd')
        ..remove('timerStartedAt')
        ..remove('failed');
      final restoredLegacy = cubit.fromJson({
        'tasks': [legacy],
      });
      expect(restoredLegacy?.single.failed, isFalse);
      expect(restoredLegacy?.single.isTracking, isFalse);
      final corrupt = const Task(id: 'bad', title: 'Read').toJson()
        ..['plannedStart'] = 'not-a-date'
        ..['timerStartedAt'] = 'not-a-date';
      final restoredCorrupt = cubit.fromJson({
        'tasks': [corrupt],
      });
      expect(restoredCorrupt?.map((t) => t.id), ['bad']);
      expect(restoredCorrupt?.single.hasPlanned, isFalse);
      expect(restoredCorrupt?.single.isTracking, isFalse);
    });

    test('TaskCubit loads pre-assignee tasks and skips bad assignees', () {
      final cubit = TaskCubit();
      final legacy = const Task(id: 'old', title: 'Read').toJson()
        ..remove('assignees');
      final restoredLegacy = cubit.fromJson({
        'tasks': [legacy],
      });
      expect(restoredLegacy?.single.assignees, isEmpty);
      final corrupt = const Task(id: 'bad', title: 'Read').toJson()
        ..['assignees'] = [
          {
            'id': 'people/1',
            'displayName': 'Amy',
            'email': 'amy@test.com',
          },
          {'id': 42},
          'not-a-map',
          {'displayName': ''},
        ];
      final restoredCorrupt = cubit.fromJson({
        'tasks': [corrupt],
      });
      expect(restoredCorrupt?.single.assignees.map((a) => a.id), ['people/1']);
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

    test('FeedCubit keeps valid feeds', () {
      final cubit = makeFeedCubit();
      const good = Feed(id: 'f1', name: 'Class', url: 'https://x.test/f.ics');
      final restored = cubit.fromJson(_withCorrupt('feeds', good.toJson()));
      expect(restored?.map((f) => f.id), ['f1']);
    });

    test('ExpenseCubit keeps valid expenses', () {
      final cubit = ExpenseCubit();
      final good = Expense(
        id: 'x1',
        name: 'Food',
        amount: -12.5,
        date: _day,
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('expenses', good));
      expect(restored?.map((e) => e.id), ['x1']);
    });

    test('BudgetCubit keeps valid budgets', () {
      final cubit = BudgetCubit();
      final good = Budget(
        id: 'b1',
        name: 'Food',
        category: 'food',
        goalAmount: 400,
        period: TimeScale.monthly,
        startDate: _day,
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('budgets', good));
      expect(restored?.map((b) => b.id), ['b1']);
    });

    test('RecurringRulesCubit keeps valid rules', () {
      final cubit = RecurringRulesCubit();
      final good = RecurringRule(
        id: 'r1',
        name: 'Rent',
        amount: -800,
        frequency: TimeScale.monthly,
        startDate: _day,
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('rules', good));
      expect(restored?.map((r) => r.id), ['r1']);
    });

    test('TransactionsCubit keeps valid transactions', () {
      final cubit = TransactionsCubit();
      final good = Transaction(
        id: 'tx1',
        accountId: 'a1',
        amount: -5.0,
        date: _day,
        name: 'Coffee',
      ).toJson();
      final restored =
          cubit.fromJson(_withCorrupt('transactions', good));
      expect(restored?.map((t) => t.id), ['tx1']);
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

    test('GoalCubit keeps valid goals, loads pre-tag goals', () {
      final cubit = GoalCubit();
      final good = Goal(
        id: 'g1',
        title: 'Get an A',
        type: GoalType.checklist,
        tagIds: const ['intellectual'],
        startDate: _day,
        deadline: _day.add(const Duration(days: 30)),
        showInTasks: true,
      ).toJson();
      final restored = cubit.fromJson(_withCorrupt('goals', good));
      expect(restored?.map((g) => g.id), ['g1']);
      final legacy = Map<String, dynamic>.from(good)..remove('tagIds');
      final restoredLegacy = cubit.fromJson({
        'goals': [legacy],
      });
      expect(restoredLegacy?.single.tagIds, isEmpty);
    });

    test('TagCubit keeps valid tags', () {
      final cubit = TagCubit();
      const good = GoalTag(id: 't1', name: 'Intellectual');
      final restored = cubit.fromJson(_withCorrupt('tags', good.toJson()));
      expect(restored?.map((t) => t.id), ['t1']);
    });

    test('UndoCubit keeps valid records', () {
      final cubit = UndoCubit();
      final good = const ChangeRecord(entries: [
        StateSnapshot(cubitId: 'TaskCubit', before: {}, after: {}),
      ]).toJson();
      final restored = cubit.fromJson(_withCorrupt('undoStack', good));
      expect(restored?.undoStack.length, 1);
    });

    test('applyJson with garbage does not throw', () {
      final cubit = TaskCubit();
      expect(() => cubit.applyJson({'tasks': 'not-a-list'}), returnsNormally);
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
      );
      expect(PlannerEvent.fromJson(event.toJson()), event);
      const feed = Feed(id: 'f1', name: 'Class', url: 'https://x.test/f.ics');
      expect(Feed.fromJson(feed.toJson()), feed);
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
  });
}
