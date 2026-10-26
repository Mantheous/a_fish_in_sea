import '../../planner/model/task_assignee.dart';
import '../model/node.dart';
import 'node_editor_schedule.dart';

/// One bulk-edit form, applied to every selected goal as a single undoable
/// write. Fields are opt-in: a null [unbounded]/[favorite]/[task] and a false
/// `apply*` flag leave that facet alone. Titles are deliberately absent —
/// naming stays individual, which is what the bulk panel says.
class NodeBulkEdits {
  const NodeBulkEdits({
    this.applyNotes = false,
    this.notes,
    this.applyParents = false,
    this.addParentIds = const [],
    this.removeParentId,
    this.applyPeople = false,
    this.people = const [],
    this.unbounded,
    this.favorite,
    this.task,
    this.applyClass = false,
    this.classNodeId,
    this.applyDue = false,
    this.due,
    this.applyEffort = false,
    this.effortMinutes,
  });

  final bool applyNotes;
  final String? notes;

  /// Adds [addParentIds] and removes [removeParentId] from every goal. Never
  /// replaces the whole parent list, so bulk edits cannot flatten the DAG.
  final bool applyParents;
  final List<String> addParentIds;
  final String? removeParentId;

  /// Replaces each goal's assignee list.
  final bool applyPeople;
  final List<TaskAssignee> people;

  /// Null keeps the current flag; true/false applies it.
  final bool? unbounded;
  final bool? favorite;

  /// Explicit `taskFlag` to write. Null leaves the derived classification.
  final bool? task;

  /// Sets (or, with a null [classNodeId], clears) class membership.
  final bool applyClass;
  final String? classNodeId;

  /// Day-only due date. Null with [applyDue] clears the due date but keeps
  /// any existing calendar block, same as the single-goal editor.
  final bool applyDue;
  final DateTime? due;

  /// Null with [applyEffort] clears the time target.
  final bool applyEffort;
  final int? effortMinutes;
}

/// Applies [edits] to [nodes] and returns only the goals that changed.
///
/// Pure: [byId] supplies class-node lookups and is never mutated. Callers
/// hand the result to [NodeCubit.writeNodes] for one undo record and one
/// validation pass over the whole batch.
List<Node> applyBulkEdits(
  List<Node> nodes,
  NodeBulkEdits edits, {
  required Map<String, Node> byId,
}) {
  final changed = <Node>[];
  for (final node in nodes) {
    var next = node;

    if (edits.applyNotes) {
      final text = edits.notes?.trim();
      final empty = text == null || text.isEmpty;
      next = next.copyWith(notes: empty ? null : text, clearNotes: empty);
    }

    if (edits.applyParents) {
      final parents = [...next.parentIds];
      final remove = edits.removeParentId;
      if (remove != null) parents.remove(remove);
      for (final id in edits.addParentIds) {
        if (id != next.id && !parents.contains(id)) parents.add(id);
      }
      next = next.copyWith(parentIds: parents);
    }

    if (edits.applyPeople) {
      next = next.copyWith(assignees: List.of(edits.people));
    }

    if (edits.applyClass) {
      next = _withClass(next, edits.classNodeId, byId);
    }

    if (edits.unbounded == true) {
      // Mirrors the editor's unbounded save: the hidden target sections are
      // dropped so the write validates instead of failing on stale facets.
      next = next.copyWith(
        isUnbounded: true,
        clearTaskFlag: true,
        clearSchedule: true,
        clearMoney: true,
        clearEffort: true,
        clearAnki: true,
        clearRecurrence: true,
        clearAuto: true,
        extraMetrics: const [],
        clearRule: true,
      );
    } else if (edits.unbounded == false) {
      next = next.copyWith(isUnbounded: false);
    }

    if (edits.favorite != null) {
      next = next.copyWith(isFavorite: edits.favorite);
    }
    if (edits.task != null && edits.unbounded != true) {
      next = next.copyWith(taskFlag: edits.task);
    }

    // Unbounded goals carry no dates or targets; the panel disables these
    // sections, and this guard keeps a stale form from resurrecting them.
    if (edits.unbounded != true) {
      if (edits.applyDue) {
        final schedule = scheduleAfterEditorSave(
          previous: next.schedule,
          due: edits.due,
          isFixed: next.schedule?.isFixed ?? false,
        );
        next = next.copyWith(
          schedule: schedule,
          clearSchedule: schedule == null,
        );
      }
      if (edits.applyEffort) {
        final minutes = edits.effortMinutes;
        next = minutes == null
            ? next.copyWith(clearEffort: true)
            : next.copyWith(
                effort: EffortFacet(
                  targetMinutes: minutes,
                  isFixed: next.effort?.isFixed ?? false,
                ),
              );
      }
    }

    if (next != node) changed.add(next);
  }
  return changed;
}

/// Class membership is a parent edge plus a stable `classNodeId`. Imported
/// homework keeps its feed provenance; manual work takes the class node's
/// id/title, mirroring the single-goal editor.
Node _withClass(Node node, String? classNodeId, Map<String, Node> byId) {
  final parents = [...node.parentIds];
  final classNode = classNodeId == null ? null : byId[classNodeId];
  if (classNode != null && !classNode.isClassNode) {
    // Stale form state: a non-class node cannot become membership.
    return node;
  }
  final isInstance = node.instanceOfId != null;
  if (!isInstance) {
    parents.removeWhere((id) => byId[id]?.isClassNode == true);
  }
  final imported = node.sourceEventId != null || node.feedId != null;
  if (classNode == null) {
    final wasManualClass = node.classNodeId != null && !imported;
    return node.copyWith(
      parentIds: parents,
      clearClassNodeId: true,
      clearClassId: wasManualClass,
      clearClassLabel: wasManualClass,
    );
  }
  if (!isInstance && !parents.contains(classNode.id)) {
    parents.add(classNode.id);
  }
  final oldClassId = node.classId;
  final oldClassIdIsNode =
      oldClassId != null && byId[oldClassId]?.isClassNode == true;
  return node.copyWith(
    parentIds: parents,
    classNodeId: classNode.id,
    classId: imported
        ? oldClassId
        : (oldClassId != null && !oldClassIdIsNode ? oldClassId : classNode.id),
    classLabel: imported
        ? (node.classLabel ?? classNode.title)
        : classNode.title,
  );
}
