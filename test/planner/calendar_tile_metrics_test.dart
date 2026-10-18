import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_tile_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlannerEvent eventOf(Duration length) {
    final start = DateTime(2026, 10, 18, 9);
    return PlannerEvent(
      id: 'evt:metrics',
      subject: 'Metrics',
      start: start,
      end: start.add(length),
    );
  }

  group('tileDuration', () {
    test('zero-duration events get the visible floor', () {
      expect(tileDuration(eventOf(Duration.zero)), minimumTileDuration);
      expect(minimumTileDuration.inMinutes, 15);
    });

    test('end-before-start events also floor', () {
      expect(
        tileDuration(eventOf(const Duration(minutes: -30))),
        minimumTileDuration,
      );
    });

    test('sub-floor events render at the floor', () {
      expect(
        tileDuration(eventOf(const Duration(minutes: 5))),
        minimumTileDuration,
      );
    });

    test('events at or above the floor keep their own length', () {
      expect(
        tileDuration(eventOf(const Duration(minutes: 15))),
        const Duration(minutes: 15),
      );
      expect(
        tileDuration(eventOf(const Duration(minutes: 90))),
        const Duration(minutes: 90),
      );
    });
  });
}
