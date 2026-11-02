import '../../common/time/local_date.dart';
import '../model/node.dart';

/// Financial defaults shared by generation and conservative amount refreshes.
MoneyFacet? recurringInstanceMoney(MoneyFacet? money) => money == null
    ? null
    : MoneyFacet(
        targetAmount: money.targetAmount,
        direction: money.direction,
        status: MoneyStatus.projected,
        period: money.period,
        customPeriodDays: money.customPeriodDays,
        isRecurring: false,
        autoRollover: money.autoRollover,
        rolloverAmount: 0.0,
        isFixed: money.isFixed,
      );

/// One scan of existing copies, with no generation or intermediate writes.
/// Require exact generated defaults to protect legacy unmarked edits. Carry
/// template title/notes changes into matching future copies when they happen,
/// so later amount saves still recognize them without ignoring custom text
/// or relying on template history that would be lost after a restart.
Map<String, Node> recurringPaymentAmountUpdates(
  Node before,
  Node after,
  List<Node> nodes, {
  required DateTime today,
  required Node Function(Node) originalInstance,
}) {
  if (before.money == null || after.money == null) {
    return {};
  }
  final amountChanged = before.money!.targetAmount != after.money!.targetAmount;
  final titleChanged = before.title != after.title;
  final notesChanged = before.notes != after.notes;
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
  if ((!amountChanged && !titleChanged && !notesChanged) ||
      !before.isTemplate ||
      !after.isTemplate) {
    return {};
  }
  return {
    for (final node in nodes)
      if (node.instanceOfId == before.id &&
          node == originalInstance(node) &&
          (node.schedule?.due ?? node.schedule?.start) != null &&
          !localDay(
            (node.schedule?.due ?? node.schedule!.start)!,
          ).isBefore(today))
        node.id: node.copyWith(
          title: titleChanged ? after.title : node.title,
          notes: notesChanged ? after.notes : node.notes,
          clearNotes: notesChanged && after.notes == null,
          money: amountChanged
              ? node.money!.copyWith(targetAmount: after.money!.targetAmount)
              : node.money,
        ),
  };
}
