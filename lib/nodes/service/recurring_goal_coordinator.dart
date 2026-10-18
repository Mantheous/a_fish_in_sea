import 'dart:async';

import '../bloc/node_cubit.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../finances/bloc/transactions_cubit.dart';
import 'recurring_goal_link.dart';

/// Coalesces hydration, feed imports and remote sync into one reconciliation.
/// Delay until the whole synchronous batch has landed in both stores.
class RecurringGoalCoordinator {
  final NodeCubit nodes;
  final CalendarCubit calendar;
  final TransactionsCubit transactions;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _queued = false;
  bool _closed = false;

  RecurringGoalCoordinator(this.nodes, this.calendar, this.transactions) {
    _subscriptions.add(nodes.stream.listen((_) => _schedule()));
    _subscriptions.add(calendar.stream.listen((_) => _schedule()));
    _schedule();
  }

  void _schedule() {
    if (_closed || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_closed) return;
      RecurringGoalLink.reconcile(
        calendar,
        nodes,
        protectedNodeIds: {
          for (final t in transactions.state)
            if (t.assignedNodeId != null) t.assignedNodeId!,
        },
      );
    });
  }

  void dispose() {
    _closed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
  }
}
