import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/settings_cubit.dart';
import '../model/feed.dart';
import '../service/syllabus_draft.dart';
import '../service/syllabus_llm_client.dart';
import '../service/syllabus_parser.dart';

Future<void> showSyllabusImport(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _SyllabusImportSheet(),
  );
}

enum _Step { input, generating, review }

class _SyllabusImportSheet extends StatefulWidget {
  const _SyllabusImportSheet();

  @override
  State<_SyllabusImportSheet> createState() => _SyllabusImportSheetState();
}

class _SyllabusImportSheetState extends State<_SyllabusImportSheet> {
  _Step _step = _Step.input;
  final _text = TextEditingController();
  String? _feedId;
  String? _fileName;
  List<_ReviewDraft> _drafts = const [];
  /// True when drafts came from the Alauris model; false = on-device parse.
  bool _usedLlm = false;
  String? _notice;

  @override
  void dispose() {
    _text.dispose();
    for (final d in _drafts) {
      d.title.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.9;
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: switch (_step) {
          _Step.input => _InputStep(
              text: _text,
              feedId: _feedId,
              fileName: _fileName,
              onFeedChanged: (v) => setState(() => _feedId = v),
              onPickFile: _pickFile,
              onClearFile: () => setState(() => _fileName = null),
              onGenerate: _generate,
            ),
          _Step.generating => const _GeneratingStep(),
          _Step.review => _ReviewStep(
              drafts: _drafts,
              usedLlm: _usedLlm,
              notice: _notice,
              onToggleAll: _toggleAll,
              onCreate: _create,
              onBack: () => setState(() => _step = _Step.input),
            ),
        },
      ),
    );
  }

  Future<void> _pickFile() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'md', 'markdown'],
      );
      if (file == null) return;
      late final String content;
      try {
        final bytes = await file.readAsBytes();
        content = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not read that file — paste the text instead.'),
            ),
          );
        }
        return;
      }
      if (content.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That file looks empty.')),
          );
        }
        return;
      }
      setState(() {
        _text.text = content.trim();
        _fileName = file.name;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open that file.')),
        );
      }
    }
  }

  Future<void> _generate() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste some syllabus text first')),
      );
      return;
    }
    setState(() {
      _step = _Step.generating;
      _notice = null;
    });
    // Prefer the Alauris model; fall back to the on-device parser when
    // the server is unreachable (off Tailscale, server down, no URL set).
    List<SyllabusDraft> drafts = const [];
    var usedLlm = false;
    String? notice;
    try {
      final proxyBase = context.read<SettingsCubit>().state.icalProxyBase;
      drafts = await extractSyllabusViaServer(
        text,
        proxyBase: () => proxyBase,
      );
      usedLlm = true;
      if (drafts.isEmpty) {
        drafts = parseSyllabusLocally(text);
        notice = drafts.isEmpty
            ? 'The model found no assignments — try pasting more of the schedule.'
            : 'The model found nothing dated, so on-device results are shown.';
        usedLlm = drafts.isEmpty ? true : false;
      }
    } on SyllabusLlmException {
      drafts = parseSyllabusLocally(text);
      notice = drafts.isEmpty
          ? 'No assignments found — try pasting more of the schedule.'
          : 'Server unreachable — on-device results shown.';
    }
    if (!mounted) return;
    setState(() {
      _usedLlm = usedLlm;
      _notice = notice;
      _drafts = drafts
          .map((d) => _ReviewDraft(
                draft: d,
                title: TextEditingController(text: d.title),
                selected: true,
              ))
          .toList();
      _step = _Step.review;
    });
  }

  void _toggleAll(bool select) {
    setState(() {
      for (final d in _drafts) {
        d.selected = select;
      }
    });
  }

  void _create() {
    final feedId = _feedId;
    Feed? feed;
    if (feedId != null) {
      try {
        feed = context.read<FeedCubit>().byId(feedId);
      } catch (_) {}
    }
    final nodes = <Node>[];
    for (final d in _drafts) {
      if (!d.selected) continue;
      final title = d.title.text.trim();
      if (title.isEmpty) continue;
      nodes.add(d.draft
          .copyWith(title: title, due: d.due, clearDue: d.due == null)
          .toNode(classId: feed?.id, classLabel: feed?.name));
    }
    if (nodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Check at least one assignment first')),
      );
      return;
    }
    final nodeCubit = context.read<NodeCubit>();
    for (final node in nodes) {
      nodeCubit.addNode(node);
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Created ${nodes.length} node${nodes.length == 1 ? '' : 's'}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => context.read<UndoCubit>().undo(),
        ),
      ),
    );
  }
}

class _ReviewDraft {
  SyllabusDraft draft;
  final TextEditingController title;
  bool selected;

  _ReviewDraft({required this.draft, required this.title, this.selected = true});

  DateTime? get due => draft.due;

  set due(DateTime? value) {
    draft = draft.copyWith(due: value, clearDue: value == null);
  }
}

class _InputStep extends StatelessWidget {
  final TextEditingController text;
  final String? feedId;
  final String? fileName;
  final ValueChanged<String?> onFeedChanged;
  final VoidCallback onPickFile;
  final VoidCallback onClearFile;
  final VoidCallback onGenerate;

  const _InputStep({
    required this.text,
    required this.feedId,
    required this.fileName,
    required this.onFeedChanged,
    required this.onPickFile,
    required this.onClearFile,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    List<Feed> feeds = const [];
    try {
      feeds = context.watch<FeedCubit>().state;
    } catch (_) {}
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Import from syllabus',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        Text(
          'Paste a syllabus (or load a .txt/.md file). Review and approve tasks before anything is created.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: text,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: 'e.g.\nHW 3 due Oct 12\nMidterm: Sep 20\nFinal project Dec 5',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: onPickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Pick .txt/.md'),
            ),
            if (fileName != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(fileName!,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              IconButton(
                tooltip: 'Clear file',
                icon: const Icon(Icons.clear),
                onPressed: onClearFile,
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: feedId,
          decoration: const InputDecoration(
            labelText: 'Class (optional)',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('No class')),
            for (final feed in feeds)
              DropdownMenuItem<String?>(value: feed.id, child: Text(feed.name)),
          ],
          onChanged: onFeedChanged,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onGenerate,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Find tasks'),
        ),
      ],
    );
  }
}

class _GeneratingStep extends StatelessWidget {
  const _GeneratingStep();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Reading syllabus…'),
        ],
      ),
    );
  }
}

class _ReviewStep extends StatelessWidget {
  final List<_ReviewDraft> drafts;
  final bool usedLlm;
  final String? notice;
  final ValueChanged<bool> onToggleAll;
  final VoidCallback onCreate;
  final VoidCallback onBack;

  const _ReviewStep({
    required this.drafts,
    required this.usedLlm,
    required this.notice,
    required this.onToggleAll,
    required this.onCreate,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final selected = drafts.where((d) => d.selected).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
            ),
            Expanded(
              child: Text('Review ${drafts.length} task${drafts.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                usedLlm ? 'AI' : 'On-device',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
        if (notice != null) ...[
          const SizedBox(height: 4),
          Text(notice!, style: Theme.of(context).textTheme.bodySmall),
        ],
        Row(
          children: [
            TextButton(
              onPressed: () => onToggleAll(true),
              child: const Text('Select all'),
            ),
            TextButton(
              onPressed: () => onToggleAll(false),
              child: const Text('None'),
            ),
            const Spacer(),
            Text('$selected selected',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Expanded(
          child: drafts.isEmpty
              ? const Center(child: Text('No tasks found.'))
              : ListView.builder(
                  itemCount: drafts.length,
                  itemBuilder: (context, index) =>
                      _DraftTile(draft: drafts[index]),
                ),
        ),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.check),
          label: Text('Create $selected task${selected == 1 ? '' : 's'}'),
        ),
      ],
    );
  }
}

class _DraftTile extends StatefulWidget {
  final _ReviewDraft draft;

  const _DraftTile({required this.draft});

  @override
  State<_DraftTile> createState() => _DraftTileState();
}

class _DraftTileState extends State<_DraftTile> {
  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final due = draft.due;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: draft.selected,
              onChanged: (v) => setState(() => draft.selected = v ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: draft.title,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      ActionChip(
                        label: Text(
                          due == null
                              ? 'No due date'
                              : 'Due ${DateFormat('EEE, MMM d').format(due)}',
                        ),
                        avatar: const Icon(Icons.event, size: 16),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: due ?? DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() => draft.due = picked);
                          }
                        },
                      ),
                      if (due != null)
                        IconButton(
                          tooltip: 'Clear due date',
                          icon: const Icon(Icons.event_busy, size: 20),
                          onPressed: () => setState(() => draft.due = null),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
