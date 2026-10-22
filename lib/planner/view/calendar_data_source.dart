import 'dart:collection';

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

  PlannerCalendarDataSource(this._events, this.feedColors, [this.colorCache]) {
    _events = _IndexedAppointments(_events);
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
    if (matches(nextEvents, nextFeedColors, nextColorCache)) return;
    final previous = {for (final event in _events) event.id: event};
    final next = {for (final event in nextEvents) event.id: event};
    final removed = <PlannerEvent>[
      for (final event in _events)
        if (next[event.id] != event) event,
    ];
    final added = <PlannerEvent>[
      for (final event in nextEvents)
        if (previous[event.id] != event) event,
    ];
    // Color-only updates affect Syncfusion's internal appointment copies.
    final colorsChanged =
        !mapEquals(feedColors, nextFeedColors) ||
        _events.any(
          (event) =>
              next.containsKey(event.id) &&
              colorCache?[event.id] != nextColorCache?[event.id],
        );
    _events = _IndexedAppointments(nextEvents);
    feedColors = nextFeedColors;
    colorCache = nextColorCache;
    appointments = _events;
    // Small edits should convert only changed appointments. Bulk imports
    // use reset to avoid the library's remove loop scanning N times.
    if (colorsChanged || removed.length + added.length > 32) {
      notifyListeners(CalendarDataSourceAction.reset, nextEvents);
    } else {
      if (removed.isNotEmpty) {
        notifyListeners(CalendarDataSourceAction.remove, removed);
      }
      if (added.isNotEmpty) {
        notifyListeners(CalendarDataSourceAction.add, added);
      }
    }
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

/// Syncfusion converts each custom appointment by calling
/// `dataSource.appointments.indexOf(event)`. A normal list makes every
/// reset quadratic, including opening a calendar with years of imports.
/// Identity lookup preserves the custom event objects used by drag/tap.
class _IndexedAppointments extends ListBase<PlannerEvent> {
  final List<PlannerEvent> _items;
  Map<PlannerEvent, int>? _indices;

  _IndexedAppointments(List<PlannerEvent> events) : _items = List.of(events);

  @override
  int get length => _items.length;

  @override
  set length(int value) {
    _indices = null;
    _items.length = value;
  }

  @override
  PlannerEvent operator [](int index) => _items[index];

  @override
  void operator []=(int index, PlannerEvent value) {
    _indices = null;
    _items[index] = value;
  }

  // Native drag/drop edits the data source before calling onDragEnd. Keep
  // its working list mutable, separate from the immutable cubit snapshot.
  @override
  void add(PlannerEvent value) {
    _indices = null;
    _items.add(value);
  }

  @override
  void addAll(Iterable<PlannerEvent> iterable) {
    _indices = null;
    _items.addAll(iterable);
  }

  @override
  int indexOf(Object? element, [int start = 0]) {
    final indices = _indices ??= _buildIndices();
    final index = indices[element];
    if (index != null && index >= start) return index;
    // Retain List equality semantics for equal copies and nonzero starts.
    return element is PlannerEvent ? _items.indexOf(element, start) : -1;
  }

  Map<PlannerEvent, int> _buildIndices() {
    final indices = Map<PlannerEvent, int>.identity();
    for (var i = 0; i < length; i++) {
      indices.putIfAbsent(this[i], () => i);
    }
    return indices;
  }
}
