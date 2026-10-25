import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:flutter_test/flutter_test.dart';

/// Calendar-day math must survive daylight-saving transitions.
///
/// Run under a DST zone (the loop host uses `TZ=America/Denver`) to
/// exercise the transition assertions; under UTC the helpers are still
/// verified for the ordinary case, but the old `Duration(days: n)` bugs
/// would be invisible.
void main() {
  group('localDay', () {
    test('keeps a local wall-clock date', () {
      expect(localDay(DateTime(2026, 10, 25, 23, 59)), DateTime(2026, 10, 25));
      expect(localDay(DateTime(2026, 10, 25, 0, 1)), DateTime(2026, 10, 25));
    });

    test('converts a UTC instant to the local calendar day', () {
      final utc = DateTime.utc(2026, 11, 2, 3); // Nov 1 evening in the US
      final local = utc.toLocal();
      expect(localDay(utc), DateTime(local.year, local.month, local.day));
      expect(localDay(utc).isUtc, isFalse);
    });
  });

  group('shiftLocalDay', () {
    test('always lands on local midnight of the target date', () {
      for (final start in [
        DateTime(2026, 3, 8), // US spring-forward Sunday
        DateTime(2026, 11, 1), // US fall-back Sunday
        DateTime(2026, 10, 30),
      ]) {
        final next = shiftLocalDay(start, 1);
        expect(next.hour, 0, reason: '$start → $next');
        expect(next.minute, 0);
        expect(localDayDistance(start, next), 1);
      }
    });

    test('stepping a week crosses both transitions without skipping', () {
      final spring = shiftLocalDay(DateTime(2026, 3, 2), 7);
      expect(spring, DateTime(2026, 3, 9));
      final fall = shiftLocalDay(DateTime(2026, 10, 26), 7);
      expect(fall, DateTime(2026, 11, 2));
    });
  });

  group('shiftByCalendarDays', () {
    test('keeps the wall-clock time across a fall-back transition', () {
      final due = DateTime(2026, 10, 30, 23, 59);
      expect(shiftByCalendarDays(due, 3), DateTime(2026, 11, 2, 23, 59));
      expect(shiftByCalendarDays(due, -2), DateTime(2026, 10, 28, 23, 59));
    });

    test('keeps UTC-ness for instant fields', () {
      final utc = DateTime.utc(2026, 10, 30, 23, 59);
      final shifted = shiftByCalendarDays(utc, 3);
      expect(shifted.isUtc, isTrue);
      expect(shifted, DateTime.utc(2026, 11, 2, 23, 59));
    });

    test('elapsed-time days would land on the wrong date in a DST zone', () {
      final start = DateTime(2026, 10, 30);
      final elapsed = start.add(const Duration(days: 3));
      final byCalendar = shiftByCalendarDays(start, 3);
      expect(byCalendar, DateTime(2026, 11, 2));
      if (start.timeZoneOffset == DateTime(2026, 11, 2).timeZoneOffset) {
        // UTC and other no-DST zones: both are correct.
        expect(elapsed, byCalendar);
      } else {
        // Fall-back zone: three 24-hour days end on Nov 1 at 23:00.
        expect(elapsed, isNot(byCalendar));
        expect(elapsed.day, 1);
      }
    });
  });

  group('localDayDistance', () {
    test('counts calendar days, not elapsed hours', () {
      expect(localDayDistance(DateTime(2026, 3, 8), DateTime(2026, 3, 9)), 1);
      expect(localDayDistance(DateTime(2026, 11, 1), DateTime(2026, 11, 2)), 1);
      expect(
        localDayDistance(DateTime(2026, 10, 12), DateTime(2026, 10, 15)),
        3,
      );
      expect(
        localDayDistance(DateTime(2026, 11, 2), DateTime(2026, 10, 30)),
        -3,
      );
    });

    test('ignores the time of day', () {
      expect(
        localDayDistance(
          DateTime(2026, 10, 12, 23, 59),
          DateTime(2026, 10, 13, 0, 1),
        ),
        1,
      );
    });
  });

  group('isSameLocalDay', () {
    test('compares calendar days, not instants', () {
      expect(
        isSameLocalDay(
          DateTime(2026, 10, 12, 0, 1),
          DateTime(2026, 10, 12, 23, 59),
        ),
        isTrue,
      );
      expect(
        isSameLocalDay(
          DateTime(2026, 10, 12, 23, 59),
          DateTime(2026, 10, 13, 0, 0),
        ),
        isFalse,
      );
    });
  });
}
