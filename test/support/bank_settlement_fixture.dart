import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/finances/view/plaid_link_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_budget_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

class SettlementPlaid extends PlaidCubit {
  SettlementPlaid() : super(userId: 'settlement-test') {
    emit(state.copyWith(status: PlaidConnectionStatus.connected));
  }

  @override
  Future<void> fetchBalance() async {}
  @override
  Future<List<Map<String, dynamic>>> fetchTransactions() async => [
    {
      'transaction_id': 'posted',
      'pending_transaction_id': 'pending',
      'account_id': 'checking',
      'amount': 23,
      'date': '2026-11-01',
      'name': 'Coffee Shop',
      'pending': false,
    },
  ];
}

class BankSettlementFixture {
  late final NodeCubit nodes;
  late final TransactionsCubit transactions;
  late final SettlementPlaid plaid;
  late final WaterfallCubit waterfall;

  BankSettlementFixture() {
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
    transactions = TransactionsCubit();
    plaid = SettlementPlaid();
    waterfall = WaterfallCubit(
      nodeCubit: nodes,
      transactionsCubit: transactions,
      plaidCubit: plaid,
    );
    final date = DateTime(2026, 11, 1);
    nodes.addNode(
      Node(
        id: 'budget',
        title: 'Monthly budget',
        createdAt: date,
        money: const MoneyFacet(targetAmount: 500, period: TimeScale.monthly),
      ),
    );
    nodes.addNode(
      Node(
        id: 'coffee',
        title: 'Coffee',
        createdAt: date,
        parentIds: const ['budget'],
        schedule: ScheduleFacet(due: date),
        money: const MoneyFacet(targetAmount: 20),
      ),
    );
    transactions.syncFromPlaid([
      Transaction(
        id: 'pending',
        accountId: 'checking',
        amount: -20,
        date: date,
        name: 'Coffee',
        pending: true,
      ),
    ]);
    nodes.linkTransaction(
      nodeId: 'coffee',
      transactionId: 'pending',
      transactionAmount: -20,
    );
    transactions.assignNode('pending', 'coffee');
    addTearDown(() async {
      await waterfall.close();
      await plaid.close();
      await transactions.close();
      await nodes.close();
    });
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<NodeCubit>.value(value: nodes),
        BlocProvider<TransactionsCubit>.value(value: transactions),
        BlocProvider<PlaidCubit>.value(value: plaid),
      ],
      child: const MaterialApp(home: PlaidLinkPage(showDrawer: false)),
    ),
  );

  void verify() {
    final money = nodes.byId('coffee')!.money!;
    expect(money.linkedTransactionIds, ['posted']);
    expect(money.actualAmount, 23);
    expect(money.status, MoneyStatus.paid);
    expect(transactions.state.single.assignedNodeId, 'coffee');
    expect(
      moneyActualForActivePeriod(
        nodes.byId('budget')!,
        nodes.state,
        transactions.state,
        now: DateTime(2026, 11, 1),
      ),
      23,
    );
    waterfall.rebuild();
    expect(waterfall.state.rows.map((row) => row.sourceId), ['posted']);
    expect(waterfall.state.rows.single.amount, -23);
  }
}
