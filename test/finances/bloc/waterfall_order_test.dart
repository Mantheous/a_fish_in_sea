import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class TestPlaidCubit extends PlaidCubit {
  void setBalance(double balance) =>
      emit(state.copyWith(currentBalance: balance));
}

/// Regression test for the ledger ordering bug: confirmed rows were
/// assembled before projected rows (so rows.first was today's balance,
/// not the horizon projection), and any unconfirmed entry dated before
/// the newest confirmed item was subtracted backward as if settled.
void main() {
  late NodeCubit nodes;
  late TransactionsCubit transactions;
  late TestPlaidCubit plaid;
  late WaterfallCubit waterfall;

  Node moneyNode(
    String id,
    DateTime due, {
    required double spend,
    MoneyStatus status = MoneyStatus.projected,
  }) =>
      Node(
        id: id,
        title: id,
        createdAt: DateTime(2026, 1, 1),
        schedule: ScheduleFacet(due: due),
        money: MoneyFacet(
          targetAmount: spend,
          direction: MoneyDirection.spend,
          status: status,
        ),
      );

  Transaction txn(
    String id,
    DateTime date, {
    required double amount,
    bool pending = false,
  }) =>
      Transaction(
        id: id,
        accountId: 'acct',
        amount: amount,
        date: date,
        name: id,
        pending: pending,
      );

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
    transactions = TransactionsCubit();
    plaid = TestPlaidCubit();
    waterfall = WaterfallCubit(
      nodeCubit: nodes,
      transactionsCubit: transactions,
      plaidCubit: plaid,
    );
  });

  tearDown(() async {
    await waterfall.close();
    await nodes.close();
    await transactions.close();
    await plaid.close();
  });

  test(
    'mixed confirmed/overdue/pending/future-paid fixture orders newest-first',
    () async {
      final now = DateTime.now();
      final day = Duration(days: 1);
      plaid.setBalance(1000);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      transactions.syncFromPlaid([
        // Settled spend 10 days ago.
        txn('confirmed-past', now.subtract(day * 10), amount: -100),
        // Still at the bank: must project forward, not settle backward.
        txn('pending-tx', now.subtract(day * 1),
            amount: -30, pending: true),
      ]);
      nodes.emitSilent([
        // Overdue estimate dated BEFORE the settled entry.
        moneyNode('overdue', now.subtract(day * 20), spend: 50),
        // Due in the future.
        moneyNode('future-due', now.add(day * 5),
            spend: 200, status: MoneyStatus.due),
        // Settled early: moves only itself into history.
        moneyNode('future-paid', now.add(day * 10),
            spend: 40, status: MoneyStatus.paid),
      ]);
      waterfall.rebuild();

      final rows = waterfall.state.rows;
      expect(
        rows.map((e) => e.sourceId).toList(),
        ['future-due', 'pending-tx', 'overdue', 'future-paid', 'confirmed-past'],
      );

      // Projected side steps forward from today's balance …
      expect(rows[0].runningBalance, 1000 - 50 - 30 - 200);
      expect(rows[1].runningBalance, 1000 - 50 - 30);
      expect(rows[2].runningBalance, 1000 - 50);
      // … confirmed side steps backward from today's balance.
      expect(rows[3].runningBalance, 1000);
      expect(rows[3].status, EntryStatus.confirmed);
      expect(rows[4].runningBalance, 1000 + 40);
      expect(rows[4].status, EntryStatus.confirmed);

      // The "Projected" header binds to rows.first: the horizon value.
      expect(rows.first.runningBalance, 720.0);

      // Overdue + pending sit on the projection side of the present line.
      final presentIndex =
          rows.indexWhere((e) => e.status == EntryStatus.confirmed);
      expect(presentIndex, 3);
      expect(rows[2].status, isNot(EntryStatus.confirmed));
    },
  );
}
