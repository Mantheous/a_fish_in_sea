import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/navigation_cubit.dart';
import '../../planner/bloc/settings_cubit.dart';
import '../../reporting/bloc/tracking_cubit.dart';
import '../../reporting/service/account_tracking.dart';
import '../../reporting/service/location_service.dart';
import '../../reporting/view/day_review_screen.dart';

class HomeTrackingCard extends StatefulWidget {
  const HomeTrackingCard({super.key});

  @override
  State<HomeTrackingCard> createState() => _HomeTrackingCardState();
}

class _HomeTrackingCardState extends State<HomeTrackingCard> {
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _mergePending();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _startPendingPoll(int intervalMinutes, TrackingCubit trackingCubit) {
    _stopPendingPoll();
    _poll = Timer.periodic(Duration(minutes: intervalMinutes), (_) {
      if (!mounted ||
          trackingCubit.isClosed ||
          !trackingCubit.state.isRecording) {
        _stopPendingPoll();
        return;
      }
      _mergePending();
    });
  }

  void _stopPendingPoll() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _mergePending() async {
    await mergePendingTrackingPoints(
      context.read<TrackingCubit>(),
      canMerge: () => mounted,
    );
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final tracking = context.read<TrackingCubit>();
    final settings = context.read<SettingsCubit>();
    final generation = tracking.accountGeneration;
    if (!tracking.isCurrentAccount(generation)) return;
    if (tracking.state.isRecording) {
      setState(() => _busy = true);
      try {
        _stopPendingPoll();
        LocationService.stopForegroundSampling();
        await LocationService.stopBackground();
        if (!mounted || !tracking.isCurrentAccount(generation)) return;
        tracking.stopRecording();
        await _mergePending();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (!settings.state.trackingEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location tracking is off — enable it in Settings.'),
        ),
      );
      context.read<NavigationCubit>().setPage(PlannerPage.settings);
      return;
    }
    final gpsAvailable = LocationService.supported;
    setState(() => _busy = true);
    try {
      if (gpsAvailable) {
        final granted = await ensureLocationPermission();
        if (!mounted || !tracking.isCurrentAccount(generation)) return;
        if (!granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied')),
          );
          return;
        }
      }
      tracking.startRecording();
      final interval = settings.state.trackingIntervalMinutes;
      // Capture the cubit up front: the old onTick closed over `mounted` /
      // `context`, so leaving Home disposed the card and silently stopped
      // all foreground sampling while `isRecording` stayed true.
      final trackingCubit = context.read<TrackingCubit>();
      var background = false;
      if (gpsAvailable) {
        // One sampler at a time: the background service keeps recording with
        // the app closed, so when it starts the in-app poller stays off and
        // the card picks up its batches on a poll timer instead. Foreground
        // sampling is the fallback when background is unavailable.
        background = await LocationService.startBackground(
          interval,
          account: tracking.pendingPointsAccount,
        );
        if (!mounted || !tracking.isCurrentAccount(generation)) return;
        if (background) {
          _startPendingPoll(interval, trackingCubit);
        } else {
          LocationService.startForegroundSampling(
            intervalMinutes: interval,
            onTick: () =>
                sampleTrackingPoint(trackingCubit, generation, samplePosition),
          );
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              !gpsAvailable
                  ? 'Recording started (no GPS on this device) — add test points from Day review.'
                  : background
                  ? 'Recording location every $interval min — see the Stats tab.'
                  : 'Recording while the app is open. Allow notifications to keep recording in the background.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trackingCubit = context.watch<TrackingCubit>();
    final tracking = trackingCubit.state;
    final settings = context.watch<SettingsCubit>().state;
    // Indexed bucket (one O(p) pass per state change, O(1) here).
    final todayCount = trackingCubit.pointsOnDay(DateTime.now()).length;
    final recording = tracking.isRecording;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  recording ? Icons.radio_button_checked : Icons.timeline,
                  color: recording ? Theme.of(context).colorScheme.error : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Day tracking',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const DayReviewScreen(),
                    ),
                  ),
                  child: const Text('Review'),
                ),
              ],
            ),
            Text(
              !settings.trackingEnabled
                  ? 'Turned off in Settings.'
                  : recording
                  ? 'Recording… $todayCount points today.'
                  : todayCount > 0
                  ? '$todayCount points recorded today.'
                  : 'Record your path to auto-report your day.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _toggle,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(recording ? Icons.stop : Icons.play_arrow),
              label: Text(recording ? 'Stop recording' : 'Start recording'),
              style: recording
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
