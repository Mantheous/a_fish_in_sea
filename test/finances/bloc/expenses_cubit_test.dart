import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';

// Create a Mock for the HydratedStorage
class MockStorage extends Mock implements Storage {}

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();

    // Setup standard mock behavior
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});

    // Use HydratedBloc here
    HydratedBloc.storage = storage;
  });

  group('ExpensesCubit', () {
    test('initial state is an empty list', () {
      final expensesCubit = ExpensesCubit();
      expect(expensesCubit.state, equals([]));
    });

    test('addExpense adds an expense to the state', () {
      final expensesCubit = ExpensesCubit();
      final expense = Expense(name: 'Test', maxAmount: 100.0);
      expensesCubit.addExpense(expense);
      expect(expensesCubit.state, equals([expense]));
    });

    test('modifyExpense updates an existing expense', () {
      final expensesCubit = ExpensesCubit();
      final oldExpense = Expense(name: 'Old', maxAmount: 100.0);
      final newExpense = Expense(name: 'New', maxAmount: 200.0);
      expensesCubit.addExpense(oldExpense);
      expensesCubit.modifyExpense(
        oldExpense: oldExpense,
        newExpense: newExpense,
      );
      expect(expensesCubit.state, equals([newExpense]));
    });

    test('clean removes all expenses from the state', () {
      final expensesCubit = ExpensesCubit();
      final expense = Expense(name: 'Test', maxAmount: 100.0);
      expensesCubit.addExpense(expense);
      expensesCubit.clean();
      expect(expensesCubit.state, equals([]));
    });

    group('Serialization', () {
      test('toJson/fromJson roundtrip', () {
        final expensesCubit = ExpensesCubit();
        final expense1 = Expense(name: 'Expense1', maxAmount: 100.0);
        final expense2 = Expense(name: 'Expense2', maxAmount: 200.0);
        expensesCubit.addExpense(expense1);
        expensesCubit.addExpense(expense2);

        final json = expensesCubit.toJson(expensesCubit.state);
        final restoredState = expensesCubit.fromJson(json);

        expect(restoredState, equals([expense1, expense2]));
      });

      test('fromJson handles invalid data', () {
        final expensesCubit = ExpensesCubit();
        final restoredState = expensesCubit.fromJson({});
        expect(restoredState, null);
      });

      test('fromJson handles empty data', () {
        final expensesCubit = ExpensesCubit();
        final restoredState = expensesCubit.fromJson({"expenses": []});
        expect(restoredState, equals([]));
      });

      test('toJson handles an empty list of expenses', () {
        final expensesCubit = ExpensesCubit();
        final json = expensesCubit.toJson([]);
        expect(json, equals({"expenses": []}));
      });
    });
  });
}
