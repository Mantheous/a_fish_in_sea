// import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
// import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
// import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
// import 'package:a_fish_in_sea/finances/model/transaction.dart';
// import 'package:flutter_test/flutter_test.dart';
// import 'package:hydrated_bloc/hydrated_bloc.dart';
// import 'package:mocktail/mocktail.dart';

// class MockStorage extends Mock implements Storage {}

// void main() {
//   late Storage storage;
//   late ExpensesCubit expensesCubit;

//   setUp(() {
//     storage = MockStorage();

//     // Setup standard mock behavior
//     when(() => storage.read(any())).thenReturn(null);
//     when(() => storage.write(any(), any())).thenAnswer((_) async {});

//     // Use HydratedBloc here
//     HydratedBloc.storage = storage;
//     expensesCubit = ExpensesCubit();
//   });

//   group('TransactionsCubit', () {
//     test('initial state is an empty list', () {
//       final transactionsCubit = TransactionsCubit(expensesCubit);
//       expect(transactionsCubit.state, equals([]));
//     });

//     group('importCsv', () {
//       test('loads and parses CSV data correctly', () {
//         // This function needs some major modifications first

//         // final transactionsCubit = TransactionsCubit(expensesCubit);
//         // await transactionsCubit.importCsv();
//         // expect(transactionsCubit.state.isNotEmpty, isTrue);
//         // expect(transactionsCubit.state.first, isA<Transaction>());
//       });

//       test('handles errors when the CSV file is not found or malformed', () {
//         // TODO: Implement test
//       });

//       test('does not add duplicate transactions', () {
//         // TODO: Implement test
//       });
//     });

//     test('changeTransactionExpenseType updates the type of a transaction', () {
//       // TODO: Implement test
//     });

//     group('Serialization', () {
//       test('toJson/fromJson roundtrip', () {
//         final transactionsCubit = TransactionsCubit(expensesCubit);
//         final transaction1 = Transaction(
//           date: DateTime.now(),
//           amount: 100.0,
//           description: 'Test',
//         );
//         final transaction2 = Transaction(
//           date: DateTime.now(),
//           amount: 200.0,
//           description: 'Test2',
//         );
//         // transactionsCubit.addTransaction(transaction1); // Functions that probably will never exist
//         // transactionsCubit.addTransaction(transaction2);

//         final json = transactionsCubit.toJson(transactionsCubit.state);
//         final restoredState = transactionsCubit.fromJson(json!);

//         expect(restoredState, equals([transaction1, transaction2]));
//       });

//       test('fromJson handles empty or invalid data', () {
//         // TODO: Implement test
//       });

//       test('toJson handles an empty list of transactions', () {
//         // TODO: Implement test
//       });
//     });
//   });
// }
