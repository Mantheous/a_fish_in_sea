import '../../common/time/local_date.dart';
import '../model/node.dart';
import 'node_recurrence_instance.dart';

/// One scan of existing copies, with no new occurrences or intermediate writes.
/// Match the old template's generated snapshot exactly to protect legacy
/// unmarked edits, then use the new snapshot so every generated default stays
/// current without relying on template history after a restart.
Map<String, Node> recurringPaymentAmountUpdates(
  Node before,
  Node after,
  List<Node> nodes, {
  required DateTime today,
}) {
  if (before.money == null || after.money == null) {
    return {};
  }
  final amountChanged = before.money!.targetAmount != after.money!.targetAmount;
  final titleChanged = before.title != after.title;
  if (before.isInstance) {
    final overrides = {
      ...after.overriddenFields,
      if (amountChanged) 'money.targetAmount',
      if (titleChanged) 'title',
    };
    return {
      if (amountChanged || titleChanged)
        after.id: after.copyWith(overriddenFields: overrides),
    };
  }
  if (!before.isTemplate || !after.isTemplate) {
    return {};
  }
  final updates = <String, Node>{};
  for (final node in nodes) {
    if (node.instanceOfId != before.id) continue;
    final date = node.schedule?.due ?? node.schedule?.start;
    if (date == null || localDay(date).isBefore(today)) continue;
    final original = spawnRecurringInstance(before, node.id, node.createdAt);
    if (node != original) continue;
    final refreshed = spawnRecurringInstance(after, node.id, node.createdAt);
    if (refreshed != original) updates[node.id] = refreshed;
  }
  return updates;
}
