import '../../common/undo/revertable_hydrated_cubit.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import 'node_event_link.dart';

/// Starts recording a brand-new ad-hoc task from a name alone.
///
/// The user did something they never planned — lunch, a train ride, an
/// errand — so the node is minted as concrete work ([Node.taskFlag]) with
/// no schedule and no parent. It lands as a root; assigning it to a goal
/// later is the normal [NodeGoalAssignment.assignNodeToGoal] reparent, not
/// a special recorded-task state.
///
/// The create and the start fold into one undoable gesture, so Undo takes
/// back both the timer and the task it was recording.
({String? error, Node? node}) startQuickRecording(
  NodeCubit nodes,
  CalendarCubit calendar,
  String title, {
  DateTime? now,
  String? nodeId,
}) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return (error: 'Please enter a name.', node: null);
  final at = now ?? DateTime.now();
  // Timestamped id, same shape as other locally minted nodes.
  final id = nodeId ?? 'node:${at.microsecondsSinceEpoch}';
  final node = Node(id: id, title: trimmed, createdAt: at, taskFlag: true);
  String? error;
  RevertableHydratedCubit.atomic([nodes, calendar], () {
    error = nodes.addNode(node);
    if (error != null) return;
    // Stops whichever recording is already running (node or plain event),
    // so there is never more than one active timer.
    NodeEventLink.startNodeTracking(nodes, calendar, id, now: at);
  });
  if (error != null) return (error: error, node: null);
  final created = nodes.byId(id);
  if (created == null) {
    return (error: 'The task could not be created.', node: null);
  }
  if (!created.isTracking) {
    return (error: 'The recording could not be started.', node: null);
  }
  return (error: null, node: created);
}
