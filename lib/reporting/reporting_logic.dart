import 'dart:math' as math;

import 'model/place.dart';
import 'model/reported_entry.dart';
import 'model/tracked_point.dart';

class PlannedSlice {
  final String eventId;
  final String title;
  final String? placeId;
  final DateTime start;
  final DateTime end;
  final bool allDay;

  const PlannedSlice({
    required this.eventId,
    required this.title,
    this.placeId,
    required this.start,
    required this.end,
    this.allDay = false,
  });

  int get durationMin => end.isAfter(start) ? end.difference(start).inMinutes : 0;
}

class Dwell {
  final String placeId;
  final DateTime start;
  final DateTime end;

  const Dwell({required this.placeId, required this.start, required this.end});

  int get minutes => end.isAfter(start) ? end.difference(start).inMinutes : 0;
}

class DayStats {
  final int plannedMin;
  final int attendedMin;
  final Map<String, int> minutesPerPlace;

  const DayStats({
    required this.plannedMin,
    required this.attendedMin,
    required this.minutesPerPlace,
  });

  double get onTaskPct =>
      plannedMin <= 0 ? 0 : (attendedMin / plannedMin).clamp(0.0, 1.0);
}

double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthM = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthM * math.asin(math.sqrt(a));
}

double _rad(double deg) => deg * math.pi / 180;

String? placeAt(List<Place> places, double lat, double lng) {
  for (final place in places) {
    if (haversineMeters(lat, lng, place.lat, place.lng) <= place.radiusM) {
      return place.id;
    }
  }
  return null;
}

List<Dwell> clusterDwells(List<TrackedPoint> points, List<Place> places) {
  final sorted = [...points]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final dwells = <Dwell>[];
  String? currentPlace;
  DateTime? dwellStart;
  DateTime? lastSeen;

  void close() {
    if (currentPlace != null && dwellStart != null && lastSeen != null) {
      dwells.add(Dwell(placeId: currentPlace!, start: dwellStart!, end: lastSeen!));
    }
    currentPlace = null;
    dwellStart = null;
    lastSeen = null;
  }

  for (final point in sorted) {
    final at = placeAt(places, point.lat, point.lng);
    if (at == null) {
      close();
      continue;
    }
    if (at != currentPlace) {
      close();
      currentPlace = at;
      dwellStart = point.timestamp;
    }
    lastSeen = point.timestamp;
  }
  close();
  return dwells;
}

int _overlapMin(DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) {
  final start = aStart.isAfter(bStart) ? aStart : bStart;
  final end = aEnd.isBefore(bEnd) ? aEnd : bEnd;
  return end.isAfter(start) ? end.difference(start).inMinutes : 0;
}

List<ReportedEntry> autoReport({
  required List<PlannedSlice> planned,
  required List<Dwell> dwells,
  required Map<String, String> placeNames,
  int extraMinThreshold = 10,
}) {
  final entries = <ReportedEntry>[];
  final claimed = List<bool>.filled(dwells.length, false);

  for (final item in planned) {
    if (item.allDay || item.durationMin <= 0) continue;
    var matched = 0;
    if (item.placeId != null) {
      for (var i = 0; i < dwells.length; i++) {
        final dwell = dwells[i];
        if (dwell.placeId != item.placeId) continue;
        final overlap = _overlapMin(item.start, item.end, dwell.start, dwell.end);
        if (overlap > 0) {
          matched += overlap;
          claimed[i] = true;
        }
      }
    }
    final threshold = math.max(10, (item.durationMin * 0.5).round());
    final status = matched >= threshold
        ? ReportStatus.attended
        : matched > 0
            ? ReportStatus.partial
            : ReportStatus.missed;
    entries.add(ReportedEntry(
      id: 'rep:${item.eventId}',
      eventId: item.eventId,
      placeId: item.placeId,
      title: item.title,
      start: item.start,
      end: item.end,
      status: status,
      minutesAtPlace: matched,
    ));
  }

  for (var i = 0; i < dwells.length; i++) {
    if (claimed[i]) continue;
    final dwell = dwells[i];
    if (dwell.minutes < extraMinThreshold) continue;
    entries.add(ReportedEntry(
      id: 'rep:extra:${dwell.placeId}:${dwell.start.millisecondsSinceEpoch}',
      placeId: dwell.placeId,
      title: placeNames[dwell.placeId] ?? 'Unplanned time',
      start: dwell.start,
      end: dwell.end,
      status: ReportStatus.extra,
      minutesAtPlace: dwell.minutes,
    ));
  }

  entries.sort((a, b) => a.start.compareTo(b.start));
  return entries;
}

DayStats computeDayStats({
  required List<PlannedSlice> planned,
  required List<Dwell> dwells,
}) {
  var plannedMin = 0;
  var attendedMin = 0;
  final perPlace = <String, int>{};
  for (final dwell in dwells) {
    perPlace.update(dwell.placeId, (v) => v + dwell.minutes,
        ifAbsent: () => dwell.minutes);
  }
  for (final item in planned) {
    if (item.allDay || item.durationMin <= 0) continue;
    plannedMin += item.durationMin;
    if (item.placeId == null) continue;
    var matched = 0;
    for (final dwell in dwells) {
      if (dwell.placeId != item.placeId) continue;
      matched += _overlapMin(item.start, item.end, dwell.start, dwell.end);
    }
    attendedMin += math.min(matched, item.durationMin);
  }
  return DayStats(
    plannedMin: plannedMin,
    attendedMin: attendedMin,
    minutesPerPlace: perPlace,
  );
}

String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
