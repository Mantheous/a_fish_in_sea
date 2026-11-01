import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';

import '../../support/bank_settlement_fixture.dart';

void main() {
  for (final sameId in [false, true]) {
    test('settlement refreshes links and actuals (same ID: $sameId)', () async {
      final f = BankSettlementFixture();
      final raw = (await f.plaid.fetchTransactions()).single;
      if (sameId) raw['transaction_id'] = 'pending';
      final posted = Transaction.fromPlaid(raw);
      final goal = f.nodes.byId('coffee')!;
      f.nodes.updateNode(
        goal.copyWith(
          money: goal.money!.copyWith(
            actualAmount: 32,
            linkedTransactionIds: ['pending', 'unrelated'],
          ),
        ),
      );
      final manual = Node(
        id: 'manual', title: 'Manual', createdAt: goal.createdAt,
        money: goal.money!.copyWith(actualAmount: 99, linkedTransactionIds: []),
      );
      f.nodes.addNode(manual);
      for (var repeat = 0; repeat < 2; repeat++) {
        f.nodes.applyTransactionChanges(f.transactions.syncFromPlaid([posted]));
        final money = f.nodes.byId('coffee')!.money!;
        expect(money.linkedTransactionIds, [posted.id, 'unrelated']);
        expect(money.actualAmount, 35); // 12 of other/manual spending retained.
        expect(money.targetAmount, 20);
        expect(f.nodes.byId('manual'), manual);
      }
    });
  }

  test('cross-account predecessor is not used to relink a goal', () async {
    final f = BankSettlementFixture();
    final raw = (await f.plaid.fetchTransactions()).single;
    raw['account_id'] = 'other-account';
    final goal = f.nodes.byId('coffee');
    f.nodes.applyTransactionChanges(
      f.transactions.syncFromPlaid([Transaction.fromPlaid(raw)]),
    );
    expect(f.nodes.byId('coffee'), goal);
    expect(f.transactions.state, hasLength(2));
  });
}
