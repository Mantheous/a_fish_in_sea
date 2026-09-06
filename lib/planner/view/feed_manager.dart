import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../bloc/feed_cubit.dart';
import '../model/feed.dart';
import '../service/google_calendar_service.dart';

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

  const FeedManagerBody({
    super.key,
    this.kinds,
    this.helpText,
    this.emptyTitle,
    this.itemNoun = 'class',
    this.showGoogleButton = true,
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
                'Canvas: one link covers all classes (Canvas web → Calendar → '
                    'Calendar Feed) — courses are split automatically. Learning '
                    'Suite: add each class separately. Google calendars: use the '
                    'Google button below.',
            style: Theme.of(context).textTheme.bodySmall,
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

void _confirmDelete(BuildContext context, Feed feed, [String itemNoun = 'class']) {
  final capitalized =
      itemNoun.isEmpty ? itemNoun : itemNoun[0].toUpperCase() + itemNoun.substring(1);
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Remove ${itemNoun}?'),
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
                  helperText: 'Canvas: one link for all classes (Calendar → '
                      'Calendar Feed). Learning Suite: course → Calendar → '
                      'subscribe / export.',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  final kind = _kindFromUrl(value);
                  if (kind != FeedKind.other && kind != _kind) {
                    setState(() => _kind = kind);
                  }
                },
              ),
              const SizedBox(height: 12),
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
      setState(() => _error = e.toString());
    }
  }

  Future<void> _openAuthPage() async {
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
          _GoogleConnectStep.checking => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
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
