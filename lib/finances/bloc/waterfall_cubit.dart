import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:a_fish_in_sea/finances/model/granularity.dart';
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

  /// [rows] grouped into [LedgerBucket]s at the granularity the current
  /// view mode asks for: by distance from today in waterfall mode, or at
  /// a fixed scale when [viewScale] is set.
  ///
  /// Derived alongside [rows], never stored: the buckets hold references
  /// to the same [LedgerEntry] objects, so grouping for readability can
  /// never lose the granular data behind it.
  final List<LedgerBucket> buckets;

  const WaterfallState({
    this.startingBalance = 0.0,
    this.rows = const [],
    required this.projectionHorizon,
    this.viewScale,
    this.monthlyThresholdDays = 60,
    this.weeklyThresholdDays = 7,
    this.buckets = const [],
  });

  WaterfallState copyWith({
    double? startingBalance,
    List<LedgerEntry>? rows,
    DateTime? projectionHorizon,
    TimeScale? viewScale,
    bool clearViewScale = false,
    int? monthlyThresholdDays,
    int? weeklyThresholdDays,
    List<LedgerBucket>? buckets,
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
      buckets: buckets ?? this.buckets,
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
        buckets,
      ];

  /// The thresholds as one value, for [groupLedgerEntries].
  GranularityThresholds get thresholds => GranularityThresholds(
        monthlyThresholdDays: monthlyThresholdDays,
        weeklyThresholdDays: weeklyThresholdDays,
      );
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
  late List<Node> _moneyNodes;
  DateTime? _rebuiltOn;
  Timer? _rebuildTimer;
  bool _rebuilding = false;
  bool _rebuildQueued = false;

  WaterfallCubit({
    required this.nodeCubit,
    required this.transactionsCubit,
    required this.plaidCubit,
  }) : super(WaterfallState(
          projectionHorizon:
              DateTime.now().add(const Duration(days: 365)),
        )) {
    // Listen for changes to rebuild (debounced: node instance generation
    // re-emits NodeCubit, which would otherwise cascade into O(templates)
    // nested rebuilds on the UI thread).
    _moneyNodes = nodeCubit.state.where((node) => node.money != null).toList();
    _nodeSubscription = nodeCubit.stream.listen((nodes) {
      final moneyNodes = nodes.where((node) => node.money != null).toList();
      // Calendar/task edits emit the whole node collection. They must not
      // regenerate money instances, sort transactions, and regroup the
      // ledger while the reader is scheduling an unrelated event.
      final now = DateTime.now();
      final sameDay = _rebuiltOn?.year == now.year &&
          _rebuiltOn?.month == now.month && _rebuiltOn?.day == now.day;
      if (sameDay && listEquals(_moneyNodes, moneyNodes)) return;
      _moneyNodes = moneyNodes;
      scheduleRebuild();
    });
    _transactionsSubscription =
        transactionsCubit.stream.listen((_) => scheduleRebuild());
    _plaidSubscription = plaidCubit.stream.listen((plaidState) {
      final balance = plaidState.currentBalance;
      if (balance == null || balance == state.startingBalance) return;
      emit(state.copyWith(startingBalance: balance));
      scheduleRebuild();
    });

    // Initial build
    rebuild();
  }

  @override
  String get storagePrefix => StableStorageKeys.waterfall;

  /// Coalesces rapid source emits (e.g. per-template instance generation)
  /// into one rebuild on the next microtask.
  void scheduleRebuild() {
    if (_rebuilding) {
      _rebuildQueued = true;
      return;
    }
    _rebuildTimer?.cancel();
    _rebuildTimer = Timer(const Duration(milliseconds: 50), () {
      _rebuildTimer = null;
      rebuild();
    });
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
    if (_rebuilding) {
      _rebuildQueued = true;
      return;
    }
    _rebuilding = true;
    try {
      _rebuildNow();
    } finally {
      _rebuilding = false;
      if (_rebuildQueued) {
        _rebuildQueued = false;
        scheduleRebuild();
      }
    }
  }

  void _rebuildNow() {
    final today = DateTime.now();
    _rebuiltOn = today;
    final horizon = state.projectionHorizon;
    final allEntries = <LedgerEntry>[];

    // 0. Materialize recurring money templates into dated instances
    // (silent, convergent — existing instances are kept as-is).
    // Batched: one id-set build + one emit for all templates, instead of
    // one scan + one emit per template (which re-fired this listener per
    // template: O(templates) cascading rebuilds).
    final templateIds = <String>[];
    for (final template in nodeCubit.state) {
      if (template.isTemplate && template.money != null) {
        templateIds.add(template.id);
      }
    }
    if (templateIds.isNotEmpty) {
      nodeCubit.generateInstancesForTemplates(
        templateIds: templateIds,
        from: today,
        horizon: horizon,
      );
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

    // 5. Compute running balance and time-until labels.
    // Built directly in display order (newest first): avoids the old
    // placeholder List.filled + per-row copyWith + reversed.toList() triple
    // allocation. Labels are computed once per row here (not in the row
    // builder) so scrolling never recomputes date math.
    final todayDate = DateTime(today.year, today.month, today.day);
    final rows = <LedgerEntry>[];

    // Partition by settled status, not by position: an unconfirmed entry
    // dated before the newest confirmed item (overdue expense, pending
    // bank transaction) is still a forward projection, and a future node
    // marked paid moves only itself into history.
    final confirmed = <LedgerEntry>[];
    final upcoming = <LedgerEntry>[];
    for (final entry in allEntries) {
      if (entry.status == EntryStatus.confirmed) {
        confirmed.add(entry);
      } else {
        upcoming.add(entry);
      }
    }

    // A. Confirmed entries: work backward from today's balance
    // (startingBalance). Both lists stay oldest-first from the sort above,
    // so the newest confirmed item anchors at today's balance.
    double confirmedBalance = state.startingBalance;
    final confirmedNewestFirst = <LedgerEntry>[];
    for (int i = confirmed.length - 1; i >= 0; i--) {
      confirmedNewestFirst.add(confirmed[i].copyWith(
        runningBalance: confirmedBalance,
        timeUntilLabel:
            _computeTimeUntilLabelForDay(confirmed[i].date, todayDate),
      ));
      confirmedBalance -= confirmed[i].amount;
    }

    // B. Projected / pending / due entries: work forward from today's
    // balance (startingBalance). Collected oldest-first, then appended
    // newest-first to keep display order.
    double projectedBalance = state.startingBalance;
    final projected = <LedgerEntry>[];
    for (final entry in upcoming) {
      projectedBalance += entry.amount;
      projected.add(entry.copyWith(
        runningBalance: projectedBalance,
        timeUntilLabel: _computeTimeUntilLabelForDay(entry.date, todayDate),
      ));
    }

    // Newest first: furthest projection at rows.first (the "Projected"
    // header value), oldest history at rows.last.
    for (var i = projected.length - 1; i >= 0; i--) {
      rows.add(projected[i]);
    }
    rows.addAll(confirmedNewestFirst);

    emit(state.copyWith(
      rows: rows,
      buckets: groupLedgerEntries(
        rows: rows,
        thresholds: state.thresholds,
        today: todayDate,
        fixedScale: state.viewScale,
      ),
    ));
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

  /// Same as the old [_computeTimeUntilLabel] but takes the already-truncated
  /// [todayDate] so per-row calls don't reallocate it O(rows) times.
  String _computeTimeUntilLabelForDay(DateTime date, DateTime todayDate) {
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

  /// Tolerant numeric parse: a wrongly-typed stored value must not throw.
  ///
  /// `as int?` on a string (or a bool) throws, and a throw out of
  /// `fromJson` makes `HydratedMixin` reset the state *and overwrite the
  /// stored payload* — the documented data-loss shape in AGENTS.md. Every
  /// value here falls back to its default instead, so a corrupt field
  /// costs that one field rather than the whole waterfall config.
  static int _asInt(Object? raw, int fallback) =>
      raw is num ? raw.toInt() : fallback;

  static double _asDouble(Object? raw, double fallback) =>
      raw is num ? raw.toDouble() : fallback;

  @override
  WaterfallState? fromJson(Map<String, dynamic> json) {
    try {
      final horizonRaw = json['projectionHorizon'];
      return WaterfallState(
        startingBalance: _asDouble(json['startingBalance'], 0.0),
        projectionHorizon:
            horizonRaw is String && DateTime.tryParse(horizonRaw) != null
                ? DateTime.parse(horizonRaw)
                : DateTime.now().add(const Duration(days: 365)),
        viewScale: json['viewScale'] != null
            ? TimeScale.values.firstWhere(
                (e) => e.name == json['viewScale'],
                orElse: () => TimeScale.monthly,
              )
            : null,
        monthlyThresholdDays: _asInt(json['monthlyThresholdDays'], 60),
        weeklyThresholdDays: _asInt(json['weeklyThresholdDays'], 7),
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
    _rebuildTimer?.cancel();
    _nodeSubscription.cancel();
    _transactionsSubscription.cancel();
    _plaidSubscription.cancel();
    return super.close();
  }
}
