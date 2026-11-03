import 'package:a_fish_in_sea/anki/anki_reports.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';

AnkiReviewDay _row(String day, String deck, int cards, {int? reviews}) =>
    AnkiReviewDay(
      day: DateTime.parse(day),
      deck: deck,
      cards: cards,
      reviews: reviews ?? cards,
    );

Node _goal(
  String id, {
  String? deck,
  TimeScale? period,
  int? customDays,
  int target = 100,
  int? actual,
  DateTime? createdAt,
}) => Node(
  id: id,
  title: id,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
  anki: AnkiFacet(
    deckName: deck,
    targetReviews: target,
    period: period,
    customPeriodDays: customDays,
    reviewsActual: actual,
  ),
);

void main() {
  final now = DateTime(2026, 11, 4, 12); // Wednesday

  group('period start', () {
    test('daily is today', () {
      expect(ankiPeriodStart(TimeScale.daily, now: now), DateTime(2026, 11, 4));
    });

    test('weekly honors the first day of week', () {
      expect(
        ankiPeriodStart(TimeScale.weekly, now: now, firstDayOfWeek: 1),
        DateTime(2026, 11, 2),
      );
      expect(
        ankiPeriodStart(TimeScale.weekly, now: now, firstDayOfWeek: 7),
        DateTime(2026, 11, 1),
      );
    });

    test('biweekly covers the current and previous week', () {
      expect(
        ankiPeriodStart(TimeScale.biweekly, now: now, firstDayOfWeek: 1),
        DateTime(2026, 10, 26),
      );
    });

    test('calendar periods start at their boundary', () {
      expect(
        ankiPeriodStart(TimeScale.monthly, now: now),
        DateTime(2026, 11, 1),
      );
      expect(
        ankiPeriodStart(TimeScale.quarterly, now: now),
        DateTime(2026, 10, 1),
      );
      expect(ankiPeriodStart(TimeScale.yearly, now: now), DateTime(2026, 1, 1));
    });

    test('custom periods step from the goal creation day', () {
      // Created Oct 1, 14-day blocks: Oct 1-14, Oct 15-28, Oct 29-Nov 11.
      expect(
        ankiPeriodStart(
          TimeScale.custom,
          customPeriodDays: 14,
          now: now,
          anchor: DateTime(2026, 10, 1),
        ),
        DateTime(2026, 10, 29),
      );
      // No anchor (a new unsaved goal): the current block starts today.
      expect(
        ankiPeriodStart(TimeScale.custom, customPeriodDays: 14, now: now),
        DateTime(2026, 11, 4),
      );
    });
  });

  test('deck matching includes subdecks and ignores case', () {
    expect(ankiDeckMatches(null, 'Anything'), isTrue);
    expect(ankiDeckMatches('  ', 'Anything'), isTrue);
    expect(ankiDeckMatches('Japanese', 'Japanese'), isTrue);
    expect(ankiDeckMatches('Japanese', 'Japanese::Vocab'), isTrue);
    expect(ankiDeckMatches('japanese', 'Japanese::Vocab'), isTrue);
    expect(ankiDeckMatches('Japanese', 'Japanese 2'), isFalse);
    expect(ankiDeckMatches('Japanese::Vocab', 'Japanese'), isFalse);
  });

  test('counts only the requested window and keeps hasData separate', () {
    final report = AnkiReportData(
      days: [
        _row('2026-10-20', 'Japanese', 5),
        _row('2026-11-02', 'Japanese', 3),
        _row('2026-11-03', 'Japanese::Vocab', 4, reviews: 6),
        _row('2026-11-04', 'Math', 9),
      ],
    );
    final count = ankiCountForFacet(
      deckName: 'Japanese',
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 4),
      report: report,
    );
    expect(count.hasData, isTrue);
    expect(count.cards, 7);
    expect(count.reviews, 9);
    expect(count.lastDay, DateTime(2026, 11, 3));

    final none = ankiCountForFacet(
      deckName: 'History',
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 4),
      report: report,
    );
    expect(none.hasData, isFalse);
    expect(none.cards, 0);
  });

  test('all-decks goals sum every reported deck', () {
    final report = AnkiReportData(
      days: [_row('2026-11-03', 'Japanese', 3), _row('2026-11-03', 'Math', 9)],
    );
    final count = ankiCountForFacet(
      deckName: null,
      start: DateTime(2026, 11, 3),
      end: DateTime(2026, 11, 4),
      report: report,
    );
    expect(count.cards, 12);
    expect(count.reviews, 12);
  });

  test('node actuals use the current period, not all history', () {
    final report = AnkiReportData(
      days: [
        _row('2026-10-20', 'Japanese', 5),
        _row('2026-11-03', 'Japanese', 3),
      ],
    );
    final nodes = [
      _goal('daily', deck: 'Japanese', period: TimeScale.daily),
      _goal('monthly', deck: 'Japanese', period: TimeScale.monthly),
      _goal('all', period: TimeScale.monthly),
    ];
    final actuals = ankiActualsForNodes(nodes, report, now: now);
    // Yesterday's reviews do not count toward a daily goal, but the goal
    // still has data, so the cached count is reset to 0.
    expect(actuals['daily'], 0);
    expect(actuals['monthly'], 3);
    expect(actuals['all'], 3);
  });

  test('one-time goals count from their creation day', () {
    final report = AnkiReportData(
      days: [
        _row('2026-10-01', 'Japanese', 40),
        _row('2026-11-03', 'Japanese', 3),
      ],
    );
    final nodes = [
      _goal('old', deck: 'Japanese', createdAt: DateTime(2026, 10, 15)),
      _goal('new', deck: 'Japanese', createdAt: DateTime(2026, 11, 1)),
    ];
    final actuals = ankiActualsForNodes(nodes, report, now: now);
    expect(actuals['old'], 3);
    expect(actuals['new'], 3);
  });

  test('a period older than the fetched window keeps the cached count', () {
    final report = AnkiReportData(
      windowStart: DateTime(2025, 10, 1),
      days: [_row('2026-11-03', 'Japanese', 3)],
    );
    final nodes = [
      _goal(
        'old-one-time',
        deck: 'Japanese',
        createdAt: DateTime(2025, 1, 1),
      ),
      _goal(
        'recent-one-time',
        deck: 'Japanese',
        createdAt: DateTime(2025, 12, 1),
      ),
      _goal('daily', deck: 'Japanese', period: TimeScale.daily),
    ];
    final actuals = ankiActualsForNodes(nodes, report, now: now);
    expect(actuals.containsKey('old-one-time'), isFalse);
    expect(actuals['recent-one-time'], 3);
    expect(actuals['daily'], 0);
  });

  test('a deck with no reports is omitted so manual counts survive', () {
    final report = AnkiReportData(days: [_row('2026-11-03', 'Math', 3)]);
    final nodes = [
      _goal('manual', deck: 'Japanese', period: TimeScale.daily, actual: 17),
    ];
    final actuals = ankiActualsForNodes(nodes, report, now: now);
    expect(actuals.containsKey('manual'), isFalse);
  });

  test('parses a server payload and tolerates junk rows', () {
    final data = AnkiReportData.fromJson({
      'days': [
        {'day': '2026-11-03', 'deck': 'Japanese', 'cards': 4, 'reviews': 6},
        {'deck': 'Missing day'},
        'not-a-map',
      ],
      'decks': [
        {
          'name': 'Japanese',
          'cards': 4,
          'reviews': 6,
          'last_day': '2026-11-03',
        },
      ],
      'last_report_at': '2026-11-03T18:30:00+00:00',
      'last_client': 'anki/1.0',
    });
    expect(data.days, hasLength(1));
    expect(data.days.first.cards, 4);
    expect(data.decks.single.lastDay, DateTime(2026, 11, 3));
    expect(data.lastReportAt, isNotNull);
    expect(data.lastClient, 'anki/1.0');
  });

  test('iso day pads single-digit months and days', () {
    expect(ankiIsoDay(DateTime(2026, 1, 2)), '2026-01-02');
  });
}
