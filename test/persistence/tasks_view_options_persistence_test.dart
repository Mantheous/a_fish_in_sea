import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('TasksViewOptions persistence', () {
    test('round-trips filters, active id, and highlight', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      cubit.addFilter(const TaskFilter(
        id: 'custom:1',
        name: 'Physics week',
        date: TaskFilterDate.thisWeek,
        kind: TaskFilterKind.homework,
        classKeys: ['Physics'],
      ));
      cubit.setHighlightEnabled(true);
      cubit.setHighlightColor(0xFFFF9800);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);
    });

    test('legacy highlight + due-filter payloads migrate', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final restored = cubit.fromJson(const {
        'highlightDueThisWeek': true,
        'dueFilter': 'overdue',
      });
      expect(restored?.activeFilterId, 'overdue');
      expect(restored?.highlight.enabled, isTrue);
      expect(
        cubit.fromJson(const {'highlightDueThisWeek': true})?.activeFilterId,
        'all',
      );
      expect(
        cubit.fromJson(const {'dueFilter': 'renamed-value'})?.activeFilterId,
        'all',
      );
      expect(
        cubit.fromJson(const {'dueFilter': 42}),
        const TasksViewOptionsState(),
      );
    });

    test('corrupt entries fall back per-item', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final restored = cubit.fromJson(const {
        'filters': [
          {'id': 'good', 'name': 'Good', 'date': 'today'},
          {'id': 42},
          'not-a-map',
        ],
        'activeFilterId': 'missing',
        'highlight': 'not-a-map',
      });
      expect(restored?.filters.map((f) => f.id), ['all', 'good']);
      expect(restored?.activeFilterId, 'all');
      expect(restored?.highlight, const TaskHighlight());
    });
  });
}
