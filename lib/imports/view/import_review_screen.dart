import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../demo/demo_coordinator.dart';
import '../../demo/demo_mode.dart';
import '../../sync/auth_cubit.dart';
import '../../sync/sync_engine.dart';
import '../import_service.dart';

final _reviewDateFormat = DateFormat('EEE, MMM d');
final _reviewTimeFormat = DateFormat('h:mm a');

/// In-app approval inbox for one staged third-party import batch.
///
/// Patterned on the syllabus-import review sheet: nothing is created
/// until the user approves it, per item or all at once. Items that
/// collide with a live row render as "updates existing" with the
/// old → new value, so corrective re-scrapes are reviewable, not silent.
class ImportReviewScreen extends StatefulWidget {
  final ImportBatch batch;

  const ImportReviewScreen({super.key, required this.batch});

  @override
  State<ImportReviewScreen> createState() => _ImportReviewScreenState();
}

class _ImportReviewScreenState extends State<ImportReviewScreen> {
  late ImportBatch _batch = widget.batch;
  bool _busy = false;
  String? _error;

  ImportService get _service =>
      ImportService(context.read<AuthCubit>().syncClient);

  Future<void> _pullFresh() async {
    // Approved items land in the sync envelope; pull now so the
    // calendar/tasks reflect them without waiting for the 5-minute timer.
    try {
      await context.read<SyncEngine>().syncNow();
    } catch (_) {}
  }

  Future<void> _run(Future<ImportBatch> Function() call) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await call();
      if (!mounted) return;
      setState(() => _batch = updated);
      await _pullFresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'That didn\u2019t go through — try again. ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _batch.pending;
    final done = pending.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text('Import from ${_batch.source}'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              done
                  ? 'All ${_batch.items.length} item${_batch.items.length == 1 ? '' : 's'} decided — nothing left to review.'
                  : '${pending.length} of ${_batch.items.length} item${_batch.items.length == 1 ? '' : 's'} waiting for your call.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_error!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemCount: _batch.items.length,
              itemBuilder: (context, i) => _StagedTile(
                  batchId: _batch.id,
                  item: _batch.items[i],
                  onAct: _run,
                  service: _service,
                ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy || done
                        ? null
                        : () => _run(() => DemoMode.isActive
                            ? DemoCoordinator.demoApprove(
                                context, _batch.id)
                            : _service.approve(_batch.id)),
                    icon: const Icon(Icons.check),
                    label: Text('Approve all (${pending.length})'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || done
                        ? null
                        : () => _run(() => DemoMode.isActive
                            ? DemoCoordinator.demoReject(
                                context, _batch.id)
                            : _service.reject(_batch.id)),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject batch'),
                  ),
                  OutlinedButton.icon(
                    // Calendar overlay preview ships later; the button
                    // reserves its place in the layout now.
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Calendar preview isn\u2019t built yet — list review for now.'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('View in calendar'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StagedTile extends StatelessWidget {
  final int batchId;
  final StagedItem item;
  final ImportService service;
  final Future<void> Function(Future<ImportBatch> Function()) onAct;

  const _StagedTile({
    required this.batchId,
    required this.item,
    required this.service,
    required this.onAct,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decided = !item.isPending;
    final notes = item.data['notes'];
    final classLabel = item.data['classLabel'];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    item.isNode
                        ? Icons.check_circle_outline
                        : Icons.event_outlined,
                    size: 20,
                    color: decided
                        ? theme.colorScheme.outline
                        : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(item.title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: decided ? theme.colorScheme.outline : null,
                          )),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(item),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (notes is String && notes.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            notes.length > 140
                                ? '${notes.substring(0, 140)}…'
                                : notes,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      if (classLabel is String && classLabel.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(classLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.secondary,
                              )),
                        ),
                      if (item.isUpdate) _UpdateLine(item: item),
                    ],
                  ),
                ),
                if (item.isPending)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Approve',
                        icon: const Icon(Icons.check),
                        color: theme.colorScheme.primary,
                        onPressed: () => onAct(
                          () => DemoMode.isActive
                              ? DemoCoordinator.demoApprove(
                                  context, batchId,
                                  itemIds: [item.itemId])
                              : service.approve(
                                  batchId,
                                  itemIds: [
                                    '${item.collection}:${item.itemId}'
                                  ],
                                ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Discard',
                        icon: const Icon(Icons.close),
                        onPressed: () => onAct(
                          () => DemoMode.isActive
                              ? DemoCoordinator.demoDiscard(
                                  context, batchId, [item.itemId])
                              : service.discard(
                                  batchId,
                                  ['${item.collection}:${item.itemId}'],
                                ),
                        ),
                      ),
                    ],
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 4),
                    child: Chip(
                      label: Text(
                          item.status == 'approved' ? 'Added' : 'Discarded'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(StagedItem item) {
    final when = _formatWhen(item);
    final kind = item.isNode ? 'Task' : 'Event';
    if (when.isEmpty) return '$kind · no date';
    return item.isNode ? '$kind · due $when' : '$kind · $when';
  }
}

class _UpdateLine extends StatelessWidget {
  final StagedItem item;

  const _UpdateLine({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final oldV = _oldWhen(item);
    final newV = _formatWhen(item);
    final restore = item.existingDeleted;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: restore
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          restore
              ? 'You deleted this in the app — approving restores it.'
              : oldV == null || oldV == newV
                  ? 'Updates an item already in your schedule.'
                  : 'Updates existing: $oldV → $newV',
          style: theme.textTheme.labelSmall,
        ),
      ),
    );
  }
}

String _formatWhen(StagedItem item) {
  final raw = item.when;
  if (raw.isEmpty) return '';
  final dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  if (item.isNode) {
    // The scraper writes end-of-day (23:59) when only a date is known;
    // show the time only when it carries real information.
    final endOfDay = dt.hour == 23 && dt.minute == 59;
    final date = _reviewDateFormat.format(dt);
    return endOfDay ? date : '$date · ${_reviewTimeFormat.format(dt)}';
  }
  final endRaw = item.data['end'];
  final end = endRaw is String ? DateTime.tryParse(endRaw) : null;
  final start = '${_reviewDateFormat.format(dt)} · ${_reviewTimeFormat.format(dt)}';
  if (end == null) return start;
  return '$start – ${_reviewTimeFormat.format(end)}';
}

String? _oldWhen(StagedItem item) {
  final existing = item.existing;
  if (existing == null) return null;
  if (item.isNode) {
    final sched = existing['schedule'];
    final due = sched is Map ? sched['due'] : null;
    if (due is! String || due.isEmpty) return null;
    final dt = DateTime.tryParse(due);
    return dt == null ? due : _reviewDateFormat.format(dt);
  }
  final start = existing['start'];
  if (start is! String || start.isEmpty) return null;
  final dt = DateTime.tryParse(start);
  return dt == null ? start : _reviewDateFormat.format(dt);
}
