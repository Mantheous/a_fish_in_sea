import 'package:flutter/material.dart';

import '../../common/time/local_date.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';

/// Picker defaults and snapping do not schedule an untouched assignment.
({DateTime start, DateTime end}) eventEditorInterval({
  required DateTime date,
  required TimeOfDay startTime,
  required TimeOfDay endTime,
  required bool allDay,
  required int snapMinutes,
  PlannerEvent? untouchedAssignment,
}) {
  if (untouchedAssignment != null) {
    return (start: untouchedAssignment.start, end: untouchedAssignment.end);
  }
  final start = allDay
      ? DateTime(date.year, date.month, date.day)
      : snapToInterval(
          DateTime(
            date.year,
            date.month,
            date.day,
            startTime.hour,
            startTime.minute,
          ),
          snapMinutes,
        );
  var end = allDay
      ? shiftLocalDay(start, 1)
      : snapToInterval(
          DateTime(
            date.year,
            date.month,
            date.day,
            endTime.hour,
            endTime.minute,
          ),
          snapMinutes,
        );
  if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
  return (start: start, end: end);
}
