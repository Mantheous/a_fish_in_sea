import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/model/node.dart';
import '../bloc/settings_cubit.dart';
import '../model/color_prefs.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';

/// Built-in color for events that belong to no class and no calendar.
const int defaultPersonalEventColor = 0xFF6B8F8A;

/// The user's color choices, or the defaults when the widget is pumped
/// outside the app shell (isolated sheets, widget tests).
ColorPrefs colorPrefsOf(BuildContext context) {
  try {
    return context.watch<SettingsCubit>().state.colors;
  } catch (_) {
    return const ColorPrefs();
  }
}

/// Whether [event] is imported homework rather than a personal entry.
///
/// A linked node is the authority when the caller has one (`Node.isHomework`
/// is provenance-based); otherwise feed events and class-labeled tasks count
/// as homework, which is exactly the set feed import turns into nodes.
bool isHomeworkEvent(PlannerEvent event, {Node? node}) {
  if (node != null) return node.isHomework;
  if (!event.isTask) return false;
  return event.feedId != null || (event.classLabel?.trim().isNotEmpty ?? false);
}

/// Color of a class label: the user's override when set, else the
/// deterministic palette color so a class never changes hue on its own.
Color resolveClassColor(
  String label,
  ColorPrefs prefs, {
  bool useOverrides = true,
}) {
  final assigned = useOverrides ? prefs.classColorFor(label) : null;
  return assigned == null ? courseColor(label.trim()) : Color(assigned);
}

/// Color of [event] everywhere an event is painted.
///
/// Priority (matching the Colors page copy):
/// homework → class → the event's own color → its calendar → personal.
/// The class step always runs (that is the pre-colors behavior); only the
/// user overrides are gated by [ColorPrefs.applyToCalendar].
Color resolveEventColor(
  PlannerEvent event,
  Map<String, Color> feedColors,
  ColorPrefs prefs, {
  Node? node,
}) {
  final overrides = prefs.applyToCalendar;
  final homework = prefs.homework;
  if (overrides && homework != null && isHomeworkEvent(event, node: node)) {
    return Color(homework);
  }
  final label = event.classLabel?.trim() ?? '';
  if (label.isNotEmpty) {
    return resolveClassColor(label, prefs, useOverrides: overrides);
  }
  final eventColor = event.colorValue;
  if (eventColor != null) return mutedCalendarColor(Color(eventColor));
  final feedColor = feedColors[event.feedId];
  if (feedColor != null) return mutedCalendarColor(feedColor);
  final personal = overrides ? prefs.personal : null;
  return personal == null
      ? const Color(defaultPersonalEventColor)
      : Color(personal);
}
