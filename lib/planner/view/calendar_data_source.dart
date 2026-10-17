import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../model/feed.dart';
import '../model/planner_event.dart';

const int defaultPersonalEventColor = 0xFF6B8F8A;

class PlannerCalendarDataSource extends CalendarDataSource {
  List<PlannerEvent> _events;
  Map<String, Color> feedColors;
  Map<String, Color>? colorCache;

  PlannerCalendarDataSource(
    this._events,
    this.feedColors, [
    this.colorCache,
  ]) {
    appointments = _events;
  }

  List<PlannerEvent> get events => _events;

  bool matches(
    List<PlannerEvent> nextEvents,
    Map<String, Color> nextFeedColors,
    Map<String, Color>? nextColorCache,
  ) {
    if (identical(_events, nextEvents) &&
        mapEquals(feedColors, nextFeedColors) &&
        mapEquals(colorCache, nextColorCache)) {
      return true;
    }
    if (listEquals(_events, nextEvents) &&
        mapEquals(feedColors, nextFeedColors) &&
        mapEquals(colorCache, nextColorCache)) {
      return true;
    }
    return false;
  }

  void update(
    List<PlannerEvent> nextEvents,
    Map<String, Color> nextFeedColors, [
    Map<String, Color>? nextColorCache,
  ]) {
    _events = nextEvents;
    feedColors = nextFeedColors;
    colorCache = nextColorCache;
    appointments = nextEvents;
    notifyListeners(CalendarDataSourceAction.reset, nextEvents);
  }

  /// Maps a dragged occurrence back onto our event model. Syncfusion calls
  /// this when a drag starts and ends; without it the drag callbacks
  /// receive null and drops silently do nothing.
  @override
  dynamic convertAppointmentToObject(
    dynamic customData,
    Appointment appointment,
  ) {
    if (customData is! PlannerEvent) return customData;
    return customData.copyWith(
      start: appointment.startTime,
      end: appointment.endTime,
      allDay: appointment.isAllDay,
    );
  }

  @override
  DateTime getStartTime(int index) => _events[index].start;

  @override
  DateTime getEndTime(int index) {
    final event = _events[index];
    if (event.allDay && !event.end.isAfter(event.start)) {
      return event.start.add(const Duration(days: 1));
    }
    return event.end;
  }

  @override
  bool isAllDay(int index) => _events[index].allDay;

  @override
  String getSubject(int index) => _events[index].subject;

  @override
  String? getNotes(int index) => _events[index].notes;

  @override
  String? getLocation(int index) => _events[index].location;

  @override
  String getRecurrenceRule(int index) => _events[index].recurrenceRule;

  @override
  Object? getId(int index) => _events[index].id;

  @override
  Color getColor(int index) {
    final cached = colorCache;
    if (cached != null) {
      final event = _events[index];
      final hit = cached[event.id];
      if (hit != null) return hit;
    }
    final event = _events[index];
    final label = event.classLabel;
    if (label != null && label.isNotEmpty) return courseColor(label);
    final eventColor = event.colorValue;
    if (eventColor != null) return mutedCalendarColor(Color(eventColor));
    final feedColor = feedColors[event.feedId];
    if (feedColor != null) return mutedCalendarColor(feedColor);
    return const Color(defaultPersonalEventColor);
  }
}
