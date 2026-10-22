import 'package:a_fish_in_sea/calendar/month_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for https://github.com/Mantheous/a_fish_in_sea/issues/62.
///
/// The month grid used to step days with fixed 24-hour [Duration]s, which
/// breaks across daylight-saving transitions: March (23-hour spring-forward
/// day) produced 41 cells and crashed on `sublist`, and November (25-hour
/// fall-back day) duplicated the DST Sunday and shifted later dates.
///
/// NOTE: the DST path only executes in a DST timezone. Run under e.g.
/// `TZ=America/Denver` (the loop host default) to exercise it; under UTC
/// there is no transition so the old code would vacuously pass.
void main() {
  group('buildMonthCalendarWeeks DST regression (refs #62)', () {
    void expectSoundGrid(List<List<DateTime>> weeks) {
      final allDays = weeks.expand((w) => w).toList();
      for (final week in weeks) {
        expect(week.length, 7);
        expect(week.first.weekday, DateTime.monday);
        expect(week.last.weekday, DateTime.sunday);
      }
      for (final day in allDays) {
        expect(day.hour, 0, reason: 'expected midnight for $day');
        expect(day.minute, 0);
        expect(day.second, 0);
      }
      for (var i = 1; i < allDays.length; i++) {
        final prev = allDays[i - 1];
        final cur = allDays[i];
        final expected = DateTime(prev.year, prev.month, prev.day + 1);
        expect(
          DateTime(cur.year, cur.month, cur.day),
          expected,
          reason: 'day $i should be the next calendar day after $prev',
        );
      }
      final keys = allDays
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
      expect(keys.length, allDays.length, reason: 'no duplicated dates');
    }

    test('March 2026 grid has 42 cells with correct dates', () {
      final weeks = buildMonthCalendarWeeks(DateTime(2026, 3, 1));
      final allDays = weeks.expand((w) => w).toList();

      expect(allDays.length, 42);
      expectSoundGrid(weeks);

      // Grid: Mon Feb 23 2026 .. Sun Apr 5 2026.
      expect(allDays.first, DateTime(2026, 2, 23));
      expect(allDays.last, DateTime(2026, 4, 5));

      // Spring-forward Sunday (Mar 8 2026 in US zones) exactly once.
      final dstSundays =
          allDays.where((d) => d.year == 2026 && d.month == 3 && d.day == 8);
      expect(dstSundays.length, 1);
      expect(dstSundays.single.hour, 0);
    });

    test('November 2026 grid has 42 cells with correct dates', () {
      final weeks = buildMonthCalendarWeeks(DateTime(2026, 11, 1));
      final allDays = weeks.expand((w) => w).toList();

      expect(allDays.length, 42);
      expectSoundGrid(weeks);

      // Grid: Mon Oct 26 2026 .. Sun Dec 6 2026.
      expect(allDays.first, DateTime(2026, 10, 26));
      expect(allDays.last, DateTime(2026, 12, 6));

      // Fall-back Sunday (Nov 1 2026 in US zones) exactly once, at midnight.
      final dstSundays =
          allDays.where((d) => d.year == 2026 && d.month == 11 && d.day == 1);
      expect(dstSundays.length, 1);
      expect(dstSundays.single.hour, 0);
    });

    testWidgets('MonthCalendar pumps the current month without throwing',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MonthCalendar(entries: [], budgets: []),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MonthCalendar), findsOneWidget);
    });
  });
}
