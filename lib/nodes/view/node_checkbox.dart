import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

/// Checkbox for a [Node]. Tap toggles (failed nodes un-fail first);
/// double-tap / Ctrl+click / long-press marks failed.
class NodeCheckbox extends StatefulWidget {
  final Node node;
  final double size;
  final Color? doneColor;

  const NodeCheckbox(
      {super.key, required this.node, this.size = 24, this.doneColor});

  @override
  State<NodeCheckbox> createState() => _NodeCheckboxState();
}

class _NodeCheckboxState extends State<NodeCheckbox> {
  DateTime? _lastTap;

  void _toggle() {
    NodeCubit nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    if (widget.node.status == NodeStatus.failed) {
      NodeEventLink.setNodeFailed(nodes, calendar, widget.node.id, false);
      return;
    }
    NodeEventLink.toggleNodeDone(nodes, calendar, widget.node.id);
  }

  void _markFailed() {
    NodeCubit nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    if (widget.node.status == NodeStatus.failed) return;
    NodeEventLink.setNodeFailed(nodes, calendar, widget.node.id, true);
    _lastTap = null;
  }

  void _onTap() {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      _markFailed();
      return;
    }
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null && now.difference(last).inMilliseconds < 400) {
      _markFailed();
      return;
    }
    _lastTap = now;
    _toggle();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final theme = Theme.of(context);
    final IconData icon;
    final Color? color;
    final String stateLabel;
    if (node.isDone) {
      icon = Icons.check_box;
      color = widget.doneColor ?? theme.colorScheme.primary;
      stateLabel = 'Completed';
    } else if (node.status == NodeStatus.failed) {
      icon = Icons.cancel;
      color = theme.colorScheme.error;
      stateLabel = 'Failed';
    } else {
      icon = Icons.check_box_outline_blank;
      color = null;
      stateLabel = 'Not done';
    }
    return Tooltip(
      message: '$stateLabel — tap to mark complete or unmark, '
          'double-tap or Ctrl+click to mark failed',
      child: InkWell(
        onTap: _onTap,
        onLongPress: _markFailed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: widget.size, color: color),
        ),
      ),
    );
  }
}

/// Checkbox for a calendar event: delegates to the backing node when one
/// exists, otherwise toggles the event itself.
class EventNodeCheckbox extends StatefulWidget {
  final PlannerEvent event;
  final double size;
  final Color? doneColor;

  const EventNodeCheckbox(
      {super.key, required this.event, this.size = 24, this.doneColor});

  @override
  State<EventNodeCheckbox> createState() => _EventNodeCheckboxState();
}

class _EventNodeCheckboxState extends State<EventNodeCheckbox> {
  DateTime? _lastTap;

  void _toggleFallback() {
    CalendarCubit calendar;
    NodeCubit nodes;
    try {
      calendar = context.read<CalendarCubit>();
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    if (widget.event.failed) {
      NodeEventLink.setEventFailed(calendar, nodes, widget.event.id, false);
      return;
    }
    NodeEventLink.toggleEventDone(calendar, nodes, widget.event.id);
  }

  void _failFallback() {
    CalendarCubit calendar;
    NodeCubit nodes;
    try {
      calendar = context.read<CalendarCubit>();
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    if (widget.event.failed) return;
    NodeEventLink.setEventFailed(calendar, nodes, widget.event.id, true);
    _lastTap = null;
  }

  void _onTapFallback() {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      _failFallback();
      return;
    }
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null && now.difference(last).inMilliseconds < 400) {
      _failFallback();
      return;
    }
    _lastTap = now;
    _toggleFallback();
  }

  @override
  Widget build(BuildContext context) {
    Node? backing;
    try {
      final nodes = context.watch<NodeCubit>().state;
      for (final n in nodes) {
        if (n.calendarEventId == widget.event.id ||
            n.sourceEventId == widget.event.id ||
            n.id == widget.event.taskId) {
          backing = n;
          break;
        }
      }
    } catch (_) {}
    final backed = backing;
    if (backed != null) {
      return NodeCheckbox(
          node: backed, size: widget.size, doneColor: widget.doneColor);
    }
    final event = widget.event;
    try {
      final live = context
          .watch<CalendarCubit>()
          .byId(event.id) ??
          event;
      return _FallbackBox(
        done: live.done,
        failed: live.failed,
        size: widget.size,
        onTap: _onTapFallback,
        onLongPress: _failFallback,
      );
    } catch (_) {
      return _FallbackBox(
        done: event.done,
        failed: event.failed,
        size: widget.size,
        onTap: _onTapFallback,
        onLongPress: _failFallback,
      );
    }
  }
}

class _FallbackBox extends StatelessWidget {
  final bool done;
  final bool failed;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FallbackBox({
    required this.done,
    required this.failed,
    required this.size,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final IconData icon;
    final Color? color;
    final String stateLabel;
    if (done) {
      icon = Icons.check_box;
      color = theme.colorScheme.primary;
      stateLabel = 'Completed';
    } else if (failed) {
      icon = Icons.cancel;
      color = theme.colorScheme.error;
      stateLabel = 'Failed';
    } else {
      icon = Icons.check_box_outline_blank;
      color = null;
      stateLabel = 'Not done';
    }
    return Tooltip(
      message: '$stateLabel — tap to mark complete or unmark, '
          'double-tap or Ctrl+click to mark failed',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
