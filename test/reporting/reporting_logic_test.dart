import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:a_fish_in_sea/reporting/reporting_logic.dart';
import 'package:flutter_test/flutter_test.dart';

const _home = Place(id: 'home', name: 'Home', lat: 40.0, lng: -111.0);
const _work = Place(
    id: 'work', name: 'Work', lat: 40.01, lng: -111.01, radiusM: 200);

TrackedPoint _pt(DateTime at, double lat, double lng) => TrackedPoint(
      id: 'pt:${at.millisecondsSinceEpoch}',
      timestamp: at,
      lat: lat,
      lng: lng,
    );

void main() {
  group('haversineMeters', () {
    test('zero for identical points', () {
      expect(haversineMeters(40, -111, 40, -111), 0);
    });

    test('roughly 111km per degree of latitude', () {
      final m = haversineMeters(40, -111, 41, -111);
      expect(m, greaterThan(110000));
      expect(m, lessThan(112000));
    });
  });

  group('placeAt', () {
    test('matches inside radius, misses outside', () {
      expect(placeAt([_home], 40.0, -111.0), 'home');
      expect(placeAt([_home], 41.0, -111.0), isNull);
    });
  });

  group('clusterDwells', () {
    test('groups consecutive points at one place', () {
      final base = DateTime(2026, 9, 5, 9);
      final points = [
        _pt(base, 40.0, -111.0),
        _pt(base.add(const Duration(minutes: 5)), 40.0, -111.0),
        _pt(base.add(const Duration(minutes: 10)), 40.0, -111.0),
      ];
      final dwells = clusterDwells(points, [_home, _work]);
      expect(dwells, hasLength(1));
      expect(dwells.first.placeId, 'home');
      expect(dwells.first.minutes, 10);
    });

    test('travel gap splits dwells', () {
      final base = DateTime(2026, 9, 5, 9);
      final points = [
        _pt(base, 40.0, -111.0),
        _pt(base.add(const Duration(minutes: 5)), 45.0, -120.0),
        _pt(base.add(const Duration(minutes: 10)), 40.0, -111.0),
      ];
      final dwells = clusterDwells(points, [_home, _work]);
      expect(dwells, hasLength(2));
    });

    test('switching places starts a new dwell', () {
      final base = DateTime(2026, 9, 5, 9);
      final points = [
        _pt(base, 40.0, -111.0),
        _pt(base.add(const Duration(minutes: 5)), 40.01, -111.01),
      ];
      final dwells = clusterDwells(points, [_home, _work]);
      expect(dwells.map((d) => d.placeId), ['home', 'work']);
    });
  });

  group('autoReport', () {
    final day = DateTime(2026, 9, 5);
    final names = {'home': 'Home', 'work': 'Work'};

    test('marks attended when dwell covers the event', () {
      final planned = [
        PlannedSlice(
          eventId: 'e1',
          title: 'Study',
          placeId: 'home',
          start: DateTime(2026, 9, 5, 9),
          end: DateTime(2026, 9, 5, 10),
        ),
      ];
      final dwells = [
        Dwell(
          placeId: 'home',
          start: DateTime(2026, 9, 5, 8, 55),
          end: DateTime(2026, 9, 5, 10, 5),
        ),
      ];
      final entries =
          autoReport(planned: planned, dwells: dwells, placeNames: names);
      expect(entries, hasLength(1));
      expect(entries.first.status, ReportStatus.attended);
      expect(entries.first.minutesAtPlace, 60);
    });

    test('marks partial on brief overlap, missed on none', () {
      final planned = [
        PlannedSlice(
          eventId: 'e1',
          title: 'Brief',
          placeId: 'home',
          start: DateTime(2026, 9, 5, 9),
          end: DateTime(2026, 9, 5, 11),
        ),
        PlannedSlice(
          eventId: 'e2',
          title: 'Skipped',
          placeId: 'work',
          start: DateTime(2026, 9, 5, 13),
          end: DateTime(2026, 9, 5, 14),
        ),
      ];
      final dwells = [
        Dwell(
          placeId: 'home',
          start: DateTime(2026, 9, 5, 9),
          end: DateTime(2026, 9, 5, 9, 5),
        ),
      ];
      final entries =
          autoReport(planned: planned, dwells: dwells, placeNames: names);
      expect(
        entries.firstWhere((e) => e.eventId == 'e1').status,
        ReportStatus.partial,
      );
      expect(
        entries.firstWhere((e) => e.eventId == 'e2').status,
        ReportStatus.missed,
      );
    });

    test('emits extra for unmatched dwells over threshold', () {
      final entries = autoReport(
        planned: const [],
        dwells: [
          Dwell(
            placeId: 'work',
            start: DateTime(2026, 9, 5, 12),
            end: DateTime(2026, 9, 5, 12, 30),
          ),
          Dwell(
            placeId: 'work',
            start: DateTime(2026, 9, 5, 15),
            end: DateTime(2026, 9, 5, 15, 5),
          ),
        ],
        placeNames: names,
      );
      expect(entries, hasLength(1));
      expect(entries.first.status, ReportStatus.extra);
      expect(entries.first.title, 'Work');
      expect(day, isNotNull);
    });
  });

  group('computeDayStats', () {
    test('on-task ratio from matched minutes', () {
      final stats = computeDayStats(
        planned: [
          PlannedSlice(
            eventId: 'e1',
            title: 'Study',
            placeId: 'home',
            start: DateTime(2026, 9, 5, 9),
            end: DateTime(2026, 9, 5, 10),
          ),
          PlannedSlice(
            eventId: 'e2',
            title: 'Gym',
            placeId: 'work',
            start: DateTime(2026, 9, 5, 11),
            end: DateTime(2026, 9, 5, 12),
          ),
        ],
        dwells: [
          Dwell(
            placeId: 'home',
            start: DateTime(2026, 9, 5, 9),
            end: DateTime(2026, 9, 5, 10),
          ),
        ],
      );
      expect(stats.plannedMin, 120);
      expect(stats.attendedMin, 60);
      expect(stats.onTaskPct, 0.5);
      expect(stats.minutesPerPlace['home'], 60);
    });

    test('zero planned gives zero pct, not NaN', () {
      final stats = computeDayStats(planned: const [], dwells: const []);
      expect(stats.onTaskPct, 0);
    });
  });

  group('dayKey', () {
    test('stable zero-padded key', () {
      expect(dayKey(DateTime(2026, 9, 5)), '2026-09-05');
    });

    test('isSameDay ignores time', () {
      expect(
        isSameDay(DateTime(2026, 9, 5, 8), DateTime(2026, 9, 5, 22)),
        isTrue,
      );
      expect(
        isSameDay(DateTime(2026, 9, 5), DateTime(2026, 9, 6)),
        isFalse,
      );
    });
  });
}
