import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('TransactionsCubit', () {
    test('initial state is an empty list', () {
      final cubit = TransactionsCubit();
      expect(cubit.state, equals([]));
    });

    test('syncFromPlaid adds new transactions', () {
      final cubit = TransactionsCubit();
      final transactions = [
        Transaction(
          id: 'txn_1',
          accountId: 'acc_1',
          amount: -50.0,
          date: DateTime(2025, 10, 1),
          name: 'Grocery Store',
        ),
        Transaction(
          id: 'txn_2',
          accountId: 'acc_1',
          amount: -25.0,
          date: DateTime(2025, 10, 2),
          name: 'Gas Station',
        ),
      ];

      cubit.syncFromPlaid(transactions);
      expect(cubit.state.length, 2);
      expect(cubit.state[0].name, 'Grocery Store');
    });

    test('syncFromPlaid deduplicates by ID', () {
      final cubit = TransactionsCubit();
      final tx = Transaction(
        id: 'txn_1',
        accountId: 'acc_1',
        amount: -50.0,
        date: DateTime(2025, 10, 1),
        name: 'Grocery Store',
      );

      cubit.syncFromPlaid([tx]);
      cubit.syncFromPlaid([tx]); // same ID again
      expect(cubit.state.length, 1);
    });

    test('syncFromPlaid updates same-ID settlement and keeps annotations', () {
      final cubit = TransactionsCubit();
      cubit.syncFromPlaid([
        Transaction(
          id: 'txn_1',
          accountId: 'acc_1',
          amount: -50,
          date: DateTime(2025, 10, 1),
          name: 'Pending Store',
          pending: true,
          assignedExpenseId: 'expense_1',
          assignedNodeId: 'node_1',
          tagIds: const ['tag_1'],
        ),
      ]);

      cubit.syncFromPlaid([
        Transaction(
          id: 'txn_1',
          accountId: 'acc_1',
          amount: -57.5,
          date: DateTime(2025, 10, 2),
          name: 'Settled Store',
          pending: false,
        ),
      ]);

      final settled = cubit.state.single;
      expect(settled.amount, -57.5);
      expect(settled.date, DateTime(2025, 10, 2));
      expect(settled.name, 'Settled Store');
      expect(settled.pending, isFalse);
      expect(settled.assignedExpenseId, 'expense_1');
      expect(settled.assignedNodeId, 'node_1');
      expect(settled.tagIds, ['tag_1']);
    });

    test('syncFromPlaid replaces linked pending row with posted ID', () {
      final cubit = TransactionsCubit();
      cubit.syncFromPlaid([
        Transaction(
          id: 'pending_1',
          accountId: 'acc_1',
          amount: -20,
          date: DateTime(2025, 10, 1),
          name: 'Coffee',
          pending: true,
          assignedNodeId: 'node_1',
          tagIds: const ['tag_1'],
        ),
      ]);

      cubit.syncFromPlaid([
        Transaction.fromPlaid({
          'transaction_id': 'posted_1',
          'account_id': 'acc_1',
          'amount': 23,
          'date': '2025-10-02',
          'name': 'Coffee Shop',
          'pending': false,
          'pending_transaction_id': 'pending_1',
        }),
      ]);

      expect(cubit.state.map((t) => t.id), ['posted_1']);
      expect(cubit.state.single.amount, -23);
      expect(cubit.state.single.pending, isFalse);
      expect(cubit.state.single.assignedNodeId, 'node_1');
      expect(cubit.state.single.tagIds, ['tag_1']);
    });

    test('does not replace a pending row from another account', () {
      final cubit = TransactionsCubit();
      cubit.syncFromPlaid([
        Transaction(
          id: 'pending_1',
          accountId: 'acc_1',
          amount: -20,
          date: DateTime(2025, 10, 1),
          name: 'Coffee',
          pending: true,
        ),
      ]);
      cubit.syncFromPlaid([
        Transaction(
          id: 'posted_1',
          accountId: 'acc_2',
          amount: -23,
          date: DateTime(2025, 10, 2),
          name: 'Coffee Shop',
          pendingTransactionId: 'pending_1',
        ),
      ]);

      expect(cubit.state.map((t) => t.id).toSet(), {'pending_1', 'posted_1'});
    });

    test('assignExpense sets the assignedExpenseId', () {
      final cubit = TransactionsCubit();
      cubit.syncFromPlaid([
        Transaction(
          id: 'txn_1',
          accountId: 'acc_1',
          amount: -50.0,
          date: DateTime(2025, 10, 1),
          name: 'Test',
        ),
      ]);

      cubit.assignExpense('txn_1', 'exp_99');
      expect(cubit.state.first.assignedExpenseId, 'exp_99');
      expect(cubit.state.first.isAssigned, true);
    });

    test('clearAssignment removes the expense assignment', () {
      final cubit = TransactionsCubit();
      cubit.syncFromPlaid([
        Transaction(
          id: 'txn_1',
          accountId: 'acc_1',
          amount: -50.0,
          date: DateTime(2025, 10, 1),
          name: 'Test',
          assignedExpenseId: 'exp_99',
        ),
      ]);

      cubit.clearAssignment('txn_1');
      expect(cubit.state.first.isAssigned, false);
    });

    test('unassignedTransactions filters correctly', () {
      final cubit = TransactionsCubit();
      cubit.syncFromPlaid([
        Transaction(
          id: 'txn_1',
          accountId: 'acc_1',
          amount: -50.0,
          date: DateTime(2025, 10, 1),
          name: 'Unassigned',
        ),
        Transaction(
          id: 'txn_2',
          accountId: 'acc_1',
          amount: -25.0,
          date: DateTime(2025, 10, 2),
          name: 'Assigned',
          assignedExpenseId: 'exp_1',
        ),
      ]);

      expect(cubit.unassignedTransactions.length, 1);
      expect(cubit.unassignedTransactions.first.name, 'Unassigned');
    });

    test('toJson/fromJson roundtrip', () {
      final cubit = TransactionsCubit();
      final tx = Transaction(
        id: 'txn_1',
        accountId: 'acc_1',
        amount: -50.0,
        date: DateTime(2025, 10, 1),
        name: 'Test',
      );
      cubit.syncFromPlaid([tx]);

      final json = cubit.toJson(cubit.state);
      final restored = cubit.fromJson(json!);
      expect(restored?.length, 1);
      expect(restored?.first.id, 'txn_1');
    });

    test('restores transactions without settlement link field', () {
      final cubit = TransactionsCubit();
      final restored = cubit.fromJson({
        'transactions': [
          {
            'id': 'legacy_txn',
            'accountId': 'acc_1',
            'amount': -10,
            'date': '2025-10-01T00:00:00.000',
            'name': 'Legacy',
            'pending': true,
          },
        ],
      });

      expect(restored?.single.pendingTransactionId, isNull);
      expect(restored?.single.pending, isTrue);
    });
  });
}
