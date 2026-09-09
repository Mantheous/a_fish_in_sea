import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../finances/bloc/plaid_cubit.dart';
import '../bloc/settings_cubit.dart';
import '../model/task_assignee.dart';
import '../service/google_contacts_service.dart';
import 'feed_manager.dart';

class PeopleField extends StatefulWidget {
  final List<TaskAssignee> selected;
  final ValueChanged<List<TaskAssignee>> onChanged;

  const PeopleField({super.key, required this.selected, required this.onChanged});

  @override
  State<PeopleField> createState() => _PeopleFieldState();
}

class _PeopleFieldState extends State<PeopleField> {
  late final TextEditingController _query;
  GoogleContactsService? _service;
  bool _loading = true;
  bool _notConnected = false;
  bool _needsReconnect = false;
  String? _error;
  List<GoogleContact> _results = const [];

  bool get _unavailable => _service == null;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
    _query.addListener(_filter);
    // The global app tree always provides these, but editor sheets can be
    // pumped in isolation (widget tests, previews) — hide instead of
    // throwing a provider error into the layout. The reads must happen
    // eagerly here: the service only calls its closures lazily on fetch,
    // which would otherwise surface as an in-form error string.
    try {
      final settings = context.read<SettingsCubit>();
      final plaid = context.read<PlaidCubit>();
      _service = GoogleContactsService(
        baseUrl: () => settings.state.icalProxyBase,
        userId: () => plaid.state.userId,
      );
    } catch (_) {
      _service = null;
    }
    if (_service != null) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = _service;
    if (service == null) return;
    try {
      final st = await service.status();
      if (!mounted) return;
      if (!st.connected) {
        setState(() {
          _loading = false;
          _notConnected = true;
        });
        return;
      }
      final contacts = await service.fetchContacts();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _needsReconnect = !st.contactsGranted && contacts.isEmpty;
        _results = service.searchCached(_query.text);
      });
    } on GoogleContactsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.needsReconnect) {
          _needsReconnect = true;
        } else {
          _error = e.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _filter() {
    final service = _service;
    if (!mounted || service == null) return;
    setState(() => _results = service.searchCached(_query.text));
  }

  void _add(GoogleContact contact) {
    if (widget.selected.any((a) => a.id == contact.id)) return;
    widget.onChanged([...widget.selected, contact.toAssignee()]);
  }

  void _remove(String id) {
    widget
        .onChanged(widget.selected.where((a) => a.id != id).toList());
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('People', style: theme.textTheme.labelLarge),
        if (widget.selected.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final person in widget.selected)
                InputChip(
                  avatar: CircleAvatar(
                    radius: 10,
                    child: Text(
                      person.displayName.isEmpty
                          ? '?'
                          : person.displayName[0].toUpperCase(),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  label: Text(person.displayName),
                  onDeleted: () => _remove(person.id),
                ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        TextField(
          controller: _query,
          decoration: const InputDecoration(
            hintText: 'Search Google contacts',
            prefixIcon: Icon(Icons.person_search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_notConnected)
          Text(
            'Connect Google to pick from your contacts '
            '(Classes & calendars → Google).',
            style: theme.textTheme.bodySmall,
          )
        else if (_needsReconnect)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Reconnect Google to allow contacts access.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () => showFeedManager(context),
                child: const Text('Reconnect'),
              ),
            ],
          )
        else if (_error != null)
          Text(
            _error!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          )
        else if (_query.text.trim().isEmpty)
          Text(
            'Start typing to search your contacts.',
            style: theme.textTheme.bodySmall,
          )
        else if (_results.isEmpty)
          Text(
            'No matches for "${_query.text.trim()}".',
            style: theme.textTheme.bodySmall,
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final contact = _results[index];
                final added = widget.selected
                    .any((a) => a.id == contact.id);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 14,
                    child: Text(
                      contact.displayName.isEmpty
                          ? '?'
                          : contact.displayName[0].toUpperCase(),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  title: Text(contact.displayName),
                  subtitle:
                      contact.email == null ? null : Text(contact.email!),
                  trailing: added
                      ? const Icon(Icons.check, size: 18)
                      : const Icon(Icons.add, size: 18),
                  onTap: added ? null : () => _add(contact),
                );
              },
            ),
          ),
      ],
    );
  }
}
