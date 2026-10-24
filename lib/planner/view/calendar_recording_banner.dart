import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/service/node_event_link.dart';
import '../bloc/calendar_cubit.dart';
import '../model/planner_event.dart';

/// Watches for a running event timer and shows the recording banner while
/// one is active. Collapses to nothing otherwise.
class RecordingBannerSlot extends StatelessWidget {
  const RecordingBannerSlot({super.key, required this.onOpen});

  final ValueChanged<PlannerEvent> onOpen;

  @override
  Widget build(BuildContext context) {
    // Select only the active tracking event: rebuilds only when it changes,
    // not on every calendar emit (the old watch rebuilt on any event edit).
    return BlocSelector<CalendarCubit, List<PlannerEvent>, PlannerEvent?>(
      selector: (events) {
        for (final e in events) {
          if (e.isTracking) return e;
        }
        return null;
      },
      builder: (context, active) {
        if (active == null || active.timerStartedAt == null) {
          return const SizedBox.shrink();
        }
        return _RecordingBanner(event: active, onOpen: onOpen);
      },
    );
  }
}

class _RecordingBanner extends StatefulWidget {
  const _RecordingBanner({required this.event, required this.onOpen});

  final PlannerEvent event;
  final ValueChanged<PlannerEvent> onOpen;

  @override
  State<_RecordingBanner> createState() => _RecordingBannerState();
}

class _RecordingBannerState extends State<_RecordingBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _elapsed(DateTime since) {
    final d = DateTime.now().difference(since);
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final startedAt = widget.event.timerStartedAt ?? widget.event.start;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onOpen(widget.event),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.fiber_manual_record,
                size: 14,
                color: Color(0xFFFF5252),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Recording · ${_elapsed(startedAt)}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      widget.event.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  try {
                    NodeEventLink.stopEventTrackingAligned(
                      context.read<NodeCubit>(),
                      context.read<CalendarCubit>(),
                      widget.event.id,
                    );
                  } catch (_) {}
                },
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
