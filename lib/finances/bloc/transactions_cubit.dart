import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

/// Manages imported bank transactions from Plaid.
///
/// Transactions are **immutable** once imported — the only mutable
/// operation is assigning an expense to a transaction for reconciliation.
class TransactionsCubit extends HydratedCubit<List<Transaction>> {
  TransactionsCubit() : super([]);

  // ── Import from Plaid ───────────────────────────────────────────────

  /// Bulk import transactions from Plaid, deduplicating by transaction ID.
  void syncFromPlaid(List<Transaction> plaidTransactions) {
    final existingIds = state.map((t) => t.id).toSet();
    final newTransactions =
        plaidTransactions.where((t) => !existingIds.contains(t.id)).toList();

    if (newTransactions.isNotEmpty) {
      emit([...state, ...newTransactions]);
    }
  }

  // ── Expense assignment ──────────────────────────────────────────────

  /// Assign a transaction to an expense for reconciliation.
  /// This is the only mutation allowed on a transaction.
  void assignExpense(String transactionId, String expenseId) {
    emit(state.map((t) {
      if (t.id == transactionId) {
        return t.copyWith(assignedExpenseId: expenseId);
      }
      return t;
    }).toList());
  }

  /// Clear the expense assignment from a transaction.
  void clearAssignment(String transactionId) {
    emit(state.map((t) {
      if (t.id == transactionId) {
        return t.copyWith(clearAssignment: true);
      }
      return t;
    }).toList());
  }

  // ── Queries ─────────────────────────────────────────────────────────

  /// Returns transactions that have not been assigned to any expense.
  List<Transaction> get unassignedTransactions =>
      state.where((t) => !t.isAssigned).toList();

  /// Returns transactions assigned to a specific expense.
  List<Transaction> transactionsForExpense(String expenseId) =>
      state.where((t) => t.assignedExpenseId == expenseId).toList();

  /// Auto-categorization: find past transactions with the same name
  /// and return the expense ID they were assigned to (if any).
  /// Returns null if no match found.
  String? suggestExpenseForTransaction(String transactionName) {
    final matches = state.where(
        (t) => t.isAssigned && t.name.toLowerCase() == transactionName.toLowerCase());
    if (matches.isNotEmpty) {
      return matches.first.assignedExpenseId;
    }
    return null;
  }

  // ── Persistence ─────────────────────────────────────────────────────

  @override
  List<Transaction>? fromJson(Map<String, dynamic> json) {
    return (json['transactions'] as List<dynamic>?)
        ?.map((e) => Transaction.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Map<String, dynamic>? toJson(List<Transaction> state) {
    return {'transactions': state.map((t) => t.toJson()).toList()};
  }
}
