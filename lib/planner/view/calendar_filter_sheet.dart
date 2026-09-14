import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_visibility_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../model/calendar_source.dart';

Future<void> showCalendarFilterSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _CalendarFilterSheet(),
  );
}

class _CalendarFilterSheet extends StatelessWidget {
  const _CalendarFilterSheet();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Calendars',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      context.read<CalendarVisibilityCubit>().showAll(),
                  child: const Text('Show all'),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Choose which calendars appear in the calendar view. '
              'Hidden calendars keep syncing in the background.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const Expanded(child: _CalendarFilterBody()),
        ],
      ),
    );
  }
}

class _CalendarFilterBody extends StatelessWidget {
  const _CalendarFilterBody();

  @override
  Widget build(BuildContext context) {
    final feeds = context.watch<FeedCubit>().state;
    final events = context.watch<CalendarCubit>().state;
    final visibility = context.watch<CalendarVisibilityCubit>().state;
    final cubit = context.read<CalendarVisibilityCubit>();

    final groups = buildCalendarTree(feeds: feeds, events: events);
    final feedById = {for (final f in feeds) f.id: f};
    final hiddenCount = events
        .where((e) => !cubit.isEventVisible(e, feedById))
        .length;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (hiddenCount > 0 || visibility.hasHidden)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              hiddenCount > 0
                  ? 'Hiding $hiddenCount of ${events.length} events'
                  : 'All events shown',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        for (final group in groups)
          _GroupSection(group: group, hiddenIds: visibility.hiddenIds),
      ],
    );
  }
}

class _GroupSection extends StatefulWidget {
  final CalendarGroup group;
  final Set<String> hiddenIds;

  const _GroupSection({required this.group, required this.hiddenIds});

  @override
  State<_GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends State<_GroupSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<CalendarVisibilityCubit>();
    final childIds = [for (final leaf in widget.group.leaves) leaf.id];
    final groupVisibility = cubit.groupState(widget.group.id, childIds);
    final groupChecked = switch (groupVisibility) {
      CalendarGroupVisibility.all => true,
      CalendarGroupVisibility.none => false,
      CalendarGroupVisibility.some => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Checkbox(
            tristate: true,
            value: groupChecked,
            onChanged: (_) => cubit.toggleGroup(widget.group.id, childIds),
          ),
          title: Text(
            widget.group.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          subtitle: Text(
            widget.group.leaves.isEmpty
                ? 'Empty'
                : '${widget.group.leaves.length} '
                    '${widget.group.leaves.length == 1 ? 'calendar' : 'calendars'}',
          ),
          trailing: IconButton(
            tooltip: _expanded ? 'Collapse' : 'Expand',
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
          onTap: () => cubit.toggleGroup(widget.group.id, childIds),
        ),
        if (_expanded)
          if (widget.group.leaves.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
              child: Text(
                widget.group.id == calendarGroupFinance
                    ? 'No finance calendars yet — they will appear here.'
                    : 'Nothing here yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            for (final leaf in widget.group.leaves)
              _LeafTile(leaf: leaf),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

class _LeafTile extends StatelessWidget {
  final CalendarLeaf leaf;

  const _LeafTile({required this.leaf});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<CalendarVisibilityCubit>();
    final visible = cubit.isLeafVisible(leaf.id, leaf.groupId);
    final dotColor =
        leaf.colorValue == null ? null : Color(leaf.colorValue!);
    return CheckboxListTile(
      contentPadding: const EdgeInsets.fromLTRB(32, 0, 16, 0),
      secondary: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: dotColor ?? Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
      title: Text(leaf.title),
      subtitle: leaf.eventCount == 0
          ? null
          : Text(
              '${leaf.eventCount} '
              '${leaf.eventCount == 1 ? 'event' : 'events'}',
            ),
      value: visible,
      onChanged: (value) =>
          cubit.setLeafVisible(leaf.id, value ?? false),
    );
  }
}
