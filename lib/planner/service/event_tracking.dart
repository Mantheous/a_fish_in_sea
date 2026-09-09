import 'package:equatable/equatable.dart';

import '../bloc/calendar_cubit.dart';
import '../model/planner_event.dart';

class TrackedSlice extends Equatable {
  final PlannerEvent event;
  final DateTime start;
  final DateTime end;

  const TrackedSlice({
    required this.event,
    required this.start,
    required this.end,
  });

  bool contains(DateTime now) =>
      !start.isAfter(now) && end.isAfter(now);

  @override
  List<Object?> get props => [event, start, end];
}

class NowSelection extends Equatable {
  final List<TrackedSlice> previous;
  final List<TrackedSlice> current;
  final List<TrackedSlice> next;

  const NowSelection({
    this.previous = const [],
    this.current = const [],
    this.next = const [],
  });

  bool get isEmpty =>
      previous.isEmpty && current.isEmpty && next.isEmpty;

  @override
  List<Object?> get props => [previous, current, next];
}

List<TrackedSlice> expandTrackedSlices(
  CalendarCubit calendar,
  List<PlannerEvent> events,
  DateTime windowStart,
  DateTime windowEnd,
) {
  final out = <TrackedSlice>[];
  for (final event in events) {
    if (event.allDay) continue;
    final duration = event.end.isAfter(event.start)
        ? event.end.difference(event.start)
        : const Duration(hours: 1);
    if (event.recurrenceRule.isEmpty) {
      if (event.end.isBefore(windowStart) ||
          event.start.isAfter(windowEnd)) {
        continue;
      }
      out.add(TrackedSlice(event: event, start: event.start, end: event.end));
      continue;
    }
    for (final occ in calendar.occurrencesOf(event, windowStart, windowEnd)) {
      out.add(TrackedSlice(event: event, start: occ, end: occ.add(duration)));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

NowSelection selectNowNext(
  List<TrackedSlice> slices,
  DateTime now, {
  int previousCount = 1,
  int nextCount = 2,
}) {
  final sorted = [...slices]..sort((a, b) => a.start.compareTo(b.start));
  final current = sorted.where((s) => s.contains(now)).toList();
  final currentIds = {for (final s in current) s.event.id};
  final ended = sorted
      .where((s) => !s.end.isAfter(now) && !currentIds.contains(s.event.id))
      .toList();
  final upcoming = sorted
      .where((s) => s.start.isAfter(now) && !currentIds.contains(s.event.id))
      .toList();
  final seenPrev = <String>{};
  final prevPicked = <TrackedSlice>[];
  for (var i = ended.length - 1;
      i >= 0 && prevPicked.length < previousCount;
      i--) {
    if (seenPrev.add(ended[i].event.id)) prevPicked.add(ended[i]);
  }
  final seenNext = <String>{};
  final nextPicked = <TrackedSlice>[];
  for (final s in upcoming) {
    if (nextPicked.length >= nextCount) break;
    if (seenNext.add(s.event.id)) nextPicked.add(s);
  }
  return NowSelection(
    previous: prevPicked.reversed.toList(),
    current: current,
    next: nextPicked,
  );
}

String formatStopwatch(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (hours > 0) return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  return '${two(minutes)}:${two(seconds)}';
}

String formatPlannedRange(DateTime start, DateTime end) {
  int minutes(DateTime a, DateTime b) => b.difference(a).inMinutes;
  final mins = minutes(start, end);
  if (mins >= 60) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (m == 0) return '${h}h planned';
    return '${h}h ${m}m planned';
  }
  return '${mins}m planned';
}
