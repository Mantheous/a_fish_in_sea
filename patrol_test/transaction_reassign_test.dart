import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/finances/view/transaction_assignment_dialog.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Reassign + unassign through the real assignment dialog on current main.
///
/// Covers the issue #76 user flow: moving an assigned bank transaction to
/// a different budget item counts the money exactly once (old item resets
/// to unpaid), and Unassign clears the link entirely. Uses the production
/// atomic unlink+link path (single undo step, accumulate-and-subtract),
/// so this locks the fixed behavior instead of a parallel helper.
///
/// Run headless (no server needed — pure widgets, like smoke_test):
///   patrol test --device chrome --web-headless \
///     --target patrol_test/transaction_reassign_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
void main() {
  patrolTest('reassign moves the money; unassign clears it', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    final nodes = NodeCubit();
    final txns = TransactionsCubit();
    addTearDown(() async {
      await nodes.close();
      await txns.close();
    });

    Node money(String id, String title) => Node(
          id: id,
          title: title,
          createdAt: DateTime(2026, 9, 1),
          schedule: ScheduleFacet(due: DateTime(2026, 9, 12)),
          money: const MoneyFacet(
              targetAmount: 100, direction: MoneyDirection.spend),
        );
    nodes.addNode(money('node-a', 'Groceries A'));
    nodes.addNode(money('node-b', 'Groceries B'));
    txns.syncFromPlaid([
      Transaction(
        id: 'tx-1',
        accountId: 'a1',
        amount: -60,
        date: DateTime(2026, 9, 12),
        name: 'Grocery Store',
      ),
    ]);
    // Pre-assign to A through the production path (link + assign).
    nodes.linkTransaction(
        nodeId: 'node-a', transactionId: 'tx-1', transactionAmount: -60);
    txns.assignNode('tx-1', 'node-a');
    expect(nodes.byId('node-a')?.money?.status, MoneyStatus.paid);

    Transaction fresh() =>
        txns.state.singleWhere((t) => t.id == 'tx-1');

    await $.pumpWidgetAndSettle(
      MultiBlocProvider(
        providers: [
          BlocProvider<NodeCubit>.value(value: nodes),
          BlocProvider<TransactionsCubit>.value(value: txns),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return FilledButton(
                onPressed: () => showDialog(
                  context: context,
                  // Fresh snapshot: the dialog reads assignedNodeId from
                  // the passed transaction, so callers must pass the
                  // current cubit state (as the ledger does).
                  builder: (_) =>
                      TransactionAssignmentDialog(transaction: fresh()),
                ),
                child: const Text('Open dialog'),
              );
            }),
          ),
        ),
      ),
    );

    // Reassign: the dialog offers the other open node plus an Unassign
    // action for the current assignment; tapping the other node moves the
    // money instead of double-counting it.
    await $('Open dialog').tap();
    await $.pumpAndSettle();
    expect($('Unassign').visible, true);
    await $('Groceries B').tap();
    await $.pumpAndSettle();
    expect(nodes.byId('node-a')?.money?.status, MoneyStatus.projected);
    expect(nodes.byId('node-a')?.money?.actualAmount, isNull);
    expect(nodes.byId('node-a')?.money?.linkedTransactionIds, isEmpty);
    expect(nodes.byId('node-b')?.money?.status, MoneyStatus.paid);
    expect(nodes.byId('node-b')?.money?.actualAmount, 60);
    expect(nodes.byId('node-b')?.money?.linkedTransactionIds, ['tx-1']);
    expect(txns.state.single.assignedNodeId, 'node-b');

    // Unassign: clears the new link and resets the node.
    await $('Open dialog').tap();
    await $.pumpAndSettle();
    expect($('Unassign').visible, true);
    await $('Unassign').tap();
    await $.pumpAndSettle();
    expect(txns.state.single.assignedNodeId, isNull);
    expect(nodes.byId('node-b')?.money?.status, MoneyStatus.projected);
    expect(nodes.byId('node-b')?.money?.actualAmount, isNull);
    expect(nodes.byId('node-b')?.money?.linkedTransactionIds, isEmpty);
  });
}
