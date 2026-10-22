import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';

/// Returns actual spending in the active period for a budget subtree.
/// Transaction links provide dated actuals; manually entered actuals without
/// transaction links remain included because they have no date to filter.
double moneyActualForActivePeriod(
  Node budget,
  List<Node> allNodes,
  List<Transaction> transactions, {
  DateTime? now,
}) {
  final period = budget.money?.period;
  if (period == null) return 0;
  final window = _activeWindow(period, budget.money?.customPeriodDays, now);
  if (window == null) return 0;
  final transactionsById = {for (final txn in transactions) txn.id: txn};
  final byId = {for (final node in allNodes) node.id: node};
  final byParent = <String, List<Node>>{};
  for (final node in allNodes) {
    for (final parentId in node.parentIds) {
      (byParent[parentId] ??= []).add(node);
    }
  }
  return _subtreeActual(
    budget.id,
    byId,
    byParent,
    transactionsById,
    window,
    {},
  );
}

double _subtreeActual(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Map<String, Transaction> transactionsById,
  (DateTime, DateTime) window,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0;
  final node = byId[id];
  if (node == null) return 0;
  final money = node.money;
  var total = 0.0;
  if (money != null && money.linkedTransactionIds.isNotEmpty) {
    for (final transactionId in money.linkedTransactionIds) {
      final transaction = transactionsById[transactionId];
      if (transaction != null &&
          !transaction.date.isBefore(window.$1) &&
          transaction.date.isBefore(window.$2)) {
        total += transaction.amount.abs();
      }
    }
  } else if (money?.actualAmount != null) {
    total += money!.actualAmount!.abs();
  }
  for (final child in byParent[id] ?? const <Node>[]) {
    total += _subtreeActual(
      child.id,
      byId,
      byParent,
      transactionsById,
      window,
      seen,
    );
  }
  return total;
}

(DateTime, DateTime)? _activeWindow(
  TimeScale period,
  int? customDays,
  DateTime? now,
) {
  final at = now ?? DateTime.now();
  final today = DateTime(at.year, at.month, at.day);
  switch (period) {
    case TimeScale.daily:
      return (today, today.add(const Duration(days: 1)));
    case TimeScale.weekly:
      final start = today.subtract(Duration(days: today.weekday - 1));
      return (start, start.add(const Duration(days: 7)));
    case TimeScale.biweekly:
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final anchor = DateTime(1970, 1, 5);
      final weeks = monday.difference(anchor).inDays ~/ 7;
      final start = anchor.add(Duration(days: (weeks ~/ 2) * 14));
      return (start, start.add(const Duration(days: 14)));
    case TimeScale.monthly:
      return (DateTime(at.year, at.month), DateTime(at.year, at.month + 1));
    case TimeScale.quarterly:
      final firstMonth = ((at.month - 1) ~/ 3) * 3 + 1;
      return (DateTime(at.year, firstMonth), DateTime(at.year, firstMonth + 3));
    case TimeScale.yearly:
      return (DateTime(at.year), DateTime(at.year + 1));
    case TimeScale.custom:
      final days = customDays;
      if (days == null || days < 1) return null;
      final start = today.subtract(Duration(days: days - 1));
      return (start, today.add(const Duration(days: 1)));
  }
}
