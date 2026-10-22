import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_budget_progress.dart';
import 'package:flutter_test/flutter_test.dart';

Node _node(String id, {List<String> parents = const [], MoneyFacet? money}) =>
    Node(
      id: id,
      title: id,
      parentIds: parents,
      createdAt: DateTime(2026, 1, 1),
      money: money,
    );

Transaction _transaction(String id, DateTime date, double amount) =>
    Transaction(
      id: id,
      accountId: 'checking',
      amount: amount,
      date: date,
      name: id,
    );

void main() {
  test('monthly budget includes only linked transactions in this month', () {
    final budget = _node(
      'food',
      money: const MoneyFacet(
        targetAmount: 500,
        period: TimeScale.monthly,
        actualAmount: 175,
        linkedTransactionIds: ['old', 'current'],
      ),
    );
    final transactions = [
      _transaction('old', DateTime(2026, 9, 30), -120),
      _transaction('current', DateTime(2026, 10, 3), -55),
    ];

    expect(
      moneyActualForActivePeriod(
        budget,
        [budget],
        transactions,
        now: DateTime(2026, 10, 18),
      ),
      55,
    );
  });

  test('manual actuals and in-period child transactions remain included', () {
    final budget = _node(
      'home',
      money: const MoneyFacet(targetAmount: 1000, period: TimeScale.monthly),
    );
    final manual = _node(
      'cash',
      parents: const ['home'],
      money: const MoneyFacet(targetAmount: 20, actualAmount: 20),
    );
    final linked = _node(
      'utilities',
      parents: const ['home'],
      money: const MoneyFacet(
        targetAmount: 100,
        actualAmount: 150,
        linkedTransactionIds: ['utility-tx'],
      ),
    );

    expect(
      moneyActualForActivePeriod(
        budget,
        [budget, manual, linked],
        [_transaction('utility-tx', DateTime(2026, 10, 8), -150)],
        now: DateTime(2026, 10, 18),
      ),
      170,
    );
  });
}
