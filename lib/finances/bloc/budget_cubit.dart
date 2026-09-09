import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';

/// Manages the list of [Budget] goals.
///
/// Provides CRUD operations, manual/automatic rollover between periods,
/// and computed budget status (spent, remaining, over-budget).
class BudgetCubit extends HydratedCubit<List<Budget>> {
  BudgetCubit() : super([]);

  // ── CRUD ────────────────────────────────────────────────────────────

  void addBudget(Budget budget) => emit([...state, budget]);

  void updateBudget(Budget updated) {
    emit(state.map((b) => b.id == updated.id ? updated : b).toList());
  }

  void deleteBudget(String budgetId) {
    emit(state.where((b) => b.id != budgetId).toList());
  }

  Budget? findById(String id) {
    try {
      return state.firstWhere((b) => b.id == id);
    } catch (_) {
      return null;
    }
  }

  // ── Rollover ────────────────────────────────────────────────────────

  /// Manually roll over surplus/deficit from the current period to the next.
  /// [spentAmount] is the total amount spent in the current period (positive).
  void rolloverBudget(String budgetId, double spentAmount) {
    final budget = findById(budgetId);
    if (budget == null || !budget.isRecurring) return;

    final surplus = budget.goalAmount - spentAmount;
    updateBudget(budget.copyWith(
      rolloverAmount: budget.rolloverAmount + surplus,
    ));
  }

  /// Check all recurring budgets and auto-rollover any whose period
  /// has ended.  Call this periodically (e.g. on app startup).
  void checkAutoRollover(List<Expense> expenses) {
    final now = DateTime.now();
    final updated = state.map((budget) {
      if (!budget.isRecurring || !budget.autoRollover) return budget;

      final periodEnd = budget.currentPeriodEnd(now);
      // If we're past the current period end, rollover
      if (now.isAfter(periodEnd)) {
        final periodStart = budget.currentPeriodStart(now);
        final periodExpenses = expenses.where((e) =>
            e.category == budget.category &&
            e.isConcrete &&
            !e.date.isBefore(periodStart) &&
            !e.date.isAfter(periodEnd));

        final spent = periodExpenses.fold<double>(
            0.0, (sum, e) => sum + e.amount.abs());
        final surplus = budget.goalAmount - spent;

        return budget.copyWith(
          rolloverAmount: budget.rolloverAmount + surplus,
        );
      }
      return budget;
    }).toList();

    if (updated != state) emit(updated);
  }

  // ── Computed status ─────────────────────────────────────────────────

  /// Calculate how much has been spent against a budget in its current period.
  BudgetStatus getBudgetStatus(String budgetId, List<Expense> allExpenses) {
    final budget = findById(budgetId);
    if (budget == null) return BudgetStatus.empty;

    final now = DateTime.now();
    final periodStart = budget.currentPeriodStart(now);
    final periodEnd = budget.currentPeriodEnd(now);

    // Find expenses that match this budget's category and fall within
    // the current period
    final periodExpenses = allExpenses.where((e) =>
        e.category?.toLowerCase() == budget.category.toLowerCase() &&
        !e.date.isBefore(periodStart) &&
        !e.date.isAfter(periodEnd));

    final spent = periodExpenses.fold<double>(
        0.0, (sum, e) => sum + e.amount.abs());

    final effective = budget.effectiveAmount;
    final remaining = effective - spent;

    return BudgetStatus(
      budgetId: budgetId,
      goalAmount: budget.goalAmount,
      rolloverAmount: budget.rolloverAmount,
      effectiveAmount: effective,
      spentAmount: spent,
      remainingAmount: remaining,
      isOverBudget: remaining < 0,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
  }

  // ── Persistence ─────────────────────────────────────────────────────

  @override
  List<Budget>? fromJson(Map<String, dynamic> json) {
    final list = json['budgets'] as List<dynamic>?;
    if (list == null) return null;
    final out = <Budget>[];
    for (final item in list) {
      try {
        out.add(Budget.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<Budget> state) {
    return {'budgets': state.map((b) => b.toJson()).toList()};
  }
}

/// Computed snapshot of a budget's current period performance.
class BudgetStatus {
  final String budgetId;
  final double goalAmount;
  final double rolloverAmount;
  final double effectiveAmount;
  final double spentAmount;
  final double remainingAmount;
  final bool isOverBudget;
  final DateTime periodStart;
  final DateTime periodEnd;

  const BudgetStatus({
    required this.budgetId,
    required this.goalAmount,
    required this.rolloverAmount,
    required this.effectiveAmount,
    required this.spentAmount,
    required this.remainingAmount,
    required this.isOverBudget,
    required this.periodStart,
    required this.periodEnd,
  });

  static final empty = BudgetStatus(
    budgetId: '',
    goalAmount: 0,
    rolloverAmount: 0,
    effectiveAmount: 0,
    spentAmount: 0,
    remainingAmount: 0,
    isOverBudget: false,
    periodStart: DateTime(2000),
    periodEnd: DateTime(2000),
  );
}
