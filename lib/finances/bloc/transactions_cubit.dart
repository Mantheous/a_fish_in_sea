import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

// TODO Before production this needs to be switched over a better solution
// I should use Plaid API to get the data dirrectly from the bank.
// This will also resolve the edge case where there are duplicate enteries
// that interupt a merge

class TransactionsCubit extends HydratedCubit<List<Transaction>> {
  TransactionsCubit() : super([]);

  Future<List<List<dynamic>>> loadData() async {
    final csvString = await rootBundle.loadString(
      'lib/data/2025-10-11_AshtonChecking...9371.csv',
    );
    final bigList = CsvToListConverter().convert(csvString);

    return bigList;
  }

  Future<void> importCsv() async {
    final csvString = await rootBundle.loadString(
      'lib/data/2025-10-11_AshtonChecking...9371.csv',
    );
    final bigList = CsvToListConverter(eol: '\n').convert(csvString);
    emit(bigList.skip(1).map((r) => Transaction.fromCSVRow(r)).toList());
  }

  void changeTransactionExpenseType(
    Transaction transaction,
    ExpenseCatagory newType,
  ) {
    transaction.type = newType;
    emit(List.from(state));
  }

  // TODO Handle Duplicates
  // Future<void> importCsv(File file) async {
  //   final incoming = await readTransactionsFromCsv(file);

  //   final existingIds = state.transactions.map((t) => t.id).toSet();

  //   final newTransactions = incoming
  //       .where((t) => !existingIds.contains(t.id))
  //       .toList();

  //   if (newTransactions.isEmpty) return;

  //   emit(TransactionState([
  //     ...state.transactions,
  //     ...newTransactions,
  //   ]));
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
