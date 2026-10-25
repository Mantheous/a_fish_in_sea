import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/task_date_range.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:a_fish_in_sea/planner/model/task_range_bound.dart';
import 'package:a_fish_in_sea/planner/view/task_selector_form.dart';
import 'package:flutter/material.dart';
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

TaskRangeBound off(int v) => TaskRangeBound.offset(v);
const unb = TaskRangeBound.unbounded;

void main() {
  // Monday 2026-10-12, noon.
  final monday = DateTime(2026, 10, 12, 12);
  // Saturday 2026-10-17, noon — the "next Monday that's not this week"
  // is Oct 19.
  final saturday = DateTime(2026, 10, 17, 12);
  final overdue = DateTime(2026, 10, 10, 9);
  final today = DateTime(2026, 10, 12, 9);
  final tomorrow = DateTime(2026, 10, 13, 9);
  final later = DateTime(2026, 10, 20, 9);

  group('TaskRangeBound resolve', () {
    test('unbounded never pins, offsets count days', () {
      expect(unb().resolve(monday), isNull);
      expect(off(0).resolve(monday), DateTime(2026, 10, 12));
      expect(off(1).resolve(monday), DateTime(2026, 10, 13));
      expect(off(-2).resolve(monday), DateTime(2026, 10, 10));
    });

    test('weekday anchors to Monday-start weeks', () {
      // Saturday Oct 17: this week runs Mon Oct 12 – Sun Oct 18.
      const nextMonday =
          TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: 1);
      expect(nextMonday.resolve(saturday), DateTime(2026, 10, 19));
      const thisMonday =
          TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: 0);
      expect(thisMonday.resolve(saturday), DateTime(2026, 10, 12));
      const thisSunday =
          TaskRangeBound.weekday(weekday: DateTime.sunday, weeksOut: 0);
      expect(thisSunday.resolve(saturday), DateTime(2026, 10, 18));
      // Monday itself: "Monday of this week" is today.
      expect(thisMonday.resolve(monday), DateTime(2026, 10, 12));
      expect(
          const TaskRangeBound.weekday(weekday: DateTime.sunday, weeksOut: 2)
              .resolve(monday),
          DateTime(2026, 11, 1));
    });

    test('offset and weekday bounds land on calendar days across DST', () {
      // Fall-back Sunday Nov 1 2026 (25 hours long).
      final fallBack = DateTime(2026, 11, 1, 12);
      const tomorrowOnly = TaskDateRange(
        start: TaskRangeBound.offset(1),
        end: TaskRangeBound.offset(1),
      );
      expect(tomorrowOnly.startDate(fallBack), DateTime(2026, 11, 2));
      expect(tomorrowOnly.endDate(fallBack), DateTime(2026, 11, 2));
      expect(
          tomorrowOnly.matches(DateTime(2026, 11, 2, 0, 1), fallBack), isTrue);
      expect(tomorrowOnly.matches(DateTime(2026, 11, 2, 23, 59), fallBack),
          isTrue);
      expect(tomorrowOnly.matches(DateTime(2026, 11, 1, 23, 59), fallBack),
          isFalse);

      // Spring-forward Sunday Mar 8 2026 (23 hours long).
      final spring = DateTime(2026, 3, 8, 12);
      expect(tomorrowOnly.startDate(spring), DateTime(2026, 3, 9));
      expect(tomorrowOnly.matches(DateTime(2026, 3, 9, 0, 30), spring), isTrue);
      expect(tomorrowOnly.matches(DateTime(2026, 3, 8, 23, 59), spring),
          isFalse);

      // Monday-of-next-week is still the Monday after the transition.
      const nextMonday =
          TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: 1);
      expect(nextMonday.resolve(fallBack), DateTime(2026, 11, 2));
      expect(nextMonday.resolve(spring), DateTime(2026, 3, 9));
    });

    test('weekday anchors can reach last week', () {
      // Saturday Oct 17: Sunday of last week is Oct 11 — the Sunday
      // before this Monday-start week, unreachable when weeksOut
      // floored at 0. Sunday of this week (Oct 18) looked a week ahead.
      const lastSunday =
          TaskRangeBound.weekday(weekday: DateTime.sunday, weeksOut: -1);
      expect(lastSunday.resolve(saturday), DateTime(2026, 10, 11));
      const lastMonday =
          TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: -1);
      expect(lastMonday.resolve(saturday), DateTime(2026, 10, 5));
      expect(
          const TaskRangeBound.weekday(weekday: DateTime.sunday, weeksOut: -2)
              .resolve(saturday),
          DateTime(2026, 10, 4));
      // The reported window: last Sunday through next Monday.
      const window = TaskDateRange(
        start: TaskRangeBound.weekday(
            weekday: DateTime.sunday, weeksOut: -1),
        end: TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: 1),
      );
      expect(window.startDate(saturday), DateTime(2026, 10, 11));
      expect(window.endDate(saturday), DateTime(2026, 10, 19));
      expect(window.matches(DateTime(2026, 10, 10, 9), saturday), isFalse);
      expect(window.matches(DateTime(2026, 10, 11, 9), saturday), isTrue);
      expect(window.matches(DateTime(2026, 10, 19, 9), saturday), isTrue);
      expect(window.matches(DateTime(2026, 10, 20, 9), saturday), isFalse);
      expect(describeTaskDateRange(window),
          'Due Sunday of last week – Monday of next week');
    });
  });

  group('TaskRangeBound describe + JSON', () {
    test('relative phrases', () {
      expect(off(0).describe(), 'today');
      expect(off(1).describe(), 'tomorrow');
      expect(off(-1).describe(), 'yesterday');
      expect(off(8).describe(), 'in 8 days');
      expect(off(-3).describe(), '3 days ago');
      expect(
          const TaskRangeBound.weekday(
                  weekday: DateTime.monday, weeksOut: 1)
              .describe(),
          'Monday of next week');
      expect(
          const TaskRangeBound.weekday(
                  weekday: DateTime.sunday, weeksOut: 0)
              .describe(),
          'Sunday of this week');
      expect(
          const TaskRangeBound.weekday(
                  weekday: DateTime.sunday, weeksOut: -1)
              .describe(),
          'Sunday of last week');
      expect(
          const TaskRangeBound.weekday(
                  weekday: DateTime.monday, weeksOut: -2)
              .describe(),
          'Monday of 2 weeks ago');
      expect(taskRangeWeekdayName(DateTime.friday), 'Friday');
    });

    test('round-trips, garbage falls back to unbounded', () {
      const bound = TaskRangeBound.weekday(
          weekday: DateTime.monday, weeksOut: 1);
      expect(TaskRangeBound.tryParse(bound.toJson()), bound);
      expect(TaskRangeBound.tryParse(off(3).toJson()), off(3));
      expect(TaskRangeBound.tryParse(unb().toJson()), unb());
      expect(TaskRangeBound.tryParse(null), isNull);
      expect(TaskRangeBound.tryParse('nope'), isNull);
      // Unknown kinds never narrow.
      expect(TaskRangeBound.tryParse(const {'kind': 'renamed'}),
          unb());
      expect(TaskRangeBound.tryParse(const {'kind': 'offset'}),
          unb());
      expect(
          TaskRangeBound.tryParse(
              const {'kind': 'offset', 'offsetDays': 'soon'}),
          unb());
      expect(
          TaskRangeBound.tryParse(const {
            'kind': 'weekday',
            'weekday': 'Monday',
            'weeksOut': 1
          }),
          unb());
      expect(
          TaskRangeBound.tryParse(const {
            'kind': 'weekday',
            'weekday': 8,
            'weeksOut': 1
          }),
          unb());
      // Out-of-range ints clamp.
      expect(
          TaskRangeBound.tryParse(
              const {'kind': 'offset', 'offsetDays': 9999}),
          off(taskDateRangeMaxOffset));
      expect(
          TaskRangeBound.tryParse(const {
            'kind': 'weekday',
            'weekday': DateTime.monday,
            'weeksOut': 9999
          }),
          const TaskRangeBound.weekday(
              weekday: DateTime.monday,
              weeksOut: taskRangeWeeksOutMax));
      // Negative weeksOut survives a round-trip and clamps, not zeroes.
      const lastSunday = TaskRangeBound.weekday(
          weekday: DateTime.sunday, weeksOut: -1);
      expect(TaskRangeBound.tryParse(lastSunday.toJson()), lastSunday);
      expect(
          TaskRangeBound.tryParse(const {
            'kind': 'weekday',
            'weekday': DateTime.monday,
            'weeksOut': -9999
          }),
          const TaskRangeBound.weekday(
              weekday: DateTime.monday,
              weeksOut: taskRangeWeeksOutMin));
    });
  });

  group('TaskDateRange matching', () {
    test('bounds are inclusive, day-precision', () {
      final range = TaskDateRange(start: off(0), end: off(1));
      expect(range.matches(today, monday), isTrue);
      expect(range.matches(tomorrow, monday), isTrue);
      expect(range.matches(overdue, monday), isFalse);
      expect(range.matches(later, monday), isFalse);
      // Times within the same days still match.
      expect(range.matches(DateTime(2026, 10, 13, 23, 59), monday), isTrue);
    });

    test('unbounded start includes overdue, unbounded end never cuts off',
        () {
      final openEnded =
          TaskDateRange(start: unb(), end: off(1));
      expect(openEnded.matches(overdue, monday), isTrue);
      expect(openEnded.matches(today, monday), isTrue);
      expect(openEnded.matches(tomorrow, monday), isTrue);
      expect(openEnded.matches(later, monday), isFalse);
      final openStarted =
          TaskDateRange(start: off(0), end: unb());
      expect(openStarted.matches(overdue, monday), isFalse);
      expect(openStarted.matches(later, monday), isTrue);
      const unbounded = TaskDateRange();
      expect(unbounded.matches(overdue, monday), isTrue);
      expect(unbounded.matches(later, monday), isTrue);
      expect(unbounded.isUnbounded, isTrue);
    });

    test('undated needs the showUndated toggle', () {
      final range = TaskDateRange(start: off(0), end: off(8));
      expect(range.matches(null, monday), isFalse);
      expect(range.matches(null, monday, showUndated: true), isTrue);
    });

    test('start past end matches nothing dated', () {
      final bad = TaskDateRange(start: off(5), end: off(1));
      expect(bad.isValidAt(monday), isFalse);
      expect(bad.matches(today, monday), isFalse);
      expect(bad.matches(later, monday), isFalse);
      expect(
          TaskDateRange(start: off(1), end: off(1)).isValidAt(monday),
          isTrue);
    });

    test('overdue through next Monday', () {
      // Saturday Oct 17: "the next Monday that's not this week" is Oct 19.
      const range = TaskDateRange(
        start: TaskRangeBound.unbounded(),
        end: TaskRangeBound.weekday(
            weekday: DateTime.monday, weeksOut: 1),
      );
      expect(
          range.matches(DateTime(2026, 10, 10, 9), saturday), isTrue);
      expect(
          range.matches(DateTime(2026, 10, 17, 9), saturday), isTrue);
      expect(
          range.matches(DateTime(2026, 10, 19, 9), saturday), isTrue);
      expect(
          range.matches(DateTime(2026, 10, 20, 9), saturday), isFalse);
      expect(
          range.matches(DateTime(2026, 10, 26, 9), saturday), isFalse);
      expect(
          describeTaskDateRange(range), 'Due Monday of next week or earlier');
      expect(resolvedTaskDateRange(range, saturday), 'On or before Oct 19');
    });
  });

  group('TaskDateRange labels', () {
    test('relative descriptions', () {
      expect(describeTaskDateRange(const TaskDateRange()), 'Any date');
      expect(
          describeTaskDateRange(
              TaskDateRange(start: unb(), end: off(1))),
          'Due tomorrow or earlier');
      expect(
          describeTaskDateRange(
              TaskDateRange(start: unb(), end: off(0))),
          'Due today or earlier');
      expect(
          describeTaskDateRange(
              TaskDateRange(start: off(0), end: off(8))),
          'Due today – in 8 days');
      expect(
          describeTaskDateRange(
              TaskDateRange(start: off(1), end: off(9))),
          'Due tomorrow – in 9 days');
      expect(
          describeTaskDateRange(TaskDateRange(
              start: off(1),
              end: const TaskRangeBound.weekday(
                  weekday: DateTime.sunday, weeksOut: 1))),
          'Due tomorrow – Sunday of next week');
    });

    test('resolved dates for the current day', () {
      expect(
          resolvedTaskDateRange(
              TaskDateRange(start: off(0), end: off(8)), monday),
          'Oct 12 – Oct 20');
      expect(
          resolvedTaskDateRange(
              TaskDateRange(start: unb(), end: off(1)), monday),
          'On or before Oct 13');
      expect(
          resolvedTaskDateRange(
              TaskDateRange(start: off(1), end: unb()), monday),
          'Oct 13 or later');
    });
  });

  group('TaskDateRange JSON tolerance', () {
    test('round-trips', () {
      final range = TaskDateRange(start: unb(), end: off(1));
      expect(TaskDateRange.tryParse(range.toJson()), range);
      expect(TaskDateRange.tryParse(const TaskDateRange().toJson()),
          const TaskDateRange());
      const anchored = TaskDateRange(
        start: TaskRangeBound.unbounded(),
        end: TaskRangeBound.weekday(
            weekday: DateTime.monday, weeksOut: 1),
      );
      expect(TaskDateRange.tryParse(anchored.toJson()), anchored);
    });

    test('pre-anchor payloads parse onto offset bounds', () {
      final legacy = TaskDateRange.tryParse(const {
        'startOffsetDays': null,
        'endOffsetDays': 1,
      });
      expect(
          legacy,
          TaskDateRange(start: unb(), end: off(1)));
      final clamped = TaskDateRange.tryParse(const {
        'startOffsetDays': -9999,
        'endOffsetDays': 9999,
      });
      expect(
          clamped,
          TaskDateRange(
              start: off(taskDateRangeMinOffset),
              end: off(taskDateRangeMaxOffset)));
      final wrongTypes = TaskDateRange.tryParse(const {
        'startOffsetDays': 'soon',
        'endOffsetDays': 1.5,
      });
      expect(wrongTypes, const TaskDateRange());
      expect(TaskDateRange.tryParse(null), isNull);
      expect(TaskDateRange.tryParse('nope'), isNull);
    });
  });

  group('weekday picker', () {
    testWidgets('offers last week for the start bound', (tester) async {
      var value = const TaskFilter(
        id: 't',
        name: 't',
        date: TaskFilterDate.custom,
        customRange: TaskDateRange(
          start: TaskRangeBound.weekday(
              weekday: DateTime.sunday, weeksOut: 0),
          end: TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: 1),
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TaskSelectorForm(
                value: value,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // From row: weekday dropdown first, weeks-out dropdown second.
      await tester.tap(find.byType(DropdownButton<int>).at(1));
      await tester.pumpAndSettle();
      expect(find.text('Last week'), findsWidgets);
      await tester.tap(find.text('Last week').last);
      await tester.pumpAndSettle();
      expect(value.customRange?.start,
          const TaskRangeBound.weekday(weekday: DateTime.sunday, weeksOut: -1));
      expect(value.customRange?.end,
          const TaskRangeBound.weekday(weekday: DateTime.monday, weeksOut: 1));
    });
  });

  group('TaskFilter custom date', () {
    test('tomorrow-or-earlier keeps overdue, today, and tomorrow', () {
      final filter = TaskFilter(
        id: 't',
        name: 't',
        date: TaskFilterDate.custom,
        customRange: TaskDateRange(start: unb(), end: off(1)),
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
        customRange: TaskDateRange(
          start: TaskRangeBound.offset(1),
          end: TaskRangeBound.offset(9),
        ),
      );
      expect(TaskFilter.tryParse(filter.toJson()), filter);
    });

    test('corrupt range drops safely, filter survives', () {
      final wrongTypes = TaskFilter.tryParse(const {
        'id': 'x',
        'name': 'x',
        'date': 'custom',
        'customRange': {
          'start': {'kind': 'offset', 'offsetDays': 'soon'},
        },
      });
      expect(wrongTypes?.customRange, const TaskDateRange());
      final garbage = TaskFilter.tryParse(const {
        'id': 'x',
        'name': 'x',
        'date': 'custom',
        'customRange': 'next-week-ish',
      });
      expect(garbage?.customRange, isNull);
      // Payloads without the key still load.
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
