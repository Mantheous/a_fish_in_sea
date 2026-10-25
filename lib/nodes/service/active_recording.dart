import 'package:equatable/equatable.dart';

import '../../planner/model/planner_event.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import '../../planner/bloc/calendar_cubit.dart';
import 'node_event_link.dart';

/// The one timer currently running, whichever store owns it.
///
/// A task-event records on its backing node, so most recordings are node
/// recordings even when they were started from the calendar. The Calendar
/// and its recording banner read this shared value instead of each scanning
/// only one store, which is how a goal timer started in Goals used to be
/// invisible on the Calendar.
class ActiveRecording extends Equatable {
  /// Owner node id for node recordings, null for plain-event recordings.
  final String? nodeId;

  /// Owner event id for plain-event recordings, null for node recordings.
  final String? eventId;
  final String title;
  final DateTime startedAt;

  const ActiveRecording({
    this.nodeId,
    this.eventId,
    required this.title,
    required this.startedAt,
  });

  bool get isNode => nodeId != null;

  @override
  List<Object?> get props => [nodeId, eventId, title, startedAt];
}

/// The single active recording across both stores, or null.
///
/// Node timers win: a task-event's timer lives on its backing node, so the
/// node copy is the canonical one. The stores never intentionally run two
/// timers at once ([NodeEventLink] stops the other store on every start).
ActiveRecording? activeRecordingOf(
  List<Node> nodes,
  List<PlannerEvent> events,
) {
  for (final node in nodes) {
    final startedAt = node.timerStartedAt;
    if (startedAt == null) continue;
    return ActiveRecording(
      nodeId: node.id,
      title: node.title,
      startedAt: startedAt,
    );
  }
  for (final event in events) {
    final startedAt = event.timerStartedAt;
    if (startedAt == null) continue;
    return ActiveRecording(
      eventId: event.id,
      title: event.subject,
      startedAt: startedAt,
    );
  }
  return null;
}

/// Stops [recording] through the same aligned path the Calendar and Goals
/// use, so a node recording still mirrors onto its linked task-event.
void stopActiveRecording(
  NodeCubit nodes,
  CalendarCubit calendar,
  ActiveRecording recording, {
  DateTime? now,
}) {
  final nodeId = recording.nodeId;
  if (nodeId != null) {
    NodeEventLink.stopNodeTrackingAligned(nodes, calendar, nodeId, now: now);
    return;
  }
  final eventId = recording.eventId;
  if (eventId != null) {
    NodeEventLink.stopEventTrackingAligned(nodes, calendar, eventId, now: now);
  }
}
