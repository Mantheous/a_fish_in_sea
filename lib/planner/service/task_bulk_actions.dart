import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_cubit.dart';
import '../../finances/bloc/transactions_cubit.dart';
import '../../finances/service/node_transaction_cleanup.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/service/node_event_link.dart';
import '../bloc/calendar_cubit.dart';

/// Bulk task actions shared by the Tasks page and the calendar side panel,
/// so both surfaces run the exact same undoable writes and snackbars.

/// Marks [ids] done in one undoable step, mirroring completion onto their
/// linked calendar events. Shows the undo snackbar; returns the number of
/// nodes changed (0 when the selection was empty, stale, or already done).
int markTaskNodesDone(BuildContext context, Set<String> ids) {
  NodeCubit nodes;
  try {
    nodes = context.read<NodeCubit>();
  } catch (_) {
    return 0;
  }
  final live = ids.where((id) => nodes.byId(id) != null).toSet();
  if (live.isEmpty) return 0;
  CalendarCubit? calendar;
  try {
    calendar = context.read<CalendarCubit>();
  } catch (_) {}
  final undoCubit = context.read<UndoCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final changed = calendar == null
      ? nodes.setDoneMany(live, done: true)
      : NodeEventLink.setNodesDone(nodes, calendar, live, done: true);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          changed == 1 ? '1 task marked done' : '$changed tasks marked done',
        ),
        duration: const Duration(seconds: 4),
        // Action snackbars persist forever by default; this one must go.
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: undoCubit.undo,
        ),
      ),
    );
  return changed;
}

/// Deletes [ids] in one undoable step, keeping their calendar events but
/// clearing the task links. Shows the undo snackbar; returns the number
/// of nodes removed (0 when the selection was empty or stale).
int deleteTaskNodes(BuildContext context, Set<String> ids) {
  NodeCubit nodes;
  try {
    nodes = context.read<NodeCubit>();
  } catch (_) {
    return 0;
  }
  final live = ids.where((id) => nodes.byId(id) != null).toSet();
  if (live.isEmpty) return 0;
  CalendarCubit? calendar;
  try {
    calendar = context.read<CalendarCubit>();
  } catch (_) {}
  final undoCubit = context.read<UndoCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  int removed;
  try {
    removed = deleteNodesAndClearAssignments(
      nodes: nodes,
      transactions: context.read<TransactionsCubit>(),
      alsoTrack: calendar == null ? const [] : [calendar],
      delete: () => calendar == null
          ? nodes.deleteNodes(live)
          : NodeEventLink.deleteNodesAndUnlink(nodes, calendar, live),
    );
  } catch (_) {
    removed = calendar == null
        ? nodes.deleteNodes(live)
        : NodeEventLink.deleteNodesAndUnlink(nodes, calendar, live);
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          removed == 1 ? '1 task deleted' : '$removed tasks deleted',
        ),
        duration: const Duration(seconds: 4),
        // Action snackbars persist forever by default; this one must go.
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: undoCubit.undo,
        ),
      ),
    );
  return removed;
}
