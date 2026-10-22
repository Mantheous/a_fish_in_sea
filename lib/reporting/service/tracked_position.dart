import '../model/tracked_point.dart';

/// Last known position at [time]. TrackingCubit supplies sorted day buckets.
/// Binary search keeps each scrub independent of the day's point count.
TrackedPoint? trackedPointAt(List<TrackedPoint> points, DateTime time) {
  var low = 0;
  var high = points.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (points[middle].timestamp.isAfter(time)) {
      high = middle;
    } else {
      low = middle + 1;
    }
  }
  return low == 0 ? null : points[low - 1];
}
