import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';

/// Manages imported bank transactions from Plaid.
///
/// Transactions are **immutable** once imported — the only mutable
/// operation is assigning an expense to a transaction for reconciliation.
class TransactionsCubit extends RevertableHydratedCubit<List<Transaction>> {
  TransactionsCubit() : super([]);

  // ── Import from Plaid ───────────────────────────────────────────────

  /// Bulk import transactions from Plaid, deduplicating by transaction ID.
  void syncFromPlaid(List<Transaction> plaidTransactions) {
    final existingIds = state.map((t) => t.id).toSet();
    final newTransactions = plaidTransactions
        .where((t) => !existingIds.contains(t.id))
        .toList();

    if (newTransactions.isNotEmpty) {
      emit([...state, ...newTransactions]);
    }
  }

  // ── Expense assignment ──────────────────────────────────────────────

  /// Assign a transaction to an expense for reconciliation.
  /// This is the only mutation allowed on a transaction.
  void assignExpense(String transactionId, String expenseId) {
    emitChange(
      state.map((t) {
        if (t.id == transactionId) {
          return t.copyWith(assignedExpenseId: expenseId);
        }
        return t;
      }).toList(),
    );
  }

  /// Clear the expense assignment from a transaction.
  void clearAssignment(String transactionId) {
    emitChange(
      state.map((t) {
        if (t.id == transactionId) {
          return t.copyWith(clearAssignment: true);
        }
        return t;
      }).toList(),
    );
  }

  // ── Node assignment (unified goals/tasks) ───────────────────────────
  //
  // Additive successor to expense assignment. Sets `assignedNodeId`
  // without touching `assignedExpenseId`, so legacy reconciliation
  // history survives untouched.

  /// Assign a transaction to a unified node for automatic reporting.
  void assignNode(
    String transactionId,
    String nodeId, {
    bool recordUndo = true,
  }) {
    final next = state.map((t) {
      if (t.id == transactionId) {
        return t.copyWith(assignedNodeId: nodeId);
      }
      return t;
    }).toList();
    if (recordUndo) {
      emitChange(next);
    } else {
      emit(next);
    }
  }

  /// Clear the node assignment from a transaction.
  void clearNodeAssignment(String transactionId) {
    emitChange(
      state.map((t) {
        if (t.id == transactionId) {
          return t.copyWith(clearNodeAssignment: true);
        }
        return t;
      }).toList(),
    );
  }

  /// Clear node references after a node or cascade of nodes is deleted.
  /// Returns how many transactions changed.
  int clearNodeAssignmentsFor(Set<String> nodeIds) {
    if (nodeIds.isEmpty) return 0;
    var changed = 0;
    final next = state.map((t) {
      if (t.assignedNodeId != null && nodeIds.contains(t.assignedNodeId)) {
        changed++;
        return t.copyWith(clearNodeAssignment: true);
      }
      return t;
    }).toList();
    if (changed > 0) emitChange(next);
    return changed;
  }

  // ── Queries ─────────────────────────────────────────────────────────

  /// Returns transactions that have not been assigned to any expense.
  List<Transaction> get unassignedTransactions =>
      state.where((t) => !t.isAssigned).toList();

  /// Returns transactions not reconciled by either mechanism.
  List<Transaction> get unreconciledTransactions =>
      state.where((t) => !t.isReconciled).toList();

  /// Returns transactions assigned to a specific expense.
  List<Transaction> transactionsForExpense(String expenseId) =>
      state.where((t) => t.assignedExpenseId == expenseId).toList();

  /// Returns transactions assigned to a specific unified node.
  List<Transaction> transactionsForNode(String nodeId) =>
      state.where((t) => t.assignedNodeId == nodeId).toList();

  /// Auto-categorization: find past transactions with the same name
  /// and return the expense ID they were assigned to (if any).
  /// Returns null if no match found.
  String? suggestExpenseForTransaction(String transactionName) {
    final matches = state.where(
      (t) =>
          t.isAssigned && t.name.toLowerCase() == transactionName.toLowerCase(),
    );
    if (matches.isNotEmpty) {
      return matches.first.assignedExpenseId;
    }
    return null;
  }

  /// Node successor to [suggestExpenseForTransaction]: suggest the node
  /// a same-named transaction reported to before. Points at a node id,
  /// never a category string or tag.
  String? suggestNodeForTransaction(String transactionName) {
    final matches =
        state
            .where(
              (t) =>
                  t.isAssignedToNode &&
                  t.name.toLowerCase() == transactionName.toLowerCase(),
            )
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    return matches.isEmpty ? null : matches.first.assignedNodeId;
  }

  // ── Persistence ─────────────────────────────────────────────────────

  /// Sync apply: replaces state from a merged envelope (no undo record).
  void applySyncedJson(Map<String, dynamic> json) {
    final restored = fromJson(json);
    if (restored != null) emit(restored);
  }

  @override
  List<Transaction>? fromJson(Map<String, dynamic> json) {
    final list = json['transactions'] as List<dynamic>?;
    if (list == null) return null;
    final out = <Transaction>[];
    for (final item in list) {
      try {
        out.add(Transaction.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic>? toJson(List<Transaction> state) {
    return {'transactions': state.map((t) => t.toJson()).toList()};
  }
}
