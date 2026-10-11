import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../sync/auth_cubit.dart';
import '../import_service.dart';
import 'import_review_screen.dart';

/// Home-screen card announcing staged third-party imports.
///
/// Self-contained and server-driven: it fetches GET /imports/pending on
/// entry and renders nothing (zero clutter) when the inbox is empty or
/// unreachable. Deliberately NOT persisted — the server is the source of
/// truth and the call is cheap, so this adds no HydratedBloc surface.
class ImportInboxCard extends StatefulWidget {
  const ImportInboxCard({super.key});

  @override
  State<ImportInboxCard> createState() => _ImportInboxCardState();
}

class _ImportInboxCardState extends State<ImportInboxCard> {
  List<ImportBatch> _batches = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<ImportBatch> batches = const [];
    try {
      final service =
          ImportService(context.read<AuthCubit>().syncClient);
      batches = await service.pending();
    } catch (_) {
      // Offline / signed out / server down: stay invisible, never noisy.
    }
    if (!mounted) return;
    setState(() {
      _batches = batches;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _batches.isEmpty) return const SizedBox.shrink();
    final total = _batches.fold<int>(0, (n, b) => n + b.pendingCount);
    if (total == 0) return const SizedBox.shrink();
    final sources = _batches.map((b) => b.source).toSet().join(', ');
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.inbox_outlined),
        title: Text(
          'Import received: $total item${total == 1 ? '' : 's'} to review',
        ),
        subtitle: Text('From $sources'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          // One batch is the common case; several open as a picker.
          final batch = _batches.length == 1
              ? _batches.first
              : await _pickBatch(context);
          if (batch == null || !context.mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ImportReviewScreen(batch: batch),
            ),
          );
          await _load();
        },
      ),
    );
  }

  Future<ImportBatch?> _pickBatch(BuildContext context) {
    return showDialog<ImportBatch>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose an import'),
        children: [
          for (final batch in _batches)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(batch),
              child: Text(
                '${batch.source} · ${batch.pendingCount} item${batch.pendingCount == 1 ? '' : 's'}',
              ),
            ),
        ],
      ),
    );
  }
}
