import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/active_recording.dart';
import '../bloc/calendar_cubit.dart';
import '../model/planner_event.dart';

/// Watches for the single active timer across tasks and events and shows
/// the recording banner while one is running. Collapses to nothing
/// otherwise.
///
/// The banner must read both stores: a goal started from the Goals page
/// lives on a node, and a task-event's timer also lives on its backing
/// node. Reading only [CalendarCubit] hid both recordings.
class RecordingBannerSlot extends StatelessWidget {
  const RecordingBannerSlot({super.key, required this.onOpen});

  final ValueChanged<ActiveRecording> onOpen;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        return BlocBuilder<CalendarCubit, List<PlannerEvent>>(
          builder: (context, events) {
            final active = activeRecordingOf(nodes, events);
            if (active == null) return const SizedBox.shrink();
            return _RecordingBanner(recording: active, onOpen: onOpen);
          },
        );
      },
    );
  }
}

class _RecordingBanner extends StatefulWidget {
  const _RecordingBanner({required this.recording, required this.onOpen});

  final ActiveRecording recording;
  final ValueChanged<ActiveRecording> onOpen;

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

  void _stop() {
    try {
      stopActiveRecording(
        context.read<NodeCubit>(),
        context.read<CalendarCubit>(),
        widget.recording,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.recording.title.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onOpen(widget.recording),
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
                      'Recording · ${_elapsed(widget.recording.startedAt)}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      title.isEmpty ? 'Untitled task' : title,
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
                onPressed: _stop,
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
