import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';

/// Manages the list of user-created [Expense]s with prefab-style operations.
///
/// Provides CRUD plus subdivision, merging, field override/revert,
/// and linking expenses to real Plaid transactions.
class ExpenseCubit extends HydratedCubit<List<Expense>> {
  ExpenseCubit() : super([]);

  // ── CRUD ────────────────────────────────────────────────────────────

  void addExpense(Expense expense) => emit([...state, expense]);

  void updateExpense(Expense updated) {
    emit(state.map((e) => e.id == updated.id ? updated : e).toList());
  }

  void deleteExpense(String expenseId) {
    emit(state.where((e) => e.id != expenseId).toList());
  }

  /// Find an expense by ID (returns null if not found).
  Expense? findById(String id) {
    try {
      return state.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  // ── Prefab operations ───────────────────────────────────────────────

  /// Override a single field on an expense, tracking it as divergent
  /// from the parent template.
  void overrideExpenseField(String expenseId, String fieldName, dynamic value) {
    final expense = findById(expenseId);
    if (expense == null) return;
    updateExpense(expense.overrideField(fieldName, value));
  }

  /// Revert an overridden field so it re-inherits from the parent.
  /// Resolves the parent value and applies it.
  void revertExpenseField(String expenseId, String fieldName) {
    final expense = findById(expenseId);
    if (expense == null) return;

    if (expense.parentExpenseId != null) {
      final parent = findById(expense.parentExpenseId!);
      if (parent != null) {
        // Re-inherit the parent's value for this field
        var reverted = expense.revertField(fieldName);
        switch (fieldName) {
          case 'name':
            reverted = reverted.copyWith(name: parent.name);
            break;
          case 'amount':
            reverted = reverted.copyWith(amount: parent.amount);
            break;
          case 'date':
            reverted = reverted.copyWith(date: parent.date);
            break;
          case 'category':
            reverted = reverted.copyWith(category: parent.category);
            break;
        }
        updateExpense(reverted);
        return;
      }
    }
    // No parent — just clear the override flag
    updateExpense(expense.revertField(fieldName));
  }

  // ── Subdivision / Merge ─────────────────────────────────────────────

  /// Split an expense into two parts: one for [splitAmount] and one for
  /// the remainder.  The original expense is updated in-place; the
  /// remainder is added as a new expense.
  void subdivideExpense(String expenseId, double splitAmount) {
    final expense = findById(expenseId);
    if (expense == null) return;

    final parts = expense.subdivide(splitAmount);
    final updated = state.map((e) => e.id == expenseId ? parts[0] : e).toList();
    updated.add(parts[1]);
    emit(updated);
  }

  /// Merge two expenses into one.  The first expense absorbs the second's
  /// amount; the second is deleted.
  void mergeExpenses(String keepId, String absorbId) {
    final keep = findById(keepId);
    final absorb = findById(absorbId);
    if (keep == null || absorb == null) return;

    final merged = keep.copyWith(
      amount: keep.amount + absorb.amount,
      overriddenFields: {...keep.overriddenFields, 'amount'},
    );

    emit(state
        .where((e) => e.id != absorbId)
        .map((e) => e.id == keepId ? merged : e)
        .toList());
  }

  // ── Transaction linking ─────────────────────────────────────────────

  /// Link an expense to a real Plaid transaction, making it concrete.
  /// If the transaction amount differs from the expense, handles
  /// subdivision or over-budget logging per the spec.
  void linkToTransaction({
    required String expenseId,
    required String transactionId,
    required double transactionAmount,
  }) {
    final expense = findById(expenseId);
    if (expense == null) return;

    final expenseAbs = expense.amount.abs();
    final transactionAbs = transactionAmount.abs();

    if ((expenseAbs - transactionAbs).abs() < 0.01) {
      // Exact match — just make concrete
      updateExpense(expense.makeConcrete(transactionId));
    } else if (transactionAbs < expenseAbs) {
      // Transaction is smaller → subdivide, make the matched part concrete
      final parts = expense.subdivide(transactionAbs);
      final concreteExpense = parts[0].makeConcrete(transactionId);

      final updated = state
          .map((e) => e.id == expenseId ? concreteExpense : e)
          .toList();
      updated.add(parts[1]); // remainder expense
      emit(updated);
    } else {
      // Transaction is larger → log as over-budget (expense gets the
      // actual transaction amount)
      final overBudget = expense.copyWith(
        amount: transactionAmount,
        overriddenFields: {...expense.overriddenFields, 'amount'},
      ).makeConcrete(transactionId);
      updateExpense(overBudget);
    }
  }

  // ── Bulk operations ─────────────────────────────────────────────────

  /// Add multiple expenses at once (e.g. from recurring rule generation).
  void addAll(List<Expense> expenses) {
    // Deduplicate by ID
    final existingIds = state.map((e) => e.id).toSet();
    final newExpenses = expenses.where((e) => !existingIds.contains(e.id)).toList();
    if (newExpenses.isNotEmpty) {
      emit([...state, ...newExpenses]);
    }
  }

  // ── Persistence ─────────────────────────────────────────────────────

  @override
  List<Expense>? fromJson(Map<String, dynamic> json) {
    final list = json['expenses'] as List<dynamic>?;
    if (list == null) return null;
    final out = <Expense>[];
    for (final item in list) {
      try {
        out.add(Expense.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<Expense> state) {
    return {'expenses': state.map((e) => e.toJson()).toList()};
  }
}
