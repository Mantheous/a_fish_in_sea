import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_budget_progress.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('Duplicate subtree starts a money goal without purchases', (
    $,
  ) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidgetAndSettle(const MyApp());
    final now = DateTime.now();
    await $(TextField)
        .at(0)
        .enterText(
          'patrol-duplicate-${now.microsecondsSinceEpoch}@example.com',
        );
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    await $(Icons.menu).tap();
    await $('Goals').tap();
    await $.pumpAndSettle();

    final context = $.tester.element(find.byType(NodesPage));
    final nodes = context.read<NodeCubit>();
    final transactions = context.read<TransactionsCubit>();
    final budget = Node(
      id: 'budget',
      title: 'Monthly budget',
      createdAt: now,
      money: const MoneyFacet(targetAmount: 500, period: TimeScale.monthly),
    );
    nodes.addNode(budget);
    nodes.addNode(
      Node(
        id: 'groceries',
        title: 'Groceries',
        createdAt: now,
        parentIds: const ['budget'],
        money: const MoneyFacet(targetAmount: 50),
      ),
    );
    transactions.syncFromPlaid([
      Transaction(
        id: 'purchase',
        accountId: 'checking',
        amount: -50,
        date: now,
        name: 'Grocery store',
      ),
    ]);
    nodes.linkTransaction(
      nodeId: 'groceries',
      transactionId: 'purchase',
      transactionAmount: -50,
    );
    transactions.assignNode('purchase', 'groceries');
    final original = nodes.byId('groceries')!;
    final originalTransactions = transactions.state;
    double spending() => moneyActualForActivePeriod(
      budget,
      nodes.state,
      transactions.state,
      now: now,
    );
    expect(spending(), 50);

    await $('Goal tree').tap();
    await $.pumpAndSettle();
    await $(Icons.unfold_more).tap();
    await $.pumpAndSettle();
    final row = find.ancestor(
      of: find.text('Groceries'),
      matching: find.byType(ListTile),
    );
    await $.tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.more_vert)),
    );
    await $.pumpAndSettle();
    await $('Duplicate subtree').tap();
    await $.pumpAndSettle();

    expect($('Groceries (copy)').visible, isTrue);
    final copy = nodes.state.singleWhere((n) => n.title == 'Groceries (copy)');
    expect(copy.parentIds, ['budget']);
    expect(copy.money?.status, MoneyStatus.projected);
    expect(copy.money?.actualAmount, isNull);
    expect(copy.money?.linkedTransactionIds, isEmpty);
    expect(nodes.byId('groceries'), original);
    expect(transactions.state, originalTransactions);
    expect(transactions.state.single.assignedNodeId, original.id);
    expect(spending(), 50);
    expect($.tester.takeException(), isNull);
  });
}
