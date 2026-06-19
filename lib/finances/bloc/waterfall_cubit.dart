import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';

/// The full waterfall display state.
class WaterfallState extends Equatable {
  /// Starting balance (from Plaid or manual override).
  final double startingBalance;

  /// The computed display rows.
  final List<LedgerEntry> rows;

  /// How far into the future we project.
  final DateTime projectionHorizon;

  /// View mode: null = waterfall (dynamic), non-null = fixed scale.
  final TimeScale? viewScale;

  /// Waterfall mode thresholds (in days).
  final int monthlyThresholdDays;
  final int weeklyThresholdDays;

  const WaterfallState({
    this.startingBalance = 0.0,
    this.rows = const [],
    required this.projectionHorizon,
    this.viewScale,
    this.monthlyThresholdDays = 60,
    this.weeklyThresholdDays = 7,
  });

  WaterfallState copyWith({
    double? startingBalance,
    List<LedgerEntry>? rows,
    DateTime? projectionHorizon,
    TimeScale? viewScale,
    bool clearViewScale = false,
    int? monthlyThresholdDays,
    int? weeklyThresholdDays,
  }) {
    return WaterfallState(
      startingBalance: startingBalance ?? this.startingBalance,
      rows: rows ?? this.rows,
      projectionHorizon: projectionHorizon ?? this.projectionHorizon,
      viewScale: clearViewScale ? null : (viewScale ?? this.viewScale),
      monthlyThresholdDays:
          monthlyThresholdDays ?? this.monthlyThresholdDays,
      weeklyThresholdDays:
          weeklyThresholdDays ?? this.weeklyThresholdDays,
    );
  }

  @override
  List<Object?> get props => [
        startingBalance,
        rows,
        projectionHorizon,
        viewScale,
        monthlyThresholdDays,
        weeklyThresholdDays,
      ];
}

/// The core waterfall engine.
///
/// Listens to all data source cubits and rebuilds the waterfall timeline
/// whenever any source data changes.  The waterfall merges:
///   1. Plaid transactions (confirmed, immutable)
///   2. User-created expenses (projected or concrete)
///   3. Recurring rule projections (as Expense instances)
///   4. Plaid balance (starting balance)
class WaterfallCubit extends HydratedCubit<WaterfallState> {
  final RecurringRulesCubit recurringRulesCubit;
  final BudgetCubit budgetCubit;
  final ExpenseCubit expenseCubit;
  final TransactionsCubit transactionsCubit;
  final PlaidCubit plaidCubit;

  late final StreamSubscription _recurringSubscription;
  late final StreamSubscription _budgetSubscription;
  late final StreamSubscription _expenseSubscription;
  late final StreamSubscription _transactionsSubscription;
  late final StreamSubscription _plaidSubscription;

  WaterfallCubit({
    required this.recurringRulesCubit,
    required this.budgetCubit,
    required this.expenseCubit,
    required this.transactionsCubit,
    required this.plaidCubit,
  }) : super(WaterfallState(
          projectionHorizon:
              DateTime.now().add(const Duration(days: 365)),
        )) {
    // Listen for changes to rebuild
    _recurringSubscription = recurringRulesCubit.stream.listen((_) => rebuild());
    _budgetSubscription = budgetCubit.stream.listen((_) => rebuild());
    _expenseSubscription = expenseCubit.stream.listen((_) => rebuild());
    _transactionsSubscription = transactionsCubit.stream.listen((_) => rebuild());
    _plaidSubscription = plaidCubit.stream.listen((plaidState) {
      if (plaidState.currentBalance != null) {
        emit(state.copyWith(startingBalance: plaidState.currentBalance));
      }
      rebuild();
    });

    // Initial build
    rebuild();
  }

  // ──────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────

  /// Change the view scale. Pass null for waterfall (dynamic) mode.
  void setViewScale(TimeScale? scale) {
    if (scale == null) {
      emit(state.copyWith(clearViewScale: true));
    } else {
      emit(state.copyWith(viewScale: scale));
    }
    rebuild();
  }

  /// Update waterfall threshold configuration.
  void setWaterfallThresholds({
    int? monthlyThresholdDays,
    int? weeklyThresholdDays,
  }) {
    emit(state.copyWith(
      monthlyThresholdDays: monthlyThresholdDays,
      weeklyThresholdDays: weeklyThresholdDays,
    ));
    rebuild();
  }

  /// Change the projection horizon.
  void setProjectionHorizon(DateTime horizon) {
    emit(state.copyWith(projectionHorizon: horizon));
    rebuild();
  }

  /// Rebuild the entire waterfall timeline from all sources.
  void rebuild() {
    final today = DateTime.now();
    final horizon = state.projectionHorizon;
    final allEntries = <LedgerEntry>[];

    // 1. Add confirmed Plaid transactions
    for (final transaction in transactionsCubit.state) {
      allEntries.add(LedgerEntry(
        sourceId: transaction.id,
        name: transaction.name,
        amount: transaction.amount,
        date: transaction.date,
        type: EntryType.transaction,
        status: transaction.pending ? EntryStatus.projected : EntryStatus.confirmed,
        category: transaction.category,
        isConcrete: true,
      ));
    }

    // 2. Add user-created expenses
    // Track which transaction IDs are already covered by concrete expenses
    // to avoid double-counting
    final concreteTransactionIds = expenseCubit.state
        .where((e) => e.isConcrete && e.linkedTransactionId != null)
        .map((e) => e.linkedTransactionId!)
        .toSet();

    for (final expense in expenseCubit.state) {
      // Skip concrete expenses whose linked transaction is already in the
      // waterfall (avoid double-counting)
      if (expense.isConcrete && concreteTransactionIds.contains(expense.linkedTransactionId)) {
        // The transaction entry already covers this — skip
        continue;
      }

      allEntries.add(LedgerEntry(
        sourceId: expense.id,
        name: expense.name,
        amount: expense.amount,
        date: expense.date,
        type: EntryType.expense,
        status: _expenseStatusToEntryStatus(expense.status),
        category: expense.category,
        isConcrete: expense.isConcrete,
      ));
    }

    // 3. Generate projections from recurring rules
    // Only for dates not already covered by an existing expense from
    // that rule
    final existingRuleExpenseIds = expenseCubit.state
        .where((e) => e.sourceRuleId != null)
        .map((e) => e.id)
        .toSet();

    for (final rule in recurringRulesCubit.state) {
      final projected = rule.generateExpenses(
        fromDate: today,
        horizon: horizon,
      );

      for (final expense in projected) {
        if (!existingRuleExpenseIds.contains(expense.id)) {
          allEntries.add(LedgerEntry(
            sourceId: expense.id,
            name: expense.name,
            amount: expense.amount,
            date: expense.date,
            type: EntryType.recurringProjection,
            status: EntryStatus.projected,
            category: expense.category,
          ));
        }
      }
    }

    // 4. Sort chronologically
    allEntries.sort((a, b) {
      final dateCompare = a.date.compareTo(b.date);
      if (dateCompare != 0) return dateCompare;
      // Confirmed entries first
      if (a.status != b.status) {
        return a.status == EntryStatus.confirmed ? -1 : 1;
      }
      // Income before expenses
      return b.amount.compareTo(a.amount);
    });

    // 5. Compute running balance and time-until labels
    final rows = List<LedgerEntry>.filled(
      allEntries.length,
      LedgerEntry(
        sourceId: '',
        name: '',
        amount: 0,
        date: DateTime(2000),
        type: EntryType.expense,
      ),
    );

    // Find the last confirmed entry index
    int lastConfirmedIndex = -1;
    for (int i = 0; i < allEntries.length; i++) {
      if (allEntries[i].status == EntryStatus.confirmed) {
        lastConfirmedIndex = i;
      }
    }

    // A. Confirmed entries: work backward from today's balance (startingBalance)
    double confirmedBalance = state.startingBalance;
    for (int i = lastConfirmedIndex; i >= 0; i--) {
      rows[i] = allEntries[i].copyWith(
        runningBalance: confirmedBalance,
        timeUntilLabel: _computeTimeUntilLabel(allEntries[i].date, today),
      );
      confirmedBalance -= allEntries[i].amount;
    }

    // B. Projected / pending / due entries: work forward from today's balance (startingBalance)
    double projectedBalance = state.startingBalance;
    for (int i = lastConfirmedIndex + 1; i < allEntries.length; i++) {
      projectedBalance += allEntries[i].amount;
      rows[i] = allEntries[i].copyWith(
        runningBalance: projectedBalance,
        timeUntilLabel: _computeTimeUntilLabel(allEntries[i].date, today),
      );
    }

    emit(state.copyWith(rows: rows.reversed.toList()));
  }

  // ──────────────────────────────────────────────────────────────────
  // Private helpers
  // ──────────────────────────────────────────────────────────────────

  EntryStatus _expenseStatusToEntryStatus(ExpenseStatus status) {
    switch (status) {
      case ExpenseStatus.projected:
        return EntryStatus.projected;
      case ExpenseStatus.due:
        return EntryStatus.due;
      case ExpenseStatus.paid:
        return EntryStatus.confirmed;
    }
  }

  /// Compute a human-readable label for the time until [date] from [today].
  String _computeTimeUntilLabel(DateTime date, DateTime today) {
    final todayDate = DateTime(today.year, today.month, today.day);
    final targetDate = DateTime(date.year, date.month, date.day);

    if (targetDate.isBefore(todayDate)) {
      return 'Past';
    }

    final difference = targetDate.difference(todayDate).inDays;

    if (difference == 0) return 'Today';
    if (difference == 1) return '1 day';

    // Calculate months difference
    int months = (targetDate.year - todayDate.year) * 12 +
        (targetDate.month - todayDate.month);
    if (targetDate.day < todayDate.day) months--;

    // Calculate years difference
    int years = targetDate.year - todayDate.year;
    if (targetDate.month < todayDate.month ||
        (targetDate.month == todayDate.month &&
            targetDate.day < todayDate.day)) {
      years--;
    }

    if (years > 0) {
      return '$years year${years > 1 ? 's' : ''}';
    }
    if (months > 0) {
      return '$months month${months > 1 ? 's' : ''}';
    }
    return '$difference day${difference > 1 ? 's' : ''}';
  }

  @override
  WaterfallState? fromJson(Map<String, dynamic> json) {
    try {
      return WaterfallState(
        startingBalance: (json['startingBalance'] as num?)?.toDouble() ?? 0.0,
        projectionHorizon: json['projectionHorizon'] != null
            ? DateTime.parse(json['projectionHorizon'] as String)
            : DateTime.now().add(const Duration(days: 365)),
        viewScale: json['viewScale'] != null
            ? TimeScale.values.firstWhere(
                (e) => e.name == json['viewScale'],
                orElse: () => TimeScale.monthly,
              )
            : null,
        monthlyThresholdDays: json['monthlyThresholdDays'] as int? ?? 60,
        weeklyThresholdDays: json['weeklyThresholdDays'] as int? ?? 7,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, dynamic>? toJson(WaterfallState state) {
    return {
      'startingBalance': state.startingBalance,
      'projectionHorizon': state.projectionHorizon.toIso8601String(),
      'viewScale': state.viewScale?.name,
      'monthlyThresholdDays': state.monthlyThresholdDays,
      'weeklyThresholdDays': state.weeklyThresholdDays,
    };
  }

  @override
  Future<void> close() {
    _recurringSubscription.cancel();
    _budgetSubscription.cancel();
    _expenseSubscription.cancel();
    _transactionsSubscription.cancel();
    _plaidSubscription.cancel();
    return super.close();
  }
}
