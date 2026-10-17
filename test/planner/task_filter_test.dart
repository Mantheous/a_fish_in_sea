import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node _node(
  String id, {
  DateTime? due,
  NodeStatus status = NodeStatus.open,
  bool homework = false,
  bool planned = false,
  bool template = false,
}) {
  final noon = due == null ? null : DateTime(due.year, due.month, due.day, 12);
  return Node(
    id: id,
    title: id,
    createdAt: DateTime(2026, 10, 1),
    status: status,
    schedule: due == null && !planned
        ? null
        : ScheduleFacet(
            due: noon,
            start: planned ? noon : null,
            end: planned && noon != null
                ? noon.add(const Duration(hours: 1))
                : null,
          ),
    sourceEventId: homework ? 'evt:$id' : null,
    classLabel: homework ? 'Physics' : null,
    recurrence: template
        ? const NodeRecurrence(frequency: TimeScale.weekly)
        : null,
  );
}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  // Monday 2026-10-12, noon. Week runs through Sunday 2026-10-18.
  final monday = DateTime(2026, 10, 12, 12);

  group('TaskFilter date windows', () {
    test('today is strict, overdue is strictly before today', () {
      final today = TaskFilter(
          id: 't', name: 't', date: TaskFilterDate.today);
      expect(today.matches(_node('a', due: DateTime(2026, 10, 12, 9)), monday),
          isTrue);
      expect(today.matches(_node('b', due: DateTime(2026, 10, 11, 9)), monday),
          isFalse);
      expect(today.matches(_node('c', due: DateTime(2026, 10, 13, 9)), monday),
          isFalse);
      final overdue = TaskFilter(
          id: 'o', name: 'o', date: TaskFilterDate.overdue);
      expect(
          overdue.matches(_node('b', due: DateTime(2026, 10, 11, 9)), monday),
          isTrue);
      expect(
          overdue.matches(_node('a', due: DateTime(2026, 10, 12, 9)), monday),
          isFalse);
    });

    test('tomorrow, thisWeek, next7Days', () {
      final tomorrow = TaskFilter(
          id: 't', name: 't', date: TaskFilterDate.tomorrow);
      expect(
          tomorrow.matches(_node('a', due: DateTime(2026, 10, 13, 9)), monday),
          isTrue);
      expect(
          tomorrow.matches(_node('b', due: DateTime(2026, 10, 12, 9)), monday),
          isFalse);
      final week = TaskFilter(
          id: 'w', name: 'w', date: TaskFilterDate.thisWeek);
      expect(week.matches(_node('sun', due: DateTime(2026, 10, 18, 9)), monday),
          isTrue);
      expect(week.matches(_node('mon', due: DateTime(2026, 10, 19, 9)), monday),
          isFalse);
      expect(week.matches(_node('past', due: DateTime(2026, 10, 11, 9)), monday),
          isFalse);
      final seven = TaskFilter(
          id: 's', name: 's', date: TaskFilterDate.next7Days);
      expect(seven.matches(_node('d6', due: DateTime(2026, 10, 18, 9)), monday),
          isTrue);
      expect(seven.matches(_node('d7', due: DateTime(2026, 10, 19, 9)), monday),
          isFalse);
    });

    test('undated needs its window or the showUndated toggle', () {
      final today = TaskFilter(
          id: 't', name: 't', date: TaskFilterDate.today);
      expect(today.matches(_node('u'), monday), isFalse);
      expect(
          today.copyWith(showUndated: true).matches(_node('u'), monday),
          isTrue);
      final undated = TaskFilter(
          id: 'u', name: 'u', date: TaskFilterDate.undated);
      expect(undated.matches(_node('u'), monday), isTrue);
      expect(
          undated.matches(_node('d', due: DateTime(2026, 10, 12, 9)), monday),
          isFalse);
      final all = TaskFilter(
          id: 'a', name: 'a', date: TaskFilterDate.all, showCompleted: true);
      expect(all.matches(_node('u'), monday), isTrue);
    });
  });

  group('TaskFilter status / kind / class / planning', () {
    test('done needs showCompleted, failed never matches', () {
      final today = TaskFilter(
          id: 't', name: 't', date: TaskFilterDate.today);
      final done = _node('d',
          due: DateTime(2026, 10, 12, 9), status: NodeStatus.done);
      expect(today.matches(done, monday), isFalse);
      expect(today.copyWith(showCompleted: true).matches(done, monday), isTrue);
      final failed = _node('f',
          due: DateTime(2026, 10, 12, 9), status: NodeStatus.failed);
      expect(
          today.copyWith(showCompleted: true).matches(failed, monday), isFalse);
    });

    test('kind narrows personal vs homework', () {
      final all = TaskFilter(
          id: 'a', name: 'a', date: TaskFilterDate.all, showCompleted: true);
      final hw = _node('h', homework: true);
      final personal = _node('p');
      expect(all.copyWith(kind: TaskFilterKind.homework).matches(hw, monday),
          isTrue);
      expect(
          all.copyWith(kind: TaskFilterKind.homework).matches(personal, monday),
          isFalse);
      expect(all.copyWith(kind: TaskFilterKind.personal).matches(hw, monday),
          isFalse);
    });

    test('classKeys restrict homework, personal passes through', () {
      final hw = TaskFilter(
          id: 'h',
          name: 'h',
          date: TaskFilterDate.all,
          showCompleted: true,
          kind: TaskFilterKind.homework,
          classKeys: const ['Physics']);
      expect(hw.matches(_node('a', homework: true), monday), isTrue);
      final chem = _node('b', homework: true).copyWith(classLabel: 'Chem');
      expect(hw.matches(chem, monday), isFalse);
      final both = hw.copyWith(kind: TaskFilterKind.both);
      expect(both.matches(_node('p'), monday), isTrue);
      expect(both.matches(chem, monday), isFalse);
    });

    test('planned narrows on calendar blocks', () {
      final all = TaskFilter(
          id: 'a', name: 'a', date: TaskFilterDate.all, showCompleted: true);
      final planned = _node('p',
          due: DateTime(2026, 10, 12, 9), planned: true);
      final unplanned = _node('u', due: DateTime(2026, 10, 12, 9));
      expect(
          all
              .copyWith(planned: TaskFilterPlanned.plannedOnly)
              .matches(planned, monday),
          isTrue);
      expect(
          all
              .copyWith(planned: TaskFilterPlanned.plannedOnly)
              .matches(unplanned, monday),
          isFalse);
      expect(
          all
              .copyWith(planned: TaskFilterPlanned.unplannedOnly)
              .matches(unplanned, monday),
          isTrue);
    });
  });

  group('TaskHighlight', () {
    test('matches open nodes in the window only', () {
      const hl = TaskHighlight(
          enabled: true, date: TaskHighlightDate.thisWeek);
      expect(hl.matches(_node('w', due: DateTime(2026, 10, 14, 9)), monday),
          isTrue);
      expect(
          hl.matches(
              _node('d',
                  due: DateTime(2026, 10, 14, 9), status: NodeStatus.done),
              monday),
          isFalse);
      expect(hl.matches(_node('past', due: DateTime(2026, 10, 11, 9)), monday),
          isFalse);
      expect(const TaskHighlight().matches(_node('w'), monday), isFalse);
    });
  });

  group('TaskFilter JSON tolerance', () {
    test('round-trips', () {
      const f = TaskFilter(
        id: 'custom:1',
        name: 'Physics week',
        date: TaskFilterDate.thisWeek,
        showCompleted: true,
        showUndated: true,
        kind: TaskFilterKind.homework,
        classKeys: ['Physics'],
        planned: TaskFilterPlanned.unplannedOnly,
      );
      expect(TaskFilter.tryParse(f.toJson()), f);
      const h = TaskHighlight(
          enabled: true,
          date: TaskHighlightDate.tomorrow,
          colorValue: 0xFFFF9800,
          hideMatching: true);
      expect(TaskHighlight.tryParse(h.toJson()), h);
    });

    test('garbage parses to null, unknown enums fall back', () {
      expect(TaskFilter.tryParse(null), isNull);
      expect(TaskFilter.tryParse('nope'), isNull);
      expect(TaskFilter.tryParse(const {'name': 'x'}), isNull);
      final renamed = TaskFilter.tryParse(const {
        'id': 'x',
        'name': 'x',
        'date': 'renamed-value',
        'kind': 'renamed-value',
        'planned': 'renamed-value',
      });
      expect(renamed?.date, TaskFilterDate.all);
      expect(renamed?.kind, TaskFilterKind.both);
      expect(renamed?.planned, TaskFilterPlanned.all);
      final wrongTypes = TaskFilter.tryParse(const {
        'id': 'x',
        'showCompleted': 'yes',
        'classKeys': ['ok', 42, '', null],
      });
      expect(wrongTypes?.showCompleted, isFalse);
      expect(wrongTypes?.classKeys, ['ok']);
      expect(TaskHighlight.tryParse(const {'colorValue': 'red'})?.colorValue,
          isNull);
      expect(TaskHighlight.tryParse(null), isNull);
    });
  });

  group('TasksViewOptionsCubit', () {
    test('defaults to All with highlight off', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      expect(cubit.state.activeFilterId, 'all');
      expect(cubit.state.activeFilter.isShowAll, isTrue);
      expect(cubit.state.highlight.enabled, isFalse);
      expect(cubit.state.hasActiveOptions, isFalse);
      expect(cubit.state.isFiltering, isFalse);
    });

    test('activate, add, update, delete, clear', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      cubit.setActiveFilter('today');
      expect(cubit.state.isFiltering, isTrue);
      expect(cubit.state.hasActiveOptions, isTrue);
      // Unknown ids are ignored.
      cubit.setActiveFilter('missing');
      expect(cubit.state.activeFilterId, 'today');

      final custom = TaskFilter(
          id: TaskFilter.newId(),
          name: 'Tomorrow',
          date: TaskFilterDate.tomorrow);
      cubit.addFilter(custom);
      expect(cubit.state.activeFilterId, custom.id);
      cubit.updateFilter(custom.copyWith(name: 'Renamed'));
      expect(cubit.state.activeFilter.name, 'Renamed');
      cubit.deleteFilter(custom.id);
      expect(cubit.state.activeFilterId, 'all');
      // The 'all' escape hatch cannot be deleted.
      cubit.deleteFilter('all');
      expect(cubit.state.filters.any((f) => f.id == 'all'), isTrue);

      cubit.setHighlightEnabled(true);
      expect(cubit.state.hasActiveOptions, isTrue);
      expect(cubit.state.isFiltering, isFalse);
      cubit.setHighlightHideMatching(true);
      expect(cubit.state.isFiltering, isTrue);
      cubit.clearAll();
      expect(cubit.state, const TasksViewOptionsState());
    });

    test('round-trips through JSON', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      cubit.setActiveFilter('overdue');
      cubit.setHighlightEnabled(true);
      cubit.setHighlightColor(0xFFFF9800);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);
    });

    test('legacy payloads map onto defaults', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final restored = cubit.fromJson(const {
        'highlightDueThisWeek': true,
        'dueFilter': 'today',
      });
      expect(restored?.activeFilterId, 'today');
      expect(restored?.highlight.enabled, isTrue);
      expect(restored?.highlight.date, TaskHighlightDate.thisWeek);
      expect(
          cubit.fromJson(const {'dueFilter': 'renamed-value'})?.activeFilterId,
          'all');
    });

    test('corrupt current payloads fall back per-item', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final restored = cubit.fromJson(const {
        'filters': [
          {'id': 'good', 'name': 'Good', 'date': 'today'},
          {'id': 42},
          'not-a-map',
          {'id': 'renamed', 'name': 'R', 'date': 'renamed-value'},
        ],
        'activeFilterId': 'missing',
        'highlight': {'enabled': 'yes'},
      });
      expect(restored?.filters.map((f) => f.id),
          containsAll(['all', 'good', 'renamed']));
      expect(restored?.activeFilterId, 'all');
      expect(restored?.highlight.enabled, isFalse);
    });
  });

  group('calendar-week window agreement (Sunday start)', () {
    // 2026-10-11 is a Sunday.
    final sunday = DateTime(2026, 10, 11, 12);
    final monday = DateTime(2026, 10, 12, 12);
    final saturday = DateTime(2026, 10, 17, 12);

    NodeCubit cubitWith(List<Node> nodes) {
      final cubit = NodeCubit();
      for (final n in nodes) {
        cubit.addNode(n);
      }
      return cubit;
    }

    test('Sunday looks forward to next Sunday inclusive', () {
      final cubit = cubitWith([
        _node('today', due: DateTime(2026, 10, 11, 9)),
        _node('sat', due: DateTime(2026, 10, 17, 9)),
        _node('sun', due: DateTime(2026, 10, 18, 9)),
        _node('mon', due: DateTime(2026, 10, 19, 9)),
        _node('past', due: DateTime(2026, 10, 10, 9)),
      ]);
      addTearDown(cubit.close);
      expect(
        cubit.dueThisWeekAt(sunday).map((n) => n.id),
        containsAll(['today', 'sat', 'sun']),
      );
      expect(cubit.dueThisWeekAt(sunday).map((n) => n.id),
          isNot(contains('mon')));
      // Overdue belongs to the past, not to this week.
      expect(cubit.dueThisWeekAt(sunday).map((n) => n.id),
          isNot(contains('past')));
    });

    test('Monday runs through Sunday, next Monday is out', () {
      final cubit = cubitWith([
        _node('sun', due: DateTime(2026, 10, 18, 9)),
        _node('mon', due: DateTime(2026, 10, 19, 9)),
      ]);
      addTearDown(cubit.close);
      expect(cubit.dueThisWeekAt(monday).map((n) => n.id), ['sun']);
    });

    test('Saturday covers just the weekend', () {
      final cubit = cubitWith([
        _node('wed', due: DateTime(2026, 10, 14, 9)),
        _node('sat', due: DateTime(2026, 10, 17, 9)),
        _node('sun', due: DateTime(2026, 10, 18, 9)),
        _node('mon', due: DateTime(2026, 10, 19, 9)),
      ]);
      addTearDown(cubit.close);
      expect(cubit.dueThisWeekAt(saturday).map((n) => n.id),
          containsAll(['sat', 'sun']));
      expect(cubit.dueThisWeekAt(saturday).map((n) => n.id),
          isNot(contains('wed')));
      expect(cubit.dueThisWeekAt(saturday).map((n) => n.id),
          isNot(contains('mon')));
    });

    test('done and template nodes never match the week', () {
      final cubit = cubitWith([
        _node('done',
            due: DateTime(2026, 10, 13, 9), status: NodeStatus.done),
        _node('tmpl', due: DateTime(2026, 10, 13, 9), template: true),
      ]);
      addTearDown(cubit.close);
      expect(cubit.dueThisWeekAt(monday), isEmpty);
    });

    test('dueToday is strict, overdue is strictly before today', () {
      final cubit = cubitWith([
        _node('over', due: DateTime(2026, 10, 10, 9)),
        _node('today', due: DateTime(2026, 10, 11, 9)),
        _node('tomorrow', due: DateTime(2026, 10, 12, 9)),
        _node('done-today',
            due: DateTime(2026, 10, 11, 9), status: NodeStatus.done),
      ]);
      addTearDown(cubit.close);
      expect(cubit.dueTodayAt(sunday).map((n) => n.id), ['today']);
      expect(cubit.overdueAt(sunday).map((n) => n.id), ['over']);
    });

    test('TaskFilter windows agree with the NodeCubit sets', () {
      final cubit = cubitWith([
        _node('over', due: DateTime(2026, 10, 10, 9)),
        _node('today', due: DateTime(2026, 10, 11, 9)),
        _node('sun', due: DateTime(2026, 10, 18, 9)),
        _node('mon', due: DateTime(2026, 10, 19, 9)),
        _node('done-today',
            due: DateTime(2026, 10, 11, 9), status: NodeStatus.done),
      ]);
      addTearDown(cubit.close);
      Set<String> matching(TaskFilter f) => {
            for (final n in cubit.state)
              if (f.matches(n, sunday)) n.id,
          };
      expect(
          matching(const TaskFilter(
              id: 't', name: 't', date: TaskFilterDate.today)),
          cubit.dueTodayAt(sunday).map((n) => n.id).toSet());
      expect(
          matching(const TaskFilter(
              id: 'o', name: 'o', date: TaskFilterDate.overdue)),
          cubit.overdueAt(sunday).map((n) => n.id).toSet());
      expect(
          matching(const TaskFilter(
              id: 'w', name: 'w', date: TaskFilterDate.thisWeek)),
          cubit.dueThisWeekAt(sunday).map((n) => n.id).toSet());
    });
  });
}
