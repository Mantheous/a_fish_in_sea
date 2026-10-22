import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';

/// Clears transaction assignments for nodes removed by a delete cascade.
/// Call with the node list captured before and after deletion.
void clearAssignmentsForDeletedNodes(
  TransactionsCubit transactions,
  Iterable<Node> before,
  Iterable<Node> after,
) {
  final remainingIds = after.map((node) => node.id).toSet();
  final deletedIds = before
      .map((node) => node.id)
      .where((id) => !remainingIds.contains(id))
      .toSet();
  transactions.clearNodeAssignmentsFor(deletedIds);
}

/// Runs a node delete and clears transaction references as one undo step.
T deleteNodesAndClearAssignments<T>({
  required NodeCubit nodes,
  required TransactionsCubit transactions,
  required T Function() delete,
  List<RevertableHydratedCubit> alsoTrack = const [],
}) {
  final before = List<Node>.of(nodes.state);
  late T result;
  RevertableHydratedCubit.atomic([nodes, transactions, ...alsoTrack], () {
    result = delete();
    clearAssignmentsForDeletedNodes(transactions, before, nodes.state);
  });
  return result;
}
