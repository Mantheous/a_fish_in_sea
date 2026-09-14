import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

/// Calendar bridge for unified nodes: schedule blocks render as
/// appointments alongside [PlannerEvent]s. Block ids are prefixed with
/// `node:` so tap/drag/resize handlers can route back to the node.
///
/// Nodes already represented by a real event (personal links via
/// `calendarEventId`, homework via `sourceEventId`) are skipped to avoid
/// double-rendering.

const String nodeBlockPrefix = 'node:';

bool isNodeBlockId(String id) => id.startsWith(nodeBlockPrefix);

String nodeIdFromBlockId(String blockId) =>
    blockId.substring(nodeBlockPrefix.length);

String nodeBlockId(String nodeId) => '$nodeBlockPrefix$nodeId';

/// Synthesized appointments for node schedule blocks.
List<PlannerEvent> nodeCalendarBlocks(List<Node> nodes) {
  final out = <PlannerEvent>[];
  for (final n in nodes) {
    final s = n.schedule;
    if (s == null || !s.hasCalendarBlock) continue;
    if (n.calendarEventId != null || n.sourceEventId != null) continue;
    out.add(PlannerEvent(
      id: nodeBlockId(n.id),
      subject: n.title,
      notes: n.notes,
      start: s.start!,
      end: s.end!,
      allDay: s.allDay,
      classLabel: n.classLabel,
      taskId: n.id,
      isTask: true,
      done: n.isDone,
      assignees: n.assignees,
    ));
  }
  return out;
}

/// Shift a node's schedule block by the same delta an event drag applied.
Node shiftNodeBlock(Node node, DateTime fromStart, DateTime toStart) {
  final s = node.schedule;
  if (s == null || s.start == null || s.end == null) return node;
  final delta = toStart.difference(fromStart);
  return node.copyWith(
    schedule: s.copyWith(
      start: s.start!.add(delta),
      end: s.end!.add(delta),
    ),
  );
}
