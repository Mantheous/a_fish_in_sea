import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';

/// Parent chips plus an "Add parent" picker for the node editor.
///
/// The picker opens a searchable list: the goal tree can hold hundreds of
/// nodes, so scrolling a plain list to find one is hopeless. [excludeId]
/// (and its descendants) is hidden so the pick cannot create a cycle.
class ParentsField extends StatelessWidget {
  final List<String> selected;
  final String? excludeId;
  final ValueChanged<List<String>> onChanged;

  const ParentsField({
    super.key,
    required this.selected,
    required this.excludeId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final nodes = goalNodes(context.watch<NodeCubit>().state);
    final names = {for (final n in nodes) n.id: n.title};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Parents', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final id in selected)
              Chip(
                label: Text(
                  names[id] ?? 'node',
                  overflow: TextOverflow.ellipsis,
                ),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () =>
                    onChanged(selected.where((p) => p != id).toList()),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Add parent'),
              onPressed: () => _pick(context, nodes),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context, List<Node> nodes) async {
    final excluded = <String>{if (excludeId != null) excludeId!};
    if (excludeId != null) {
      excluded.addAll(descendantIds(excludeId!, nodes));
    }
    final candidates = nodes.where((n) => !excluded.contains(n.id)).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No eligible parents')));
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _ParentPickerDialog(candidates: candidates),
    );
    if (picked != null && !selected.contains(picked)) {
      onChanged([...selected, picked]);
    }
  }
}

class _ParentPickerDialog extends StatefulWidget {
  final List<Node> candidates;

  const _ParentPickerDialog({required this.candidates});

  @override
  State<_ParentPickerDialog> createState() => _ParentPickerDialogState();
}

class _ParentPickerDialogState extends State<_ParentPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((n) =>
                n.title.toLowerCase().contains(q) ||
                (n.notes?.toLowerCase().contains(q) ?? false))
            .toList();
    return AlertDialog(
      title: const Text('Add parent'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search nodes',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: shown.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No nodes match.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final n = shown[index];
                        return ListTile(
                          dense: true,
                          title: Text(
                            n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(context).pop(n.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
