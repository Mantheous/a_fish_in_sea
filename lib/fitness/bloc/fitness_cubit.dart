import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../demo/demo_mode.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../fitness_models.dart';
import '../fitness_service.dart';
import '../fitness_sync.dart';

/// Where the Strava connection stands.
enum FitnessLink {
  /// Not checked yet (nothing fetched).
  unknown,

  /// Server has no Strava API app configured, so connect can't start.
  unconfigured,

  /// Server is configured and waiting for the athlete to sign in.
  disconnected,

  /// Tokens stored; activities can sync.
  connected,

  /// Status check failed (offline, signed out, server down).
  unavailable,
}

class FitnessState extends Equatable {
  final FitnessLink link;
  final String? athlete;
  final String? redirectUri;
  final bool supportsSleep;
  final List<FitnessActivity> activities;
  final List<SleepSample> sleep;
  final DateTime? lastSync;
  final bool syncing;
  final String? error;

  const FitnessState({
    this.link = FitnessLink.unknown,
    this.athlete,
    this.redirectUri,
    this.supportsSleep = false,
    this.activities = const [],
    this.sleep = const [],
    this.lastSync,
    this.syncing = false,
    this.error,
  });

  bool get isConnected => link == FitnessLink.connected;

  FitnessState copyWith({
    FitnessLink? link,
    String? athlete,
    String? redirectUri,
    bool? supportsSleep,
    List<FitnessActivity>? activities,
    List<SleepSample>? sleep,
    DateTime? lastSync,
    bool? syncing,
    String? error,
    bool clearError = false,
    bool clearAthlete = false,
  }) =>
      FitnessState(
        link: link ?? this.link,
        athlete: clearAthlete ? null : (athlete ?? this.athlete),
        redirectUri: redirectUri ?? this.redirectUri,
        supportsSleep: supportsSleep ?? this.supportsSleep,
        activities: activities ?? this.activities,
        sleep: sleep ?? this.sleep,
        lastSync: lastSync ?? this.lastSync,
        syncing: syncing ?? this.syncing,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props =>
      [link, athlete, redirectUri, supportsSleep, activities, sleep,
        lastSync, syncing, error];
}

/// Owns the Strava connection status and the synced activities that feed
/// workout auto-report and fitness-goal progress.
///
/// The server holds the OAuth tokens and fetches Strava; this cubit only
/// reads normalized activities, then writes workout actuals through
/// [NodeCubit] (silent, so syncing never pollutes undo history).
class FitnessCubit extends Cubit<FitnessState> {
  final FitnessService service;
  final NodeCubit nodes;
  bool _asked = false;

  FitnessCubit({required this.service, required this.nodes})
      : super(const FitnessState());

  /// One automatic status check per session, triggered the first time a
  /// screen needs fitness data (Goals page / Settings).
  Future<void> refreshOnce() {
    if (_asked) return Future<void>.value();
    // Signed-out / no session yet: nothing to ask the server. Don't mark
    // the check as done so the first signed-in screen still runs it.
    if (!DemoMode.isActive && (service.authToken() ?? '').isEmpty) {
      return Future<void>.value();
    }
    _asked = true;
    return refresh();
  }

  /// Drops everything on sign-out/account switch: a stale athlete name or
  /// another account's activities must never leak into the next session.
  void reset() {
    _asked = false;
    emit(const FitnessState());
  }

  Future<void> refresh() async {
    try {
      final status = await service.status();
      final link = status.connected
          ? FitnessLink.connected
          : status.configured
              ? FitnessLink.disconnected
              : FitnessLink.unconfigured;
      emit(state.copyWith(
        link: link,
        athlete: status.athlete,
        redirectUri: status.redirectUri,
        supportsSleep: status.supportsSleep,
        clearError: status.connected,
        clearAthlete: !status.connected,
      ));
      if (status.connected) await sync();
    } on FitnessException catch (e) {
      emit(state.copyWith(
        link: e.needsSetup
            ? FitnessLink.unconfigured
            : e.needsReconnect
                ? FitnessLink.disconnected
                : FitnessLink.unavailable,
        redirectUri: e.redirectUri,
        error: e.message,
      ));
    }
  }

  /// Returns the Strava consent URL to open in a browser tab, or null when
  /// the server isn't set up (state then carries the callback URL to use).
  Future<String?> connectUrl() async {
    if (DemoMode.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await refresh();
      return null;
    }
    try {
      final url = await service.authUrl();
      emit(state.copyWith(clearError: true));
      return url;
    } on FitnessException catch (e) {
      emit(state.copyWith(
        link: e.needsSetup ? FitnessLink.unconfigured : state.link,
        redirectUri: e.redirectUri,
        error: e.message,
      ));
      return null;
    }
  }

  Future<void> disconnect() async {
    try {
      await service.disconnect();
      // Drop derived numbers immediately: workout timestamps already
      // written stay (they are real reported time), but goal progress
      // must not keep crediting activities we can no longer verify.
      emit(state.copyWith(
        link: FitnessLink.disconnected,
        activities: const [],
        sleep: const [],
        clearAthlete: true,
        clearError: true,
      ));
    } on FitnessException catch (e) {
      emit(state.copyWith(error: e.message));
    }
  }

  Future<void> sync() async {
    if (state.syncing || state.link != FitnessLink.connected) return;
    emit(state.copyWith(syncing: true, clearError: true));
    try {
      final activities = await service.activities();
      final sleep = await service.sleep();
      _applyWorkouts(activities);
      emit(state.copyWith(
        activities: activities,
        sleep: sleep,
        syncing: false,
        lastSync: DateTime.now(),
      ));
    } on FitnessException catch (e) {
      emit(state.copyWith(
        syncing: false,
        link: e.needsReconnect ? FitnessLink.disconnected : state.link,
        error: e.message,
      ));
    }
  }

  void _applyWorkouts(List<FitnessActivity> activities) {
    if (DemoMode.isActive || activities.isEmpty) return;
    final current = nodes.state;
    final next = applyWorkoutActivities(current, activities);
    final upserts = <Node>[
      for (var i = 0; i < next.length; i++)
        if (!identical(next[i], current[i])) next[i],
    ];
    if (upserts.isEmpty) return;
    // System write: no undo entry, no user-visible "unsaved" churn.
    nodes.writeNodes(upserts: upserts, silent: true);
  }
}
