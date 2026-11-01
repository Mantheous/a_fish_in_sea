import 'package:a_fish_in_sea/finances/model/transaction.dart';

import '../model/node.dart';

List<String> nodeLinkedTxnIds(Node node) =>
    node.money?.linkedTransactionIds ?? const [];

/// Refresh only linked bank contributions; retain manual actuals and all
/// other money fields. Kept separate from the persisted cubit's business logic.
Node settleNodeTransactions(Node node, Map<Transaction, Transaction> changes) {
  final money = node.money;
  if (money == null ||
      !changes.keys.any((t) => money.linkedTransactionIds.contains(t.id))) {
    return node;
  }
  final before = {for (final t in changes.keys) t.id: t};
  final after = {for (final t in changes.values) t.id: t};
  final replacements = {for (final e in changes.entries) e.key.id: e.value.id};
  final links = {
    for (final id in money.linkedTransactionIds) replacements[id] ?? id,
  }.toList();
  // Count each bank contribution once even if both IDs were already linked.
  final oldContribution = money.linkedTransactionIds.toSet().fold<double>(
    0,
    (sum, id) => sum + ((before[id] ?? after[id])?.amount.abs() ?? 0),
  );
  final newContribution = links.fold<double>(
    0,
    (sum, id) => sum + ((after[id] ?? before[id])?.amount.abs() ?? 0),
  );
  return node.copyWith(
    money: money.copyWith(
      linkedTransactionIds: links,
      actualAmount: money.actualAmount == null
          ? null
          : money.actualAmount! + newContribution - oldContribution,
    ),
  );
}
