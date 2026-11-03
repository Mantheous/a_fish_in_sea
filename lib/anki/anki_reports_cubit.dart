import 'dart:async';

import 'package:a_fish_in_sea/anki/anki_reports.dart';
import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum AnkiReportsStatus { idle, loading, ready, error }

class AnkiReportsState extends Equatable {
  final AnkiReportsStatus status;
  final AnkiReportData data;
  final String? error;
  final DateTime? lastFetchAt;

  const AnkiReportsState({
    this.status = AnkiReportsStatus.idle,
    this.data = AnkiReportData.empty,
    this.error,
    this.lastFetchAt,
  });

  bool get isLoading => status == AnkiReportsStatus.loading;

  AnkiReportsState copyWith({
    AnkiReportsStatus? status,
    AnkiReportData? data,
    String? error,
    bool clearError = false,
    DateTime? lastFetchAt,
  }) => AnkiReportsState(
    status: status ?? this.status,
    data: data ?? this.data,
    error: clearError ? null : (error ?? this.error),
    lastFetchAt: lastFetchAt ?? this.lastFetchAt,
  );

  @override
  List<Object?> get props => [status, data, error, lastFetchAt];
}

/// Fetches the Anki add-on's daily history and folds it into memorization
/// goals as a live cached count.
///
/// Goals keep using `AnkiFacet.reviewsActual` (the existing persisted
/// shape), so every surface — progress bars, goal subtitles, and the
/// stats page — reads the same number without a second progress model.
/// Updates go through [NodeCubit.writeNodes] with `silent: true`: synced
/// system data must not create undo history. A count only changes a few
/// times a day, so the sync traffic is small.
class AnkiReportsCubit extends Cubit<AnkiReportsState> {
  final Future<AnkiReportData> Function() _fetch;
  final NodeCubit _nodes;
  final bool Function() _isSignedIn;
  final int Function() _firstDayOfWeek;
  final DateTime Function() _now;
  final Duration refreshEvery;

  Timer? _timer;
  StreamSubscription<bool>? _authSub;
  Future<void>? _inFlight;

  AnkiReportsCubit({
    required Future<AnkiReportData> Function() fetch,
    required NodeCubit nodes,
    required bool Function() isSignedIn,
    required int Function() firstDayOfWeek,
    Stream<bool>? authChanges,
    DateTime Function()? now,
    this.refreshEvery = const Duration(minutes: 5),
  }) : _fetch = fetch,
       _nodes = nodes,
       _isSignedIn = isSignedIn,
       _firstDayOfWeek = firstDayOfWeek,
       _now = now ?? DateTime.now,
       super(const AnkiReportsState()) {
    _authSub = authChanges?.listen((signedIn) {
      if (signedIn) {
        _startTimer();
        refresh();
      } else {
        _stopTimer();
        emit(const AnkiReportsState());
      }
    });
    if (_isSignedIn()) {
      _startTimer();
      refresh();
    }
  }

  void _startTimer() {
    _timer ??= Timer.periodic(refreshEvery, (_) => refresh());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Pulls the last 400 days (the server's maximum range), updates stale
  /// goal caches, and emits the new report. Safe to call from a button,
  /// a timer tick, or app resume: concurrent callers share one request,
  /// so a button always awaits the data it is about to read.
  Future<void> refresh() {
    // Demo mode swaps in mock nodes and ephemeral storage; real counts
    // must never land in that state (or trigger a sync from it).
    if (DemoMode.isActive) return Future.value();
    final pending = _inFlight;
    if (pending != null) return pending;
    if (!_isSignedIn()) return Future.value();
    final future = _refresh();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<void> _refresh() async {
    final hadData = !state.data.isEmpty;
    if (!hadData) {
      emit(state.copyWith(status: AnkiReportsStatus.loading, clearError: true));
    }
    final now = _now();
    try {
      final data = await _fetch();
      if (!_isSignedIn()) return;
      _applyToNodes(data, now);
      emit(
        AnkiReportsState(
          status: AnkiReportsStatus.ready,
          data: data,
          lastFetchAt: _now(),
        ),
      );
    } on AnkiReportException catch (e) {
      emit(
        state.copyWith(
          status: hadData ? AnkiReportsStatus.ready : AnkiReportsStatus.error,
          error: e.message,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          status: hadData ? AnkiReportsStatus.ready : AnkiReportsStatus.error,
          error: e.toString(),
        ),
      );
    }
  }

  void _applyToNodes(AnkiReportData data, DateTime now) {
    if (DemoMode.isActive) return;
    final actuals = ankiActualsForNodes(
      _nodes.state,
      data,
      now: now,
      firstDayOfWeek: _firstDayOfWeek(),
    );
    if (actuals.isEmpty) return;
    final upserts = <Node>[];
    for (final node in _nodes.state) {
      final actual = actuals[node.id];
      final facet = node.anki;
      if (actual == null || facet == null) continue;
      if (facet.reviewsActual == actual && facet.lastSyncedAt != null) {
        continue;
      }
      upserts.add(
        node.copyWith(
          anki: facet.copyWith(reviewsActual: actual, lastSyncedAt: now),
        ),
      );
    }
    if (upserts.isEmpty) return;
    final errors = _nodes.writeNodes(upserts: upserts, silent: true);
    if (errors.isNotEmpty) {
      debugPrint('[anki] skipped ${errors.length} goal update(s): $errors');
    }
  }

  /// Reading for an unsaved editor form (or a goal about to be created).
  ///
  /// [anchor] is the goal's creation day for a one-time goal. Returns null
  /// when the add-on has no matching deck data, so the editor can keep the
  /// manual count instead of showing a misleading zero.
  AnkiFacetCount? countFor({
    required String? deckName,
    required TimeScale? period,
    int? customPeriodDays,
    DateTime? anchor,
  }) {
    if (DemoMode.isActive || state.data.isEmpty) return null;
    final now = _now();
    final start = period == null
        ? localDay(anchor ?? now)
        : ankiPeriodStart(
            period,
            customPeriodDays: customPeriodDays,
            now: now,
            firstDayOfWeek: _firstDayOfWeek(),
            anchor: anchor,
          );
    if (!state.data.covers(start)) return null;
    final count = ankiCountForFacet(
      deckName: deckName,
      start: start,
      end: localDay(now),
      report: state.data,
    );
    return count.hasData ? count : null;
  }

  @override
  Future<void> close() async {
    _stopTimer();
    await _authSub?.cancel();
    return super.close();
  }
}
