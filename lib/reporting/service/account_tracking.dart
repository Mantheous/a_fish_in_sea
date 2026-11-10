import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../bloc/tracking_cubit.dart';
import '../model/tracked_point.dart';
import 'location_service.dart';

/// Resume an existing device recording before sync can change ownership.
/// startBackground writes the retained owner's new session before launching
/// the service. Never revive a config that already has ownership/session keys.
Future<void> resumeLegacyTrackingRecording(
  TrackingCubit tracking, {
  Future<bool> Function(int, {String? account}) startBackground =
      LocationService.startBackground,
}) async {
  final generation = tracking.accountGeneration;
  final account = tracking.pendingPointsAccount;
  bool stillRecording() =>
      tracking.isCurrentAccount(generation) &&
      tracking.state.isRecording &&
      tracking.pendingPointsAccount == account;
  if (account == null || account.isEmpty || !stillRecording()) return;
  final interval = await readLegacyTrackingInterval();
  if (interval == null || !stillRecording()) return;
  final background = await startBackground(interval, account: account);
  if (!background && stillRecording() && LocationService.supported) {
    LocationService.startForegroundSampling(
      intervalMinutes: interval,
      onTick: () => sampleTrackingPoint(tracking, generation, samplePosition),
    );
  }
}

/// Home and Day review capture both the account and its operation generation.
/// If navigation or account removal interrupts a take, return the batch to
/// its original account's queue, never the new account's queue.
Future<void> mergePendingTrackingPoints(
  TrackingCubit tracking, {
  bool Function()? canMerge,
}) async {
  final generation = tracking.accountGeneration;
  final account = tracking.pendingPointsAccount;
  if (!tracking.isCurrentAccount(generation)) return;
  final pending = await takePendingPoints(account: account);
  if (pending.isEmpty) return;
  if (!tracking.isCurrentAccount(generation) || !(canMerge?.call() ?? true)) {
    await requeuePendingPoints(pending, account: account);
    return;
  }
  try {
    tracking.mergePoints(pending);
    await HydratedBloc.storage.write(
      tracking.storageToken,
      tracking.toJson(tracking.state),
    );
  } catch (_) {
    await requeuePendingPoints(pending, account: account);
    rethrow;
  }
}

/// Foreground GPS results remain invalid after a sign-out fence has opened.
Future<void> sampleTrackingPoint(
  TrackingCubit tracking,
  int generation,
  Future<TrackedPoint?> Function() sample,
) async {
  if (!tracking.isCurrentAccount(generation)) return;
  final point = await sample();
  if (point != null && tracking.isCurrentAccount(generation)) {
    tracking.addPoint(point);
  }
}
