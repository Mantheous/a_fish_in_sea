import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/task_date_range.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:flutter_test/flutter_test.dart';

Node _node(String id, {DateTime? due}) {
  final noon = due == null ? null : DateTime(due.year, due.month, due.day, 12);
  return Node(
    id: id,
    title: id,
    createdAt: DateTime(2026, 10, 1),
    schedule: due == null ? null : ScheduleFacet(due: noon),
  );
}

void main() {
  // Monday 2026-10-12, noon.
  final monday = DateTime(2026, 10, 12, 12);
  final overdue = DateTime(2026, 10, 10, 9);
  final today = DateTime(2026, 10, 12, 9);
  final tomorrow = DateTime(2026, 10, 13, 9);
  final later = DateTime(2026, 10, 20, 9);

  group('TaskDateRange matching', () {
    test('bounds are inclusive, day-precision', () {
      const range =
          TaskDateRange(startOffsetDays: 0, endOffsetDays: 1);
      expect(range.matches(today, monday), isTrue);
      expect(range.matches(tomorrow, monday), isTrue);
      expect(range.matches(overdue, monday), isFalse);
      expect(range.matches(later, monday), isFalse);
      // Times within the same days still match.
      expect(range.matches(DateTime(2026, 10, 13, 23, 59), monday), isTrue);
    });

    test('null start includes overdue, null end never cuts off', () {
      const openEnded =
          TaskDateRange(startOffsetDays: null, endOffsetDays: 1);
      expect(openEnded.matches(overdue, monday), isTrue);
      expect(openEnded.matches(today, monday), isTrue);
      expect(openEnded.matches(tomorrow, monday), isTrue);
      expect(openEnded.matches(later, monday), isFalse);
      const openStarted =
          TaskDateRange(startOffsetDays: 0, endOffsetDays: null);
      expect(openStarted.matches(overdue, monday), isFalse);
      expect(openStarted.matches(later, monday), isTrue);
      const unbounded = TaskDateRange();
      expect(unbounded.matches(overdue, monday), isTrue);
      expect(unbounded.matches(later, monday), isTrue);
      expect(unbounded.isUnbounded, isTrue);
    });

    test('undated needs the showUndated toggle', () {
      const range =
          TaskDateRange(startOffsetDays: 0, endOffsetDays: 8);
      expect(range.matches(null, monday), isFalse);
      expect(range.matches(null, monday, showUndated: true), isTrue);
    });

    test('start past end matches nothing dated', () {
      const bad =
          TaskDateRange(startOffsetDays: 5, endOffsetDays: 1);
      expect(bad.isValid, isFalse);
      expect(bad.matches(today, monday), isFalse);
      expect(bad.matches(later, monday), isFalse);
      expect(
          const TaskDateRange(startOffsetDays: 1, endOffsetDays: 1).isValid,
          isTrue);
    });
  });

  group('TaskDateRange labels', () {
    test('relative descriptions', () {
      expect(describeTaskDateRange(const TaskDateRange()),
          'Any date');
      expect(
          describeTaskDateRange(const TaskDateRange(
              startOffsetDays: null, endOffsetDays: 1)),
          'Due tomorrow or earlier');
      expect(
          describeTaskDateRange(const TaskDateRange(
              startOffsetDays: null, endOffsetDays: 0)),
          'Due today or earlier');
      expect(
          describeTaskDateRange(const TaskDateRange(
              startOffsetDays: 0, endOffsetDays: 8)),
          'Due today – in 8 days');
      expect(
          describeTaskDateRange(const TaskDateRange(
              startOffsetDays: 1, endOffsetDays: 9)),
          'Due tomorrow – in 9 days');
      expect(
          describeTaskDateRange(const TaskDateRange(
              startOffsetDays: null, endOffsetDays: null)),
          'Any date');
    });

    test('resolved dates for the current day', () {
      expect(
          resolvedTaskDateRange(
              const TaskDateRange(startOffsetDays: 0, endOffsetDays: 8),
              monday),
          'Oct 12 – Oct 20');
      expect(
          resolvedTaskDateRange(
              const TaskDateRange(
                  startOffsetDays: null, endOffsetDays: 1),
              monday),
          'On or before Oct 13');
      expect(
          resolvedTaskDateRange(
              const TaskDateRange(
                  startOffsetDays: 1, endOffsetDays: null),
              monday),
          'Oct 13 or later');
    });
  });

  group('TaskDateRange JSON tolerance', () {
    test('round-trips', () {
      const range =
          TaskDateRange(startOffsetDays: null, endOffsetDays: 1);
      expect(TaskDateRange.tryParse(range.toJson()), range);
      expect(TaskDateRange.tryParse(const TaskDateRange().toJson()),
          const TaskDateRange());
    });

    test('garbage is safe, out-of-range clamps', () {
      expect(TaskDateRange.tryParse(null), isNull);
      expect(TaskDateRange.tryParse('nope'), isNull);
      final wrongTypes = TaskDateRange.tryParse(const {
        'startOffsetDays': 'soon',
        'endOffsetDays': 1.5,
      });
      expect(wrongTypes?.startOffsetDays, isNull);
      expect(wrongTypes?.endOffsetDays, isNull);
      final clamped = TaskDateRange.tryParse(const {
        'startOffsetDays': -9999,
        'endOffsetDays': 9999,
      });
      expect(clamped?.startOffsetDays, taskDateRangeMinOffset);
      expect(clamped?.endOffsetDays, taskDateRangeMaxOffset);
    });
  });

  group('TaskFilter custom date', () {
    test('tomorrow-or-earlier keeps overdue, today, and tomorrow', () {
      const filter = TaskFilter(
        id: 't',
        name: 't',
        date: TaskFilterDate.custom,
        customRange: TaskDateRange(startOffsetDays: null, endOffsetDays: 1),
      );
      expect(filter.matches(_node('over', due: overdue), monday), isTrue);
      expect(filter.matches(_node('today', due: today), monday), isTrue);
      expect(filter.matches(_node('tom', due: tomorrow), monday), isTrue);
      expect(filter.matches(_node('later', due: later), monday), isFalse);
      expect(filter.matches(_node('u'), monday), isFalse);
      expect(
          filter
              .copyWith(showUndated: true)
              .matches(_node('u'), monday),
          isTrue);
    });

    test('null range behaves like an unbounded window', () {
      const filter = TaskFilter(
          id: 't', name: 't', date: TaskFilterDate.custom);
      expect(filter.matches(_node('over', due: overdue), monday), isTrue);
      expect(filter.matches(_node('later', due: later), monday), isTrue);
      expect(
          describeTaskFilter(filter), contains('Any date'));
    });

    test('round-trips through JSON', () {
      const filter = TaskFilter(
        id: 'custom:1',
        name: 'Sunday + 8',
        date: TaskFilterDate.custom,
        customRange: TaskDateRange(startOffsetDays: 1, endOffsetDays: 9),
      );
      expect(TaskFilter.tryParse(filter.toJson()), filter);
    });

    test('corrupt range drops safely, filter survives', () {
      final wrongTypes = TaskFilter.tryParse(const {
        'id': 'x',
        'name': 'x',
        'date': 'custom',
        'customRange': {'startOffsetDays': 'soon'},
      });
      expect(wrongTypes?.customRange,
          const TaskDateRange(startOffsetDays: null, endOffsetDays: null));
      final garbage = TaskFilter.tryParse(const {
        'id': 'x',
        'name': 'x',
        'date': 'custom',
        'customRange': 'next-week-ish',
      });
      expect(garbage?.customRange, isNull);
      // Old payloads without the key still load.
      final legacy = TaskFilter.tryParse(const {
        'id': 'x',
        'name': 'x',
        'date': 'today',
      });
      expect(legacy?.customRange, isNull);
      expect(legacy?.date, TaskFilterDate.today);
    });
  });
}
