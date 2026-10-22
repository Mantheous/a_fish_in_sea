import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../bloc/feed_cubit.dart';
import '../model/feed.dart';
import '../service/canvas_service.dart';
import '../service/google_calendar_service.dart';
import '../../demo/demo_data.dart';
import '../../demo/demo_mode.dart';

FeedKind _kindFromUrl(String url) {
  final normalized = url.toLowerCase();
  if (normalized.contains('instructure.com')) return FeedKind.canvas;
  if (normalized.contains('learningsuite.byu.edu')) {
    return FeedKind.learningSuite;
  }
  return FeedKind.other;
}

Future<void> showFeedManager(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _FeedManagerSheet(),
  );
}

class _FeedManagerSheet extends StatelessWidget {
  const _FeedManagerSheet();

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.watch<FeedCubit>();
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
                    'Classes & calendars',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: feedCubit.isSyncing,
                  builder: (context, syncing, _) => IconButton(
                    tooltip: 'Sync now',
                    icon: syncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.refresh),
                    onPressed:
                        syncing ? null : () => feedCubit.syncAll(force: true),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: SafeArea(
                top: false,
                child: const FeedManagerBody(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The classes & calendars configuration, embeddable in the settings page.
///
/// When [kinds] is set, only feeds of those kinds are shown. Use [itemNoun]
/// to tailor labels (e.g. 'class' vs 'calendar').
class FeedManagerBody extends StatelessWidget {
  final Set<FeedKind>? kinds;
  final String? helpText;
  final String? emptyTitle;
  final String itemNoun;
  final bool showGoogleButton;
  final bool showCanvasButton;

  const FeedManagerBody({
    super.key,
    this.kinds,
    this.helpText,
    this.emptyTitle,
    this.itemNoun = 'class',
    this.showGoogleButton = true,
    this.showCanvasButton = true,
  });

  String get _capitalizedNoun =>
      itemNoun.isEmpty ? itemNoun : itemNoun[0].toUpperCase() + itemNoun.substring(1);

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.watch<FeedCubit>();
    final allFeeds = feedCubit.state;
    final feeds = kinds == null
        ? allFeeds
        : allFeeds.where((feed) => kinds!.contains(feed.kind)).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            helpText ??
                'Canvas: one link covers all classes (Canvas web > Calendar > '
                    'Calendar Feed) — courses are split automatically. Learning '
                    'Suite: add each class separately. Google calendars: use the '
                    'Google button below.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showIcalTutorial(context),
            icon: const Icon(Icons.help_outline, size: 18),
            label: const Text('How do I find my iCal link?'),
          ),
        ),
        if (feeds.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 280),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.event_note_outlined, size: 48),
                    const SizedBox(height: 8),
                    Text(
                      emptyTitle ?? 'No ${itemNoun}s yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _editFeed(context, null, itemNoun),
                      icon: const Icon(Icons.add),
                      label: Text('Add a $itemNoun'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          for (final feed in feeds)
            _FeedTile(
              feed: feed,
              itemNoun: itemNoun,
              onEdit: () => _editFeed(context, feed, itemNoun),
              onDelete: () => _confirmDelete(context, feed, itemNoun),
            ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: showGoogleButton
              ? Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _editFeed(context, null, itemNoun),
                        icon: const Icon(Icons.add),
                        label: Text('Add ${_capitalizedNoun.toLowerCase()}'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _connectGoogle(context),
                        icon: const Icon(Icons.event_available),
                        label: const Text('Google'),
                      ),
                    ),
                  ],
                )
              : OutlinedButton.icon(
                  onPressed: () => _editFeed(context, null, itemNoun),
                  icon: const Icon(Icons.add),
                  label: Text('Add ${_capitalizedNoun.toLowerCase()}'),
                ),
        ),
        if (showCanvasButton &&
            (kinds == null || kinds!.contains(FeedKind.canvas)))
          const _CanvasTile(),
      ],
    );
  }
}

void _editFeed(BuildContext context, Feed? feed, [String itemNoun = 'class']) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => _FeedEditorDialog(existing: feed, itemNoun: itemNoun),
  );
}

void _connectGoogle(BuildContext context) {
  final googleService = context.read<FeedCubit>().googleService;
  showDialog<void>(
    context: context,
    builder: (dialogContext) => _GoogleConnectDialog(googleService),
  );
}

void _connectCanvas(BuildContext context) {
  final canvasService = context.read<FeedCubit>().canvasService;
  if (canvasService == null) return;
  // Prefill the host from an existing Canvas feed URL when there is one.
  var host = 'byu.instructure.com';
  try {
    for (final feed in context.read<FeedCubit>().state) {
      if (feed.kind != FeedKind.canvas) continue;
      final uri = Uri.tryParse(feed.url);
      if (uri != null && uri.host.endsWith('.instructure.com')) {
        host = uri.host;
        break;
      }
    }
  } catch (_) {}
  showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        _CanvasConnectDialog(canvasService, initialHost: host),
  );
}

void _confirmDelete(BuildContext context, Feed feed, [String itemNoun = 'class']) {
  final capitalized =
      itemNoun.isEmpty ? itemNoun : itemNoun[0].toUpperCase() + itemNoun.substring(1);
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Remove $itemNoun?'),
      content: Text(
        'Remove "${feed.name}"? Its $capitalized assignments will be removed from the '
        'calendar and its imported tasks deleted.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            context.read<FeedCubit>().removeFeed(feed.id);
            Navigator.of(dialogContext).pop();
          },
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}

/// Step-by-step tutorial for finding the iCal feed URLs that classes need.
///
/// Canvas exposes ONE user-level feed covering every course; Learning Suite
/// exposes one feed PER course. Opened from the feed editor and from the
/// classes manager help text.
Future<void> showIcalTutorial(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => const _IcalTutorialDialog(),
  );
}

class _IcalTutorialDialog extends StatelessWidget {
  const _IcalTutorialDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('How do I find my iCal link?'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Canvas — one link covers every class',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              const _TutorialSteps(
                steps: [
                  'Open Canvas in a browser and log in (e.g. byu.instructure.com).',
                  'In the left-hand global navigation, click Calendar.',
                  'In the calendar sidebar (bottom right), click Calendar Feed.',
                  'Copy the URL in the URL field — it looks like https://<school>.instructure.com/feeds/calendars/user_….ics — and paste it into the iCal link field here.',
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Copy the link itself, not “Click here to view”: that downloads a one-time .ics file, while this app needs the live link so future assignments keep syncing. Courses split automatically — leave the source as Canvas.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Text(
                'Learning Suite — one link per class',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              const _TutorialSteps(
                steps: [
                  'Open learningsuite.byu.edu in a browser and log in.',
                  'From the Course List, open the course, then click its Schedule tab.',
                  'At the top of the Schedule page, click Get iCalendar Feed.',
                  'Copy the link provided and paste it into the iCal link field here. Name it after the class.',
                  'Repeat for each class — every course needs its own feed.',
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Learning Suite refreshes its feed about once a day, so brand-new schedule changes can lag behind. Press sync in the app to pull the latest.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

class _TutorialSteps extends StatelessWidget {
  final List<String> steps;

  const _TutorialSteps({required this.steps});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '${i + 1}.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Expanded(
                  child: Text(
                    steps[i],
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FeedTile extends StatelessWidget {
  final Feed feed;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final String itemNoun;

  const _FeedTile({
    required this.feed,
    required this.onEdit,
    required this.onDelete,
    this.itemNoun = 'class',
  });

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.watch<FeedCubit>();
    final formatter = DateFormat('MMM d, h:mm a');
    return ListTile(
      leading: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: feed.color,
          shape: BoxShape.circle,
        ),
      ),
      title: Text(feed.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${feed.kind.displayName} · ${feed.enabled ? (feed.lastSyncAt == null ? 'Never synced' : 'Synced ${formatter.format(feed.lastSyncAt!)}') : 'Sync off'}',
          ),
          if (feed.lastError != null)
            Text(
              feed.lastError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      isThreeLine: feed.lastError != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Sync',
            icon: const Icon(Icons.refresh),
            onPressed: () => feedCubit.syncFeed(feed.id),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') onEdit();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (context) => [
              if (feed.kind != FeedKind.google)
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'delete', child: Text('Remove')),
            ],
          ),
          Switch(
            value: feed.enabled,
            onChanged: (value) => feedCubit.updateFeed(
              feed.copyWith(enabled: value),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedEditorDialog extends StatefulWidget {
  final Feed? existing;
  final String itemNoun;

  const _FeedEditorDialog({this.existing, this.itemNoun = 'class'});

  @override
  State<_FeedEditorDialog> createState() => _FeedEditorDialogState();
}

class _FeedEditorDialogState extends State<_FeedEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late FeedKind _kind;
  late int _colorValue;
  late bool _createTasks;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _url = TextEditingController(text: existing?.url ?? '');
    _kind = existing?.kind ??
        (widget.itemNoun == 'calendar'
            ? FeedKind.other
            : FeedKind.learningSuite);
    _colorValue = existing?.colorValue ?? Feed.palette.first;
    _createTasks = existing?.createTasks ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final noun = widget.itemNoun;
    final capitalized =
        noun.isEmpty ? noun : noun[0].toUpperCase() + noun.substring(1);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add $noun' : 'Edit $noun'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.existing == null,
                decoration: InputDecoration(
                  labelText: '$capitalized name',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'iCal link',
                  helperText: 'Canvas: one link for all classes (Calendar > '
                      'Calendar Feed). Learning Suite: course > Schedule > '
                      'Get iCalendar Feed.',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  final kind = _kindFromUrl(value);
                  if (kind != FeedKind.other && kind != _kind) {
                    setState(() => _kind = kind);
                  }
                },
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => showIcalTutorial(context),
                  icon: const Icon(Icons.help_outline, size: 18),
                  label: const Text('How do I find my iCal link?'),
                ),
              ),
              const SizedBox(height: 4),
              DropdownButtonFormField<FeedKind>(
                initialValue: _kind,
                decoration: const InputDecoration(
                  labelText: 'Source',
                  border: OutlineInputBorder(),
                ),
                items: FeedKind.values
                    .map(
                      (kind) => DropdownMenuItem(
                        value: kind,
                        child: Text(kind.displayName),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _kind = value ?? FeedKind.other),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final colorValue in Feed.palette)
                    _ColorSwatch(
                      colorValue: colorValue,
                      selected: _colorValue == colorValue,
                      onTap: () => setState(() => _colorValue = colorValue),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Create tasks for assignments'),
                subtitle: Text(
                  _kind == FeedKind.learningSuite
                      ? 'Only events that look like assignments become tasks; '
                          'off for class schedules'
                      : 'Turn on for homework feeds; off for class schedules',
                ),
                value: _createTasks,
                onChanged: (value) => setState(() => _createTasks = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _save(context),
          child: Text(widget.existing == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  void _save(BuildContext context) {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and iCal link are required')),
      );
      return;
    }
    final feedCubit = context.read<FeedCubit>();
    if (widget.existing == null) {
      final feed = Feed(
        id: 'feed:${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        url: url,
        kind: _kind,
        colorValue: _colorValue,
        createTasks: _createTasks,
      );
      feedCubit.addFeed(feed);
      feedCubit.syncFeed(feed.id);
    } else {
      feedCubit.updateFeed(
        widget.existing!.copyWith(
          name: name,
          url: url,
          kind: _kind,
          colorValue: _colorValue,
          createTasks: _createTasks,
        ),
      );
      feedCubit.syncFeed(widget.existing!.id);
    }
    Navigator.of(context).pop();
  }
}

enum _GoogleConnectStep { checking, needAuth, pickCalendars }

class _GoogleConnectDialog extends StatefulWidget {
  final GoogleCalendarService googleService;

  const _GoogleConnectDialog(this.googleService);

  @override
  State<_GoogleConnectDialog> createState() => _GoogleConnectDialogState();
}

class _GoogleConnectDialogState extends State<_GoogleConnectDialog> {
  _GoogleConnectStep _step = _GoogleConnectStep.checking;
  String? _error;
  List<GoogleCalendarInfo> _calendars = const [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _step = _GoogleConnectStep.checking;
      _error = null;
    });
    try {
      final connected = await widget.googleService.isConnected();
      if (!mounted) return;
      if (connected) {
        await _loadCalendars();
      } else {
        setState(() => _step = _GoogleConnectStep.needAuth);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _GoogleConnectStep.needAuth;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadCalendars() async {
    try {
      final calendars = await widget.googleService.listCalendars();
      if (!mounted) return;
      setState(() {
        _calendars = calendars;
        _selected
          ..clear()
          ..addAll([
            for (final calendar in calendars)
              if (calendar.primary) calendar.id,
          ]);
        _step = _GoogleConnectStep.pickCalendars;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        if (e is GoogleCalendarException && e.needsReconnect) {
          // The stored grant is dead (expired/revoked): fall back to the
          // sign-in step instead of stranding the dialog on the spinner.
          _calendars = const [];
          _step = _GoogleConnectStep.needAuth;
        }
      });
    }
  }

  Future<void> _openAuthPage() async {
    // Demo has no browser OAuth round-trip: one tap "connects" the mock
    // account and lands on the calendar picker.
    if (DemoMode.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      DemoMocks.googleConnected = true;
      if (!mounted) return;
      await _checkConnection();
      return;
    }
    try {
      final uri = Uri.parse(await widget.googleService.authUrl());
      if (kIsWeb) {
        await launchUrl(uri, webOnlyWindowName: '_blank');
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (!mounted) return;
      setState(() => _error = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _addSelected() {
    final feedCubit = context.read<FeedCubit>();
    final addedIds = <String>[];
    for (final calendar in _calendars) {
      if (!_selected.contains(calendar.id)) continue;
      final id = 'gcal:${calendar.id}';
      feedCubit.addFeed(Feed(
        id: id,
        name: calendar.summary,
        url: '',
        kind: FeedKind.google,
        colorValue:
            calendar.colorValue ?? courseColor(calendar.id).toARGB32(),
        createTasks: false,
        calendarId: calendar.id,
      ));
      addedIds.add(id);
    }
    if (addedIds.isNotEmpty) {
      feedCubit.syncFeeds(addedIds);
    }
    Navigator.of(context).pop();
  }

  Future<void> _disconnect() async {
    try {
      await widget.googleService.disconnect();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      return;
    }
    if (!mounted) return;
    setState(() => _step = _GoogleConnectStep.needAuth);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Google Calendar'),
      content: SizedBox(
        width: 420,
        child: switch (_step) {
          _GoogleConnectStep.checking => _error == null
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _checkConnection,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
          _GoogleConnectStep.needAuth => _buildNeedAuth(),
          _GoogleConnectStep.pickCalendars => _buildCalendarPicker(),
        },
      ),
      actions: [
        if (_step == _GoogleConnectStep.pickCalendars)
          TextButton(
            onPressed: _disconnect,
            child: const Text('Disconnect'),
          ),
        if (_step == _GoogleConnectStep.needAuth)
          TextButton(
            onPressed: _checkConnection,
            child: const Text("I've signed in — check"),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildNeedAuth() {
    if (DemoMode.isActive) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Connect the mock Google account. No browser, no password — '
            'one tap and the demo calendars list below.',
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _openAuthPage,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Connect mock Google'),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Connect your Google account once. The sign-in page opens in a '
          'browser; afterwards your calendars can be synced here.',
        ),
        const SizedBox(height: 8),
        Text(
          'Note: Google only allows localhost redirects over HTTP, so if the '
          'sign-in page reports a redirect error, open the app from '
          'http://localhost:<server port> on the machine running the server '
          'and connect there once.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: _openAuthPage,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open Google sign-in'),
        ),
      ],
    );
  }

  Widget _buildCalendarPicker() {
    if (_calendars.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('No calendars found on this account.'),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Pick the calendars to show in the app:'),
        const SizedBox(height: 8),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Flexible(
          child: SizedBox(
            height: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _calendars.length,
              itemBuilder: (context, index) {
                final calendar = _calendars[index];
                return CheckboxListTile(
                  value: _selected.contains(calendar.id),
                  title: Text(calendar.summary),
                  onChanged: (value) => setState(() {
                    if (value ?? false) {
                      _selected.add(calendar.id);
                    } else {
                      _selected.remove(calendar.id);
                    }
                  }),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _selected.isEmpty ? null : _addSelected,
          child: Text('Add ${_selected.length} selected'),
        ),
      ],
    );
  }
}

/// Canvas submission sync: when connected, each feed sync auto-completes
/// homework Canvas reports as submitted or excused.
class _CanvasTile extends StatefulWidget {
  const _CanvasTile();

  @override
  State<_CanvasTile> createState() => _CanvasTileState();
}

class _CanvasTileState extends State<_CanvasTile> {
  bool? _connected;
  String? _host;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final service = _service();
    if (service == null) return;
    try {
      final connected = await service.isConnected();
      String? host;
      if (connected) {
        try {
          host = await service.connectedHost();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _connected = connected;
        _host = host;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _connected = false);
    }
  }

  CanvasService? _service() {
    try {
      return context.read<FeedCubit>().canvasService;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_service() == null) return const SizedBox.shrink();
    final connected = _connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.school_outlined),
        title: const Text('Canvas submissions'),
        subtitle: Text(
          connected == null
              ? 'Checking…'
              : connected
                  ? 'Connected${_host == null ? '' : ' ($_host)'} — submitted homework completes on sync'
                  : 'Not connected — submitted homework stays overdue',
        ),
        trailing: connected == true
            ? TextButton(
                onPressed: () async {
                  await _connectCanvasRefresh();
                },
                child: const Text('Manage'),
              )
            : OutlinedButton(
                onPressed: () async {
                  _connectCanvas(context);
                  // Refresh the status line after the dialog closes.
                  await Future<void>.delayed(
                    const Duration(milliseconds: 300),
                  );
                  await _check();
                },
                child: const Text('Connect'),
              ),
      ),
      ),
    );
  }

  Future<void> _connectCanvasRefresh() async {
    _connectCanvas(context);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _check();
  }
}

class _CanvasConnectDialog extends StatefulWidget {
  final CanvasService canvasService;
  final String initialHost;

  const _CanvasConnectDialog(this.canvasService, {required this.initialHost});

  @override
  State<_CanvasConnectDialog> createState() => _CanvasConnectDialogState();
}

class _CanvasConnectDialogState extends State<_CanvasConnectDialog> {
  late final TextEditingController _host;
  late final TextEditingController _token;
  bool _checking = true;
  bool _connected = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.initialHost);
    _token = TextEditingController();
    _checkConnection();
  }

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final connected = await widget.canvasService.isConnected();
      if (!mounted) return;
      setState(() {
        _checking = false;
        _connected = connected;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _connected = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _save() async {
    final token = _token.text.trim();
    final host = _host.text.trim();
    if (token.isEmpty || host.isEmpty) {
      setState(() => _error = 'Host and token are both required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.canvasService.connect(token: token, host: host);
      // Never keep the pasted token in the field.
      _token.clear();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _connected = true;
      });
      // Apply immediately: submitted homework completes on this sync.
      try {
        await context.read<FeedCubit>().syncAll(force: true);
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Canvas connected — submitted homework marked done'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    try {
      await widget.canvasService.disconnect();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      return;
    }
    if (!mounted) return;
    setState(() => _connected = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Canvas submissions'),
      content: SizedBox(
        width: 420,
        child: _checking
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _connected
                        ? 'Connected. Each sync marks homework submitted or '
                            'excused in Canvas as done.'
                        : 'Paste a personal access token so submitted homework '
                            'marks itself done on sync. Create one in Canvas '
                            'web → Account → Settings → New Access Token. '
                            'The token is stored on the sync server, never on '
                            'this device.',
                  ),
                  const SizedBox(height: 12),
                  if (!_connected) ...[
                    TextField(
                      controller: _host,
                      decoration: const InputDecoration(
                        labelText: 'Canvas host',
                        helperText: 'e.g. byu.instructure.com',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _token,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Access token',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!_connected)
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: const Text('Connect Canvas'),
                    ),
                ],
              ),
      ),
      actions: [
        if (_connected && !_checking)
          TextButton(
            onPressed: _disconnect,
            child: const Text('Disconnect'),
          ),
        if (!_connected && !_checking)
          TextButton(
            onPressed: _checkConnection,
            child: const Text('Retry'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Color(colorValue),
          shape: BoxShape.circle,
          border: selected
              ? Border.all(width: 3, color: Colors.white)
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}
