import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/view/class_names.dart';

/// Picks or creates a class node for a work item.
///
/// Existing class nodes are listed first. Imported homework also suggests
/// classes that do not have a node yet (the source binding is derived from
/// the feed and label), so the first manual task for a feed class creates
/// the class node and adopts the already-imported work in one action.
/// Returns the chosen class node id, or null when dismissed.
Future<String?> showClassPicker(
  BuildContext context, {
  String? selectedId,
  bool createOnly = false,
}) async {
  List<Node> nodes;
  try {
    nodes = context.read<NodeCubit>().state;
  } catch (_) {
    return null;
  }
  final className = classNameResolver(context);
  final classNodes = nodes.where((n) => n.isClassNode).toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  final boundKeys = <String>{
    for (final node in classNodes)
      for (final source in node.classFacet!.sources) source.key,
  };
  final suggestions = <String, ClassSource>{};
  for (final node in nodes) {
    if (node.sourceEventId == null && node.feedId == null) continue;
    final source = classSourceOfNode(
      feedId: node.feedId,
      classId: node.classId,
      classLabel: node.classLabel,
    );
    if (source == null || boundKeys.contains(source.key)) continue;
    suggestions.putIfAbsent(source.key, () => source);
  }
  if (!context.mounted) return null;
  return showDialog<String?>(
    context: context,
    builder: (dialogContext) => _ClassPickerDialog(
      classNodes: classNodes,
      suggestions: suggestions,
      className: className,
      selectedId: selectedId,
      createOnly: createOnly,
    ),
  );
}

class _ClassPickerDialog extends StatefulWidget {
  final List<Node> classNodes;
  final Map<String, ClassSource> suggestions;
  final String Function(String key) className;
  final String? selectedId;
  final bool createOnly;

  const _ClassPickerDialog({
    required this.classNodes,
    required this.suggestions,
    required this.className,
    this.selectedId,
    this.createOnly = false,
  });

  @override
  State<_ClassPickerDialog> createState() => _ClassPickerDialogState();
}

class _ClassPickerDialogState extends State<_ClassPickerDialog> {
  late final TextEditingController _search;
  late final TextEditingController _newName;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
    _newName = TextEditingController();
  }

  @override
  void dispose() {
    _search.dispose();
    _newName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final classes = widget.createOnly
        ? const <Node>[]
        : q.isEmpty
        ? widget.classNodes
        : widget.classNodes
              .where((n) => n.title.toLowerCase().contains(q))
              .toList();
    final suggestions = widget.suggestions.values.where((source) {
      if (q.isEmpty) return true;
      return _sourceLabel(source).toLowerCase().contains(q) ||
          source.feedId.toLowerCase().contains(q);
    }).toList();
    final typed = _newName.text.trim();
    return AlertDialog(
      title: Text(widget.createOnly ? 'New class' : 'Class'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search classes',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final node in classes)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.school_outlined, size: 20),
                      title: Text(node.title),
                      subtitle: Text(_classSubtitle(node)),
                      trailing: node.id == widget.selectedId
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.of(context).pop(node.id),
                    ),
                  for (final source in suggestions)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add, size: 20),
                      title: Text('Create “${_sourceLabel(source)}”'),
                      subtitle: Text(
                        source.classLabel == null
                            ? 'Bind this feed as a class'
                            : 'Bind ${source.classLabel} from this feed',
                      ),
                      onTap: () =>
                          _create(context, _sourceLabel(source), source),
                    ),
                  if (classes.isEmpty && suggestions.isEmpty && typed.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No classes yet. Type a name below to create one.',
                      ),
                    ),
                ],
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newName,
                    decoration: const InputDecoration(
                      labelText: 'New class name',
                      hintText: 'CMLIT 201',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: typed.isEmpty
                      ? null
                      : () => _create(context, typed, null),
                  child: const Text('Create'),
                ),
              ],
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

  String _sourceLabel(ClassSource source) {
    final label = source.classLabel;
    if (label != null && label.isNotEmpty) return label;
    return widget.className(source.feedId);
  }

  static String _classSubtitle(Node node) {
    final sources = node.classFacet?.sources ?? const <ClassSource>[];
    if (sources.isEmpty) return 'manual class';
    return sources.length == 1
        ? '1 feed source'
        : '${sources.length} feed sources';
  }

  Future<void> _create(
    BuildContext context,
    String label,
    ClassSource? source,
  ) async {
    final cubit = context.read<NodeCubit>();
    Map<String, String> feedNames = const {};
    try {
      feedNames = {
        for (final feed in context.read<FeedCubit>().state)
          feed.id: feed.name,
      };
    } catch (_) {}
    // Opening the picker from Home/Tasks may be the first structural pass;
    // ensure the Homework container before parenting this class.
    final homeworkId = cubit.ensureHomeworkStructure(
      force: true,
      feedNames: feedNames,
    );
    if (source != null) {
      // The structural pass may already have created the class for this
      // feed; reuse it instead of duplicating.
      for (final node in cubit.state) {
        if (!node.isClassNode) continue;
        if (node.classFacet!.matchesNodeSource(source)) {
          if (context.mounted) Navigator.of(context).pop(node.id);
          return;
        }
      }
    }
    final classNode = Node(
      id: 'node:class:${DateTime.now().microsecondsSinceEpoch}',
      title: label.trim().isEmpty ? 'Class' : label.trim(),
      parentIds: [if (homeworkId != null) homeworkId],
      createdAt: DateTime.now(),
      classFacet: ClassFacet(sources: [if (source != null) source]),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final error = cubit.addNode(classNode);
    if (error != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
      return;
    }
    if (source != null) _adoptSourceTasks(cubit, classNode, source);
    if (context.mounted) Navigator.of(context).pop(classNode.id);
  }

  /// Existing imported work from the same feed/label joins the new class
  /// node immediately, so class metrics and the class grouping are useful
  /// without waiting for a resync.
  static void _adoptSourceTasks(
    NodeCubit cubit,
    Node classNode,
    ClassSource source,
  ) {
    final upserts = <Node>[];
    for (final node in cubit.state) {
      if (node.id == classNode.id) continue;
      final nodeSource = classSourceOfNode(
        feedId: node.feedId,
        classId: node.classId,
        classLabel: node.classLabel,
      );
      if (nodeSource == null || nodeSource.key != source.key) continue;
      final parents = [
        for (final parent in node.parentIds)
          if (cubit.byId(parent)?.isClassNode != true) parent,
      ];
      if (!node.isInstance && !parents.contains(classNode.id)) {
        parents.add(classNode.id);
      }
      upserts.add(
        node.copyWith(
          parentIds: parents,
          classNodeId: classNode.id,
          classLabel: node.classLabel ?? classNode.title,
        ),
      );
    }
    if (upserts.isNotEmpty) cubit.writeNodes(upserts: upserts);
  }


}
