import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_cubit.dart';
import '../../planner/service/task_bulk_actions.dart';
import '../model/node.dart';
import 'node_bulk_editor.dart';

/// Bulk actions for the graph's multi-select bar. Kept out of the view so
/// the canvas file stays focused on layout and selection state.

/// Opens the bulk editor and reports whether anything was applied. The
/// snackbar carries the undo action for the one write the editor recorded.
Future<bool> editSelectedGoals(BuildContext context, List<Node> nodes) async {
  final changed = await showNodeBulkEditor(context, nodes: nodes);
  if (!context.mounted || changed == null) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  UndoCubit? undo;
  try {
    undo = context.read<UndoCubit>();
  } catch (_) {}
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          changed == 1 ? '1 goal updated' : '$changed goals updated',
        ),
        duration: const Duration(seconds: 4),
        persist: false,
        action: undo == null
            ? null
            : SnackBarAction(label: 'Undo', onPressed: undo.undo),
      ),
    );
  return true;
}

/// Marks the group complete, or reopens it when every selected goal was
/// already done. Returns the number changed.
int markSelectedGoalsDone(
  BuildContext context,
  List<Node> nodes, {
  required bool allDone,
}) => markTaskNodesDone(
  context,
  {for (final node in nodes) node.id},
  done: !allDone,
  noun: 'goal',
);

/// Confirms and deletes the selected goals as one undoable write. Returns
/// true when the deletion ran.
Future<bool> deleteSelectedGoals(BuildContext context, List<Node> nodes) async {
  final count = nodes.length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(count == 1 ? 'Delete goal?' : 'Delete $count goals?'),
      content: const Text(
        'A subgoal is removed with its last remaining parent. '
        'You can undo this right after deleting.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (!context.mounted || confirmed != true) return false;
  deleteTaskNodes(context, {for (final node in nodes) node.id}, noun: 'goal');
  return true;
}
