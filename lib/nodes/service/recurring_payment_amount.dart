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
/// Older hand edits may lack override markers, so compare each occurrence
/// with its complete previous generated copy before changing anything.
Map<String, Node> recurringPaymentAmountUpdates(
  Node before,
  Node after,
  List<Node> nodes, {
  required DateTime today,
  required Node Function(Node) originalInstance,
}) {
  if (before.money == null ||
      after.money == null ||
      before.money!.targetAmount == after.money!.targetAmount) {
    return {};
  }
  if (before.isInstance) {
    return {after.id: after.withOverride('money.targetAmount')};
  }
  if (!before.isTemplate || !after.isTemplate) return {};
  return {
    for (final node in nodes)
      if (node.instanceOfId == before.id &&
          node == originalInstance(node) &&
          (node.schedule?.due ?? node.schedule?.start) != null &&
          !localDay(
            (node.schedule?.due ?? node.schedule!.start)!,
          ).isBefore(today))
        node.id: node.copyWith(
          money: node.money!.copyWith(targetAmount: after.money!.targetAmount),
        ),
  };
}
