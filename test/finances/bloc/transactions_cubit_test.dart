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
  });
}
