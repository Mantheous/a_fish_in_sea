import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';

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
///   2. Money nodes (dated singles + generated template instances)
///   3. Plaid balance (starting balance)
///
/// Recurring money templates materialize dated instances into [NodeCubit]
/// on rebuild (convergent: existing instances are never rewritten), so
/// projections are first-class nodes — visible in the queue, the ledger,
/// and the calendar — not virtual rows.
class WaterfallCubit extends HydratedCubit<WaterfallState> {
  final NodeCubit nodeCubit;
  final TransactionsCubit transactionsCubit;
  final PlaidCubit plaidCubit;

  late final StreamSubscription _nodeSubscription;
  late final StreamSubscription _transactionsSubscription;
  late final StreamSubscription _plaidSubscription;

  WaterfallCubit({
    required this.nodeCubit,
    required this.transactionsCubit,
    required this.plaidCubit,
  }) : super(WaterfallState(
          projectionHorizon:
              DateTime.now().add(const Duration(days: 365)),
        )) {
    // Listen for changes to rebuild
    _nodeSubscription = nodeCubit.stream.listen((_) => rebuild());
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

    // 0. Materialize recurring money templates into dated instances
    // (silent, convergent — existing instances are kept as-is).
    for (final template in nodeCubit.state) {
      if (template.isTemplate && template.money != null) {
        nodeCubit.generateInstances(
          templateId: template.id,
          from: today,
          horizon: horizon,
        );
      }
    }

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

    // 2. Add money nodes. Templates are skipped (their instances carry
    // the dated amounts). Concrete nodes whose linked transaction is
    // already in the waterfall are skipped to avoid double-counting.
    final txnIds =
        transactionsCubit.state.map((t) => t.id).toSet();
    for (final node in nodeCubit.state) {
      final money = node.money;
      if (money == null || node.isTemplate) continue;
      final date =
          node.schedule?.due ?? node.schedule?.start ?? node.schedule?.end;
      if (date == null) continue;
      if (money.isConcrete &&
          money.linkedTransactionIds.any(txnIds.contains)) {
        continue;
      }
      final magnitude =
          money.actualAmount ?? money.effectiveTarget;
      if (magnitude <= 0) continue;
      final signed =
          money.direction == MoneyDirection.income ? magnitude : -magnitude;
      allEntries.add(LedgerEntry(
        sourceId: node.id,
        name: node.title,
        amount: signed,
        date: date,
        type: node.isInstance
            ? EntryType.recurringProjection
            : EntryType.expense,
        status: _moneyStatusToEntryStatus(money.status),
        isConcrete: money.isConcrete,
      ));
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

  EntryStatus _moneyStatusToEntryStatus(MoneyStatus status) {
    switch (status) {
      case MoneyStatus.projected:
        return EntryStatus.projected;
      case MoneyStatus.due:
        return EntryStatus.due;
      case MoneyStatus.paid:
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

  /// Sync apply: takes the roamed view config, then rebuilds rows from
  /// local sources (rows themselves are derived, never stored).
  void applySyncedConfig(Map<String, dynamic> json) {
    final parsed = fromJson(json);
    if (parsed == null) return;
    emit(state.copyWith(
      startingBalance: parsed.startingBalance,
      projectionHorizon: parsed.projectionHorizon,
      viewScale: parsed.viewScale,
      clearViewScale: parsed.viewScale == null,
      monthlyThresholdDays: parsed.monthlyThresholdDays,
      weeklyThresholdDays: parsed.weeklyThresholdDays,
    ));
    rebuild();
  }

  @override
  Future<void> close() {
    _nodeSubscription.cancel();
    _transactionsSubscription.cancel();
    _plaidSubscription.cancel();
    return super.close();
  }
}
