import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';

Node node(
  String id, {
  List<String> parents = const [],
  String? calendarEventId,
  DateTime? actualStart,
  DateTime? actualEnd,
  DateTime? timerStartedAt,
  List<TimeSession> sessions = const [],
}) => Node(
  id: id,
  title: 'Node $id',
  parentIds: parents,
  createdAt: DateTime(2026, 9, 1),
  calendarEventId: calendarEventId,
  sessions: sessions,
  actualStart: actualStart,
  actualEnd: actualEnd,
  timerStartedAt: timerStartedAt,
);

PlannerEvent event(
  String id, {
  DateTime? start,
  DateTime? actualStart,
  DateTime? actualEnd,
  DateTime? timerStartedAt,
  String? taskId,
  String? feedId,
  bool allDay = false,
  List<TimeSession> sessions = const [],
}) => PlannerEvent(
  id: id,
  subject: 'Event $id',
  start: start ?? DateTime(2026, 9, 8, 9),
  end: (start ?? DateTime(2026, 9, 8, 9)).add(const Duration(hours: 1)),
  allDay: allDay,
  feedId: feedId,
  taskId: taskId,
  sessions: sessions,
  actualStart: actualStart,
  actualEnd: actualEnd,
  timerStartedAt: timerStartedAt,
);

ReportedEntry manual({
  required String id,
  String? eventId,
  required DateTime start,
  required DateTime end,
}) => ReportedEntry(
  id: id,
  eventId: eventId,
  title: 'Manual $id',
  start: start,
  end: end,
  status: ReportStatus.attended,
  auto: false,
);
