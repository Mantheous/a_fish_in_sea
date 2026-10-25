import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../../planner/bloc/settings_cubit.dart';
import '../../planner/model/color_prefs.dart';
import '../../planner/model/feed.dart';
import '../../planner/model/planner_event.dart';
import '../../planner/view/event_colors.dart';
import 'color_picker_sheet.dart';

/// One place to manage every event color in the app: homework, individual
/// classes, whole calendars, personal events, and which surfaces honor the
/// choices. Reached from Settings → Colors.
class ColorsPage extends StatelessWidget {
  const ColorsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>();
    final prefs = settings.state.colors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Colors'),
        actions: [
          IconButton(
            tooltip: 'Reset event colors',
            icon: const Icon(Icons.restart_alt),
            onPressed: prefs.isDefault
                ? null
                : () => _confirmReset(context, settings),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _SectionCard(
            title: 'Preview',
            subtitle: 'How event tiles read with these choices.',
            child: _PreviewStrip(prefs: prefs),
          ),
          _SectionCard(
            title: 'Homework & personal events',
            subtitle: 'Homework wins over class and calendar colors.',
            child: Column(
              children: [
                _ColorTile(
                  title: 'Homework',
                  subtitle:
                      'Every imported assignment and scheduled task on the '
                      'calendar.',
                  value: prefs.homework,
                  autoLabel: 'Class or calendar color',
                  onChanged: settings.setHomeworkColor,
                ),
                const Divider(height: 1),
                _ColorTile(
                  title: 'Personal events',
                  subtitle: 'Events with no class and no calendar.',
                  value: prefs.personal,
                  autoLabel: 'Built-in teal',
                  onChanged: settings.setPersonalEventColor,
                ),
              ],
            ),
          ),
          _ClassesCard(prefs: prefs),
          const _CalendarsCard(),
          _SectionCard(
            title: 'Where colors apply',
            subtitle:
                'Switch a surface off to keep the inherited colors '
                'there; your choices stay saved.',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Calendar'),
                  subtitle: const Text(
                    'Tiles, report lanes, and event details.',
                  ),
                  value: prefs.applyToCalendar,
                  onChanged: settings.setColorsApplyToCalendar,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Task lists'),
                  subtitle: const Text(
                    'Class colors on chips and homework group headers.',
                  ),
                  value: prefs.applyToTaskLists,
                  onChanged: settings.setColorsApplyToTaskLists,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    SettingsCubit settings,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset event colors?'),
        content: const Text(
          'Homework, personal, class, and surface choices return to '
          'automatic. Calendar colors you set in Manage classes/calendars '
          'are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    settings.resetEventColors();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Event colors reset')));
  }
}

class _ClassesCard extends StatelessWidget {
  final ColorPrefs prefs;

  const _ClassesCard({required this.prefs});

  /// Every class the app currently knows about: labels on events, labels on
  /// homework nodes, and any class that still has a saved override.
  List<String> _knownClasses(BuildContext context) {
    final labels = <String>{...prefs.classes.keys};
    for (final event in context.watch<CalendarCubit>().state) {
      final label = event.classLabel?.trim() ?? '';
      if (label.isNotEmpty) labels.add(label);
    }
    for (final node in context.watch<NodeCubit>().state) {
      final label = node.classLabel?.trim() ?? '';
      if (label.isNotEmpty) labels.add(label);
    }
    final sorted = labels.toList()..sort();
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsCubit>();
    final classes = _knownClasses(context);
    return _SectionCard(
      title: 'Classes',
      subtitle:
          'Assign a color to one class here. Events keep the automatic '
          'palette color until you do.',
      child: classes.isEmpty
          ? const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.school_outlined),
              title: Text('No classes yet'),
              subtitle: Text(
                'Add a class feed under Settings → Classes and each course '
                'shows up here.',
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < classes.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _ClassColorTile(
                    label: classes[i],
                    prefs: prefs,
                    onChanged: (value) =>
                        settings.setClassColor(classes[i], value),
                  ),
                ],
              ],
            ),
    );
  }
}

class _CalendarsCard extends StatelessWidget {
  const _CalendarsCard();

  @override
  Widget build(BuildContext context) {
    final feeds = context.watch<FeedCubit>().state;
    final feedCubit = context.read<FeedCubit>();
    return _SectionCard(
      title: 'Calendars',
      subtitle:
          'One color per calendar. These are the same colors you can '
          'set in Manage classes/calendars.',
      child: feeds.isEmpty
          ? const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.event_note_outlined),
              title: Text('No calendars yet'),
              subtitle: Text('Add one under Settings → Calendars.'),
            )
          : Column(
              children: [
                for (var i = 0; i < feeds.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _FeedColorTile(
                    feed: feeds[i],
                    onChanged: (value) => feedCubit.updateFeed(
                      feeds[i].copyWith(colorValue: value),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _ColorTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final int? value;
  final String autoLabel;
  final ValueChanged<int?> onChanged;

  const _ColorTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.autoLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _ColorDot(value: value, autoColor: null),
      title: Text(title),
      subtitle: Text(value == null ? '$subtitle · Automatic' : subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final choice = await showColorPickerSheet(
          context,
          title: title,
          selected: value,
          autoLabel: autoLabel,
        );
        if (choice != null) onChanged(choice.color);
      },
    );
  }
}

class _ClassColorTile extends StatelessWidget {
  final String label;
  final ColorPrefs prefs;
  final ValueChanged<int?> onChanged;

  const _ClassColorTile({
    required this.label,
    required this.prefs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final assigned = prefs.classColorFor(label);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _ColorDot(value: assigned, autoColor: courseColor(label)),
      title: Text(label),
      subtitle: Text(assigned == null ? 'Automatic' : 'Custom color'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final choice = await showColorPickerSheet(
          context,
          title: label,
          selected: assigned,
          autoLabel: 'Automatic palette color',
        );
        if (choice != null) onChanged(choice.color);
      },
    );
  }
}

class _FeedColorTile extends StatelessWidget {
  final Feed feed;
  final ValueChanged<int> onChanged;

  const _FeedColorTile({required this.feed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _ColorDot(value: feed.colorValue, autoColor: null),
      title: Text(feed.name),
      subtitle: Text(feed.kind.displayName),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final choice = await showColorPickerSheet(
          context,
          title: feed.name,
          selected: feed.colorValue,
          allowAuto: false,
        );
        final color = choice?.color;
        if (color != null) onChanged(color);
      },
    );
  }
}

class _ColorDot extends StatelessWidget {
  final int? value;
  final Color? autoColor;

  const _ColorDot({required this.value, required this.autoColor});

  @override
  Widget build(BuildContext context) {
    final color = value != null
        ? Color(value!)
        : autoColor ?? Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: value == null
          ? Icon(Icons.auto_awesome, size: 12, color: _onColor(color))
          : null,
    );
  }
}

class _PreviewStrip extends StatelessWidget {
  final ColorPrefs prefs;

  const _PreviewStrip({required this.prefs});

  @override
  Widget build(BuildContext context) {
    final classes = <String>{...prefs.classes.keys};
    for (final event in context.watch<CalendarCubit>().state) {
      final label = event.classLabel?.trim() ?? '';
      if (label.isNotEmpty) {
        classes.add(label);
        break;
      }
    }
    final sampleClass = classes.isEmpty ? 'Example class' : classes.first;
    final now = DateTime(2026, 1, 1, 9);
    PlannerEvent sample(String id, {bool isTask = false, String? label}) =>
        PlannerEvent(
          id: id,
          subject: id,
          start: now,
          end: now.add(const Duration(hours: 1)),
          isTask: isTask,
          classLabel: label,
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _PreviewChip(
          label: 'Homework',
          color: resolveEventColor(
            sample('Homework', isTask: true, label: sampleClass),
            const {},
            prefs,
          ),
        ),
        _PreviewChip(
          label: sampleClass,
          color: resolveEventColor(
            sample(sampleClass, label: sampleClass),
            const {},
            prefs,
          ),
        ),
        _PreviewChip(
          label: 'Personal',
          color: resolveEventColor(sample('personal'), const {}, prefs),
        ),
      ],
    );
  }
}

class _PreviewChip extends StatelessWidget {
  final String label;
  final Color color;

  const _PreviewChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(color: _onColor(color), fontSize: 12),
      ),
    );
  }
}

/// White unless the tile color is too light to read white on.
Color _onColor(Color color) =>
    color.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
