import 'dart:collection';

import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:a_fish_in_sea/reporting/service/tracked_position.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingPoints extends ListBase<TrackedPoint> {
  final List<TrackedPoint> points;
  var reads = 0;
  CountingPoints(this.points);
  @override
  int get length => points.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  TrackedPoint operator [](int index) {
    reads++;
    return points[index];
  }

  @override
  void operator []=(int index, TrackedPoint value) =>
      throw UnsupportedError('read only');
}

void main() {
  final start = DateTime(2026, 10, 18);
  TrackedPoint point(int i) => TrackedPoint(
    id: '$i',
    timestamp: start.add(Duration(seconds: i)),
    lat: i.toDouble(),
    lng: 0,
  );

  test('scrub preserves last-known position at every boundary', () {
    final points = [point(1), point(3), point(3), point(5)];
    expect(trackedPointAt([], start), isNull);
    expect(trackedPointAt(points, start), isNull);
    expect(
      trackedPointAt(points, start.add(const Duration(seconds: 1))),
      same(points[0]),
    );
    expect(
      trackedPointAt(points, start.add(const Duration(seconds: 2))),
      same(points[0]),
    );
    expect(
      trackedPointAt(points, start.add(const Duration(seconds: 3))),
      same(points[2]),
    );
    expect(
      trackedPointAt(points, start.add(const Duration(days: 1))),
      same(points.last),
    );
  });

  test('scrubbing a maximum-size route needs at most 14 point reads', () {
    final points = CountingPoints(List.generate(5000, point));
    expect(
      trackedPointAt(points, start.add(const Duration(seconds: 4500)))?.id,
      '4500',
    );
    expect(points.reads, lessThanOrEqualTo(14));
  });
}
