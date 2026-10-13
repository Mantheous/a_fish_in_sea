import 'package:a_fish_in_sea/common/undo/undo_bar.dart';
import 'package:a_fish_in_sea/demo/demo_coordinator.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
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
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        children: [
          const _SettingsSection(
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
          const _SettingsSection(
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
              ],
            ),
          ),
          const _SettingsSection(
            title: 'Location reporting',
            subtitle: 'Record your path through the day to auto-report '
                'events and see on-task stats.',
            child: _LocationTrackingSection(),
          ),
          _SettingsSection(
            title: 'Sync',
            subtitle: DemoMode.isActive
                ? 'Demo mode · mock data — nothing syncs or is saved.'
                : 'Signed in as ${context.watch<AuthCubit>().state.email}. '
                    'Offline-first: this device works without a connection and '
                    'merges later; server copy wins true conflicts.',
            child: const _SyncSection(),
          ),
          const _SettingsSection(
            title: 'API tokens',
            subtitle: 'Long-lived tokens for third-party apps and AI agents. '
                'A token sees everything sync does; revoke any you no longer use.',
            child: _ApiTokensSection(),
          ),
          _SettingsSection(
            title: 'Bank connection',            subtitle: 'Connect a bank with Plaid to pull balances and '
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

/// Sync status + manual sync + sign-out.
class _SyncSection extends StatelessWidget {
  const _SyncSection();

  @override
  Widget build(BuildContext context) {
    // Static flag (not a cubit watch): entry/exit always rebuilds the whole
    // shell from main.dart, and this keeps standalone widget tests working
    // without a DemoCubit in the tree.
    if (DemoMode.isActive) return const _DemoSyncSection();
    final engine = context.read<SyncEngine>();
    return ValueListenableBuilder<EngineStatus>(
      valueListenable: engine.status,
      builder: (context, status, _) {
        final syncing = status == EngineStatus.syncing;
        final last = engine.lastSyncAt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: syncing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_done_outlined),
              title: Text(syncing
                  ? 'Syncing…'
                  : last == null
                      ? 'Never synced'
                      : 'Last synced ${_formatAgo(last)}'),
              subtitle: engine.lastError == null
                  ? null
                  : Text(engine.lastError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              trailing: TextButton(
                onPressed: syncing
                    ? null
                    : () => context.read<SyncEngine>().syncNow(),
                child: const Text('Sync now'),
              ),
            ),
            ValueListenableBuilder<List<String>>(
              valueListenable: engine.protectedDeletions,
              builder: (context, guarded, _) {
                if (guarded.isEmpty) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Sync held back deletions for: ${guarded.join(', ')}. '
                        'This device is missing items the cloud still has. '
                        'That usually means its local app storage was lost — '
                        'not that you deleted them.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          // Clear the bookkeeping so the next sync
                          // re-downloads the cloud copy onto this device.
                          context.read<SyncMetaCubit>().reset();
                          context.read<SyncEngine>().syncNow();
                        },
                        icon: const Icon(Icons.restore),
                        label: const Text('Restore missing items from cloud'),
                      ),
                    ],
                  ),
                );
              },
            ),
            OutlinedButton.icon(
              onPressed: () {
                context.read<AuthCubit>().logout();
                context.read<SyncMetaCubit>().reset();
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign out (keeps on-device data)'),
            ),
          ],
        );
      },
    );
  }

  String _formatAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

/// Demo replacement for [_SyncSection]: mock-feed refresh + exit.
class _DemoSyncSection extends StatelessWidget {
  const _DemoSyncSection();

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.read<FeedCubit>();
    return ValueListenableBuilder<bool>(
      valueListenable: feedCubit.isSyncing,
      builder: (context, syncing, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: syncing
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science_outlined),
            title: Text(syncing ? 'Refreshing mock feeds…' : 'Demo sync'),
            subtitle: const Text(
              'Mock Canvas, Google and iCal feeds refresh locally. '
              'Submitted homework auto-completes, like the real thing.',
            ),
            trailing: TextButton(
              onPressed: syncing
                  ? null
                  : () => feedCubit.syncAll(force: true),
              child: const Text('Sync now'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => DemoCoordinator.exitDemo(context),
            icon: const Icon(Icons.logout),
            label: const Text('Exit demo (discards mock data)'),
          ),
        ],
      ),
    );
  }
}

/// Lists, creates, and revokes scoped `afm_…` tokens (server
/// `POST/GET/DELETE /api/v1/tokens`). Plaintext secrets are shown once
/// in a copy dialog and never persisted on device.
class _ApiTokensSection extends StatefulWidget {
  const _ApiTokensSection();

  @override
  State<_ApiTokensSection> createState() => _ApiTokensSectionState();
}

class _ApiTokensSectionState extends State<_ApiTokensSection> {
  List<ApiToken>? _tokens;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SyncClient get _client => context.read<AuthCubit>().syncClient;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tokens = await _client.listApiTokens();
      if (!mounted) return;
      setState(() => _tokens = tokens);
    } on SyncException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final spec = await showDialog<_TokenSpec>(
      context: context,
      builder: (dialogContext) => const _CreateTokenDialog(),
    );
    if (spec == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final created = await _client.createApiToken(
        name: spec.name,
        review: spec.review,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) =>
            _ShowTokenDialog(secret: created.token, name: created.info.name),
      );
    } on SyncException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create token: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(ApiToken token) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke token?'),
        content: Text(
          '“${token.name.isEmpty ? 'Unnamed token' : token.name}” (${token.prefix}…) '
          'will stop working immediately. Apps using it will lose sync access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _client.revokeApiToken(token.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token revoked.')),
      );
      await _load();
    } on SyncException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not revoke token: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (DemoMode.isActive) {
      return const Text(
        'API tokens need a real account — unavailable in demo mode.',
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Could not load tokens: $_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    final tokens = _tokens ?? const <ApiToken>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tokens.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('No tokens yet. Create one per app or agent.'),
          )
        else
          for (final token in tokens)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.key_outlined),
              title: Text(
                  token.name.isEmpty ? 'Unnamed token' : token.name),
              subtitle: Text(
                '${token.prefix}… · full sync access'
                '${token.review ? ' · needs approval' : ''}',
              ),
              trailing: IconButton(
                tooltip: 'Revoke',
                onPressed: _busy ? null : () => _revoke(token),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.add),
          label: const Text('Create token'),
        ),
      ],
    );
  }
}

class _TokenSpec {
  final String name;
  final bool review;
  const _TokenSpec({required this.name, required this.review});
}

class _CreateTokenDialog extends StatefulWidget {
  const _CreateTokenDialog();

  @override
  State<_CreateTokenDialog> createState() => _CreateTokenDialogState();
}

class _CreateTokenDialogState extends State<_CreateTokenDialog> {
  final _name = TextEditingController();
  bool _review = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create API token'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Name (e.g. Claude on laptop)',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Needs approval'),
            subtitle: const Text(
              'On: this token drafts into the import inbox instead of '
              'writing directly. Use for untrusted writers.',
            ),
            value: _review,
            onChanged: (v) => setState(() => _review = v),
          ),
          const Text(
            'Tokens get full sync access (read + write everything). '
            'Copy the secret right away — it is shown only once.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _TokenSpec(name: _name.text.trim(), review: _review),
          ),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _ShowTokenDialog extends StatelessWidget {
  final String secret;
  final String name;
  const _ShowTokenDialog({required this.secret, required this.name});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Copy your token'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (name.isNotEmpty) Text('“$name” — copy it now.'),
          if (name.isEmpty) const Text('Copy it now.'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(secret),
          ),
          const SizedBox(height: 8),
          const Text(
            'This is the only time the secret is shown. '
            'If you lose it, revoke this token and create a new one.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: secret));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Token copied.')),
              );
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}

class _DefaultViewTile extends StatelessWidget {  const _DefaultViewTile();

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
            'GPS is not available on this device — you can still record and add test points manually from Day review.',
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
