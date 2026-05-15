import 'dart:convert';

import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';

// TODO Before production this needs to be switched over a better solution
// I should use Plaid API to get the data dirrectly from the bank.
// This will also resolve the edge case where there are duplicate enteries
// that interupt a merge

class TransactionsCubit extends HydratedCubit<List<Transaction>> {
  final ExpensesCubit expensesCubit;
  List<int> loadedTransactionIds = const [];
  bool showAllTransactions = true;

  TransactionsCubit(this.expensesCubit) : super([]);

  void pickNewCSV() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();

    if (result != null) {
      //importCsv(result.files.single.path!);
      final file = File(result.files.single.path!).openRead();
      final fields = await file
          .transform(utf8.decoder)
          .transform(CsvToListConverter())
          .toList();
      final loadedIds = state.map((t) => t.id).toList();
      List<Transaction> newState = fields
          .skip(1)
          .map((r) => Transaction.fromCSVRow(r))
          .where((t) => !loadedIds.contains(t.id))
          .toList();
      emit(newState);
      loadedTransactionIds = newState.map((t) => t.id).toList();
    } else {
      // User canceled the picker
    }
  }

  // Depreciated
  Future<void> importCsv(String path) async {
    final csvString = await rootBundle.loadString(path);
    final bigList = CsvToListConverter(eol: '\n').convert(csvString);
    final loadedIds = state.map((t) => t.id).toList();
    List<Transaction> newState = bigList
        .skip(1)
        .map((r) => Transaction.fromCSVRow(r))
        .where((t) => !loadedIds.contains(t.id))
        .toList();
    emit(newState);
    loadedTransactionIds = newState.map((t) => t.id).toList();
  }

  // So that we can look at the current CSV file or all of the transactions
  List<Transaction> get loadedTransactions {
    if (showAllTransactions) {
      return state;
    }
    return state.where((t) => loadedTransactionIds.contains(t.id)).toList();
  }

  void setExpense(Transaction transaction, Expense expense) {
    final oldExpense = transaction.assignedExpense;

    // Associate the transaction with the new expense
    transaction.assignedExpense = expense;

    // Add transaction to the new expense transactions list if it's not already present
    final newExpenseTxns = List<Transaction>.from(expense.transactions);
    final existsInNew = newExpenseTxns.any(
      (t) => t.isSameTransaction(transaction),
    );
    if (!existsInNew) {
      newExpenseTxns.add(transaction);
    }
    final newExpense = expense.copyWith(transactions: newExpenseTxns);
    expensesCubit.modifyExpense(oldExpense: expense, newExpense: newExpense);

    // If it was previously assigned to a different expense, remove it from that expense
    if (oldExpense != null && oldExpense.name != expense.name) {
      final oldTxns = List<Transaction>.from(oldExpense.transactions);
      oldTxns.removeWhere((t) => t.isSameTransaction(transaction));
      final updatedOld = oldExpense.copyWith(transactions: oldTxns);
      expensesCubit.modifyExpense(
        oldExpense: oldExpense,
        newExpense: updatedOld,
      );
    }

    emit(List.from(state));
  }

  // void changeTransactionExpenseType(
  //   Transaction transaction,
  //   ExpenseCategory newType,
  // ) {
  //   transaction.type = newType;
  //   emit(List.from(state));
  // }

  @override
  List<Transaction>? fromJson(Map<String, dynamic> json) {
    return (json['transactions'] as List)
        .map((e) => Transaction.fromJson(e))
        .toList();
  }

  @override
  Map<String, dynamic>? toJson(List<Transaction> state) {
    return {'transactions': state.map((t) => t.toJson()).toList()};
  }
}
