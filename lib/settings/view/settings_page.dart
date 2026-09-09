import 'package:a_fish_in_sea/common/undo/undo_bar.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/view/bank_connection_card.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/view/feed_manager.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/service/location_service.dart';
import 'package:a_fish_in_sea/reporting/view/places_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

/// Configuration hub: classes, calendars, plus the bank connection.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    final plaidCubit = context.read<PlaidCubit>();
    if (!plaidCubit.state.isConnected &&
        plaidCubit.state.status != PlaidConnectionStatus.connecting) {
      plaidCubit.checkExistingConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [UndoRedoActions()],
      ),
      drawer: const AppDrawer(),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          _SettingsSection(
            title: 'Classes',
            subtitle: 'Canvas and Learning Suite feeds for your courses.',
            child: FeedManagerBody(
              kinds: {FeedKind.canvas, FeedKind.learningSuite},
              helpText: 'Canvas: one link covers all classes (Canvas web → '
                  'Calendar → Calendar Feed) — courses are split '
                  'automatically. Learning Suite: add each class separately.',
              itemNoun: 'class',
              showGoogleButton: false,
            ),
          ),
          _SettingsSection(
            title: 'Calendars',
            subtitle: 'Default view, Google calendars, other iCal links, '
                'and the sync server used on the web.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DefaultViewTile(),
                SizedBox(height: 8),
                _DayHoursTile(),
                SizedBox(height: 8),
                _SnapTile(),
                SizedBox(height: 8),
                _DefaultCalendarTile(),
                SizedBox(height: 8),
                FeedManagerBody(
                  kinds: {FeedKind.google, FeedKind.other},
                  helpText:
                      'Google calendars: use the Google button below. Other: '
                      'any other iCal link to show on the calendar.',
                  emptyTitle: 'No calendars yet',
                  itemNoun: 'calendar',
                ),
                _SyncServerTile(),
              ],
            ),
          ),
          _SettingsSection(
            title: 'Location reporting',
            subtitle: 'Record your path through the day to auto-report '
                'events and see on-task stats. Mobile only.',
            child: _LocationTrackingSection(),
          ),
          _SettingsSection(
            title: 'Bank connection',
            subtitle: 'Connect a bank with Plaid to pull balances and '
                'transactions into Finances.',
            child: _BankSection(),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SettingsSection({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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

class _DefaultViewTile extends StatelessWidget {
  const _DefaultViewTile();

  @override
  Widget build(BuildContext context) {
    final current =
        context.watch<SettingsCubit>().state.defaultCalendarView;
    return SegmentedButton<CalendarView>(
      segments: const [
        ButtonSegment(
          value: CalendarView.day,
          icon: Icon(Icons.view_day),
          label: Text('Day'),
        ),
        ButtonSegment(
          value: CalendarView.week,
          icon: Icon(Icons.view_column),
          label: Text('Week'),
        ),
        ButtonSegment(
          value: CalendarView.month,
          icon: Icon(Icons.calendar_view_month),
          label: Text('Month'),
        ),
      ],
      selected: {current},
      onSelectionChanged: (selection) =>
          context.read<SettingsCubit>().setDefaultCalendarView(
                selection.first,
              ),
    );
  }
}

class _DayHoursTile extends StatelessWidget {
  const _DayHoursTile();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    return ListTile(
      leading: const Icon(Icons.schedule_outlined),
      title: const Text('Visible hours'),
      subtitle: Text(
        '${_formatHour(settings.dayStartHour)} – ${_formatHour(settings.dayEndHour)}',
      ),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _editDayHours(context),
    );
  }

  void _editDayHours(BuildContext context) {
    final settingsCubit = context.read<SettingsCubit>();
    var start = settingsCubit.state.dayStartHour;
    var end = settingsCubit.state.dayEndHour;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Visible hours'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_formatHour(start)} – ${_formatHour(end)}',
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              RangeSlider(
                min: 0,
                max: 24,
                divisions: 48,
                labels: RangeLabels(
                  _formatHour(start),
                  _formatHour(end),
                ),
                values: RangeValues(start, end),
                onChanged: (values) => setDialogState(() {
                  start = values.start;
                  end = values.end;
                }),
              ),
              const Text(
                'Hours outside this range are cut off in day and week views.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                settingsCubit.setDayHours(start, end);
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapTile extends StatelessWidget {
  const _SnapTile();

  @override
  Widget build(BuildContext context) {
    final snap = context.watch<SettingsCubit>().state.snapMinutes;
    return ListTile(
      leading: const Icon(Icons.access_time_outlined),
      title: const Text('Snap to'),
      subtitle: Text('Drags and edits snap to $snap minutes'),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _editSnap(context),
    );
  }

  void _editSnap(BuildContext context) {
    final settingsCubit = context.read<SettingsCubit>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Snap to'),
        content: Wrap(
          spacing: 8,
          children: [
            for (final choice in SettingsCubit.snapChoices)
              ChoiceChip(
                label: Text('$choice min'),
                selected: settingsCubit.state.snapMinutes == choice,
                onSelected: (_) {
                  settingsCubit.setSnapMinutes(choice);
                  Navigator.of(dialogContext).pop();
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _DefaultCalendarTile extends StatelessWidget {
  const _DefaultCalendarTile();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final feeds = context.watch<FeedCubit>().state;
    final writable = feeds
        .where((f) =>
            f.kind == FeedKind.google &&
            f.calendarId != null &&
            f.calendarId!.isNotEmpty)
        .toList();
    final currentId = settings.defaultEventFeedId;
    final validCurrent =
        currentId != null && writable.any((f) => f.id == currentId)
            ? currentId
            : null;
    final currentName = validCurrent == null
        ? 'This device'
        : writable.firstWhere((f) => f.id == validCurrent).name;
    return ListTile(
      leading: const Icon(Icons.event_note_outlined),
      title: const Text('Default calendar'),
      subtitle: Text('New events save to $currentName'),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _editDefaultCalendar(context, writable, validCurrent),
    );
  }

  void _editDefaultCalendar(
    BuildContext context,
    List<Feed> writable,
    String? currentId,
  ) {
    final settingsCubit = context.read<SettingsCubit>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Default calendar'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('New events save here unless you pick otherwise.'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: currentId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Default calendar',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('This device'),
                ),
                for (final feed in writable)
                  DropdownMenuItem(
                    value: feed.id,
                    child: Text(feed.name),
                  ),
              ],
              onChanged: (value) {
                settingsCubit.setDefaultEventFeedId(value);
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

String _formatHour(double hour) {  if (hour >= 24) return '12 AM';
  if (hour <= 0) return '12 AM';
  final h = hour.floor();
  final m = ((hour - h) * 60).round();
  final suffix = h < 12 ? 'AM' : 'PM';
  var h12 = h % 12;
  if (h12 == 0) h12 = 12;
  if (m == 0) return '$h12 $suffix';
  return '$h12:${m.toString().padLeft(2, '0')} $suffix';
}

class _SyncServerTile extends StatelessWidget {
  const _SyncServerTile();

  @override
  Widget build(BuildContext context) {
    final proxyBase = context.watch<SettingsCubit>().state.icalProxyBase;
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: const Text('Sync server URL'),
      subtitle: Text(
        proxyBase.isEmpty
            ? "Default (this app's own server)"
            : proxyBase,
      ),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _editSyncServer(context),
    );
  }

  void _editSyncServer(BuildContext context) {
    final settingsCubit = context.read<SettingsCubit>();
    final controller =
        TextEditingController(text: settingsCubit.state.icalProxyBase);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sync server URL'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            helperText:
                'Leave empty to use this app\'s own server (recommended '
                'when testing over the web)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              settingsCubit.setIcalProxyBase(controller.text.trim());
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _LocationTrackingSection extends StatelessWidget {
  const _LocationTrackingSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final recording = context.watch<TrackingCubit>().state.isRecording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Location tracking'),
          subtitle: Text(
            settings.trackingEnabled
                ? 'Allowed — start a day from Home.'
                : 'Off — no location is recorded.',
          ),
          value: settings.trackingEnabled,
          onChanged: (value) async {
            final settingsCubit = context.read<SettingsCubit>();
            final trackingCubit = context.read<TrackingCubit>();
            settingsCubit.setTrackingEnabled(value);
            if (!value) {
              LocationService.stopForegroundSampling();
              await LocationService.stopBackground();
              trackingCubit.stopRecording();
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Check interval'),
          subtitle: Text(
            'GPS fix every ${settings.trackingIntervalMinutes} min while recording',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap:
              settings.trackingEnabled ? () => _editInterval(context) : null,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.place_outlined),
          title: const Text('Saved places'),
          subtitle: const Text('Home, work, library… used for auto-report'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => showPlacesSheet(context),
        ),
        if (recording)
          Text(
            'Recording now — turning tracking off stops it.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
        if (!LocationService.supported)
          Text(
            'Location recording works on Android and iOS only.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }

  void _editInterval(BuildContext context) {
    final settingsCubit = context.read<SettingsCubit>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Check interval'),
        content: Wrap(
          spacing: 8,
          children: [
            for (final choice in SettingsCubit.trackingIntervalChoices)
              ChoiceChip(
                label: Text('$choice min'),
                selected:
                    settingsCubit.state.trackingIntervalMinutes == choice,
                onSelected: (_) {
                  settingsCubit.setTrackingIntervalMinutes(choice);
                  Navigator.of(dialogContext).pop();
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _BankSection extends StatelessWidget {
  const _BankSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PlaidCubit, PlaidState>(
      builder: (context, plaidState) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: ConnectionStatusChip(state: plaidState)),
            const SizedBox(height: 8),
            BankConnectionCard(state: plaidState),
            if (plaidState.isConnected) ...[
              FilledButton.icon(
                onPressed: () => syncPlaidTransactions(context),
                icon: const Icon(Icons.sync),
                label: const Text('Sync transactions'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => context.read<PlaidCubit>().disconnect(),
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect bank'),
              ),
            ],
          ],
        );
      },
    );
  }
}
