import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/granularity.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/view/transaction_assignment_dialog.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// The main waterfall ledger screen.
///
/// Displays the chronological cascade of confirmed and projected entries
/// with running balance, time-until labels, and a granularity selector
/// analogous to Google Calendar's week/month view toggle.
class WaterfallLedgerPage extends StatefulWidget {
  const WaterfallLedgerPage({super.key, this.showDrawer = true});

  final bool showDrawer;

  @override
  State<WaterfallLedgerPage> createState() => _WaterfallLedgerPageState();
}

class _WaterfallLedgerPageState extends State<WaterfallLedgerPage> {
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToPresent = false;

  /// Buckets the reader has expanded, keyed by [bucketKey]. Local, view-only
  /// state: collapsing is for readability, never a mutation of the model.
  final Set<String> _expandedBuckets = <String>{};

  static final _dateFormat = DateFormat('M/d/yy');
  static final _currencyFormat = NumberFormat.currency(symbol: '\$');

  /// Stable identity for a bucket across rebuilds. Buckets are recomputed
  /// on every rebuild, so the key has to be the bucket's own content, not
  /// its position.
  static String bucketKey(LedgerBucket bucket) =>
      '${bucket.granularity.name}:${bucket.bucketStart.toIso8601String()}';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToPresent(List<LedgerEntry> rows) {
    if (_hasScrolledToPresent || rows.isEmpty) return;

    final presentIndex = rows.indexWhere((e) => e.status == EntryStatus.confirmed);
    if (presentIndex == -1) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      
      final rowHeight = 56.0; // Estimated row height
      double targetOffset = (presentIndex * rowHeight) - 200.0;
      targetOffset = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
      
      _scrollController.jumpTo(targetOffset);
      setState(() {
        _hasScrolledToPresent = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      drawer: widget.showDrawer ? const AppDrawer() : null,
      body: BlocBuilder<WaterfallCubit, WaterfallState>(
        builder: (context, state) {
          // Scroll to the present if we haven't already
          if (!_hasScrolledToPresent && state.rows.isNotEmpty) {
            _scrollToPresent(state.rows);
          }

          return CustomScrollView(
            controller: _scrollController,
            slivers: [
              // ── Header ──
              SliverAppBar(
                expandedHeight: 140,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          colorScheme.primary,
                          colorScheme.primaryContainer,
                        ],
                      ),
                    ),
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Waterfall Ledger',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: colorScheme.onPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Balance (Plaid)',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                        color: colorScheme.onPrimary
                                            .withValues(alpha: 0.7),
                                      ),
                                    ),
                                    Text(
                                      _currencyFormat
                                          .format(state.startingBalance),
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                        color: colorScheme.onPrimary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const Spacer(),
                                // Projected balance at horizon
                                if (state.rows.isNotEmpty)
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        'Projected',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                          color: colorScheme.onPrimary
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                      Text(
                                        _currencyFormat.format(
                                            state.rows.first.runningBalance),
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                          color: colorScheme.onPrimary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── Granularity selector ──
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      _buildViewScaleDropdown(context, state),
                      if (state.viewScale == null) ...[
                        const SizedBox(width: 8),
                        _buildWaterfallConfigButton(context, state),
                      ],
                      const Spacer(),
                      Text(
                        _entrySummary(state),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Waterfall table ──
              if (state.rows.isEmpty)
                const SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.water_drop_outlined,
                            size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No entries yet',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Connect your bank, add a repeating template,\nor create a money node to get started.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      // One widget per bucket, plus its member rows when
                      // expanded. Built from state.buckets (already grouped
                      // by the cubit) so scrolling never re-groups.
                      final widgets = _bucketWidgets(context, state, theme);
                      return widgets[index];
                    },
                    childCount: _bucketWidgetCount(state),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showNodeEditor(context, enableMoney: true),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Dropdown to select the view scale (Waterfall, Daily, Weekly, etc.)
  Widget _buildViewScaleDropdown(
      BuildContext context, WaterfallState state) {
    final currentLabel =
        state.viewScale?.displayName ?? 'Waterfall';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: currentLabel,
          isDense: true,
          icon: const Icon(Icons.unfold_more, size: 18),
          items: [
            const DropdownMenuItem(
              value: 'Waterfall',
              child: Text('Waterfall'),
            ),
            ...TimeScale.values
                .where((s) => s != TimeScale.custom)
                .map((s) => DropdownMenuItem(
                      value: s.displayName,
                      child: Text(s.displayName),
                    )),
          ],
          onChanged: (value) {
            if (value == 'Waterfall') {
              context.read<WaterfallCubit>().setViewScale(null);
            } else {
              final scale = TimeScale.values.firstWhere(
                (s) => s.displayName == value,
              );
              context.read<WaterfallCubit>().setViewScale(scale);
            }
          },
        ),
      ),
    );
  }

  /// Button to configure waterfall thresholds.
  Widget _buildWaterfallConfigButton(
      BuildContext context, WaterfallState state) {
    return IconButton(
      icon: const Icon(Icons.tune, size: 20),
      tooltip: 'Configure waterfall thresholds',
      onPressed: () => _showWaterfallConfigDialog(context, state),
    );
  }

  // ── Bucketed (granular) rendering ──────────────────────────────────
  //
  // Waterfall mode groups rows by distance: nearby days bucket daily,
  // mid-range weeks bucket weekly, far-out months bucket monthly. The
  // thresholds behind that are user-configurable (the tune button) and
  // are persisted on WaterfallState.
  //
  // Collapsing hides rows for readability only. state.rows is untouched
  // and state.buckets holds references to the same LedgerEntry objects,
  // so nothing is ever lost — expanding rebuilds the list from the model.

  /// Flattened widget list: a header per bucket, then the bucket's member
  /// rows when it is expanded.
  List<Widget> _bucketWidgets(
      BuildContext context, WaterfallState state, ThemeData theme) {
    final out = <Widget>[];
    for (final bucket in state.buckets) {
      out.add(_buildBucketHeader(context, state, bucket, theme));
      if (!bucket.isCollapsible || _expandedBuckets.contains(bucketKey(bucket))) {
        for (final entry in bucket.entries) {
          out.add(_buildWaterfallRow(context, entry, theme));
        }
      }
    }
    return out;
  }

  int _bucketWidgetCount(WaterfallState state) {
    var count = 0;
    for (final bucket in state.buckets) {
      count += 1;
      if (!bucket.isCollapsible ||
          _expandedBuckets.contains(bucketKey(bucket))) {
        count += bucket.entries.length;
      }
    }
    return count;
  }

  /// Collapsed buckets read as one summary line carrying the whole bucket.
  String _entrySummary(WaterfallState state) {
    final entries = state.rows.length;
    final buckets = state.buckets.length;
    if (buckets == 0 || buckets == entries) {
      return '$entries ${_plural(entries, 'entry', 'entries')}';
    }
    return '$entries ${_plural(entries, 'entry', 'entries')} · '
        '$buckets ${_plural(buckets, 'bucket', 'buckets')}';
  }

  static String _plural(int n, String one, String many) =>
      n == 1 ? one : many;

  /// Header for one bucket. Tapping toggles expansion.
  Widget _buildBucketHeader(BuildContext context, WaterfallState state,
      LedgerBucket bucket, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final expanded =
        !bucket.isCollapsible || _expandedBuckets.contains(bucketKey(bucket));
    final net = bucket.netAmount;
    final projected = !bucket.hasConfirmed;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: InkWell(
        onTap: bucket.isCollapsible
            ? () {
                setState(() {
                  final key = bucketKey(bucket);
                  if (!_expandedBuckets.remove(key)) {
                    _expandedBuckets.add(key);
                  }
                });
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (bucket.isCollapsible)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                )
              else
                const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _bucketLabel(bucket),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${bucket.entries.length} '
                    '${_plural(bucket.entries.length, 'entry', 'entries')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '${net < 0 ? '' : '+'}${_currencyFormat.format(net)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: net < 0 ? colorScheme.error : Colors.green.shade700,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'balance',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    _currencyFormat.format(bucket.runningBalance),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: projected
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                      fontStyle: projected ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Human label for a bucket, e.g. "Wed, Oct 8", "Week of Oct 5",
  /// "October 2026".
  String _bucketLabel(LedgerBucket bucket) {
    switch (bucket.granularity) {
      case DisplayGranularity.daily:
        return DateFormat('EEE, MMM d').format(bucket.bucketStart);
      case DisplayGranularity.weekly:
        return 'Week of ${DateFormat('MMM d').format(bucket.bucketStart)}';
      case DisplayGranularity.monthly:
        return DateFormat('MMMM yyyy').format(bucket.bucketStart);
    }
  }

  /// A single row in the waterfall table.
  Widget _buildWaterfallRow(
      BuildContext context, LedgerEntry entry, ThemeData theme) {
    final isProjected = entry.status != EntryStatus.confirmed;
    final isIncome = entry.amount > 0;
    final colorScheme = theme.colorScheme;

    // Determine the row's type indicator icon
    final IconData typeIcon;
    switch (entry.type) {
      case EntryType.transaction:
        typeIcon = Icons.receipt;
        break;
      case EntryType.expense:
        typeIcon = entry.isConcrete ? Icons.check_circle : Icons.circle_outlined;
        break;
      case EntryType.recurringProjection:
        typeIcon = Icons.repeat;
        break;
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        color: isProjected
            ? colorScheme.surfaceContainerLow.withValues(alpha: 0.5)
            : null,
      ),
      child: InkWell(
        onTap: () => _onRowTap(context, entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
            // Type indicator
            Icon(
              typeIcon,
              size: 16,
              color: isProjected
                  ? colorScheme.outline.withValues(alpha: 0.5)
                  : (isIncome
                      ? Colors.green.shade600
                      : Colors.red.shade600),
            ),
            const SizedBox(width: 12),

            // Name and category
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontStyle:
                          isProjected ? FontStyle.italic : FontStyle.normal,
                      color: isProjected
                          ? colorScheme.onSurface.withValues(alpha: 0.7)
                          : colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (entry.category != null)
                    Text(
                      entry.category!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),

            // Amount
            Expanded(
              flex: 2,
              child: Text(
                _currencyFormat.format(entry.amount),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isIncome
                      ? Colors.green.shade700
                      : Colors.red.shade700,
                ),
                textAlign: TextAlign.right,
              ),
            ),

            const SizedBox(width: 8),

            // Date
            SizedBox(
              width: 56,
              child: Text(
                _dateFormat.format(entry.date),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(width: 8),

            // Time until
            SizedBox(
              width: 72,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: entry.timeUntilLabel == 'Past'
                      ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                      : entry.timeUntilLabel == 'Today'
                          ? colorScheme.primary.withValues(alpha: 0.15)
                          : colorScheme.surfaceContainerHigh
                              .withValues(alpha: 0.5),
                ),
                child: Text(
                  entry.timeUntilLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: entry.timeUntilLabel == 'Today'
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: entry.timeUntilLabel == 'Today'
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Running balance
            SizedBox(
              width: 80,
              child: Text(
                _currencyFormat.format(entry.runningBalance),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: entry.runningBalance >= 0
                      ? colorScheme.onSurface
                      : Colors.red.shade800,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

  /// Handle tap on a waterfall row.
  void _onRowTap(BuildContext context, LedgerEntry entry) {
    switch (entry.type) {
      case EntryType.transaction:
        // Tap a transaction → assign to a node
        final transaction = context.read<TransactionsCubit>().state
            .firstWhere(
              (t) => t.id == entry.sourceId,
              orElse: () => throw StateError('Transaction not found'),
            );
        showDialog(
          context: context,
          builder: (_) => TransactionAssignmentDialog(transaction: transaction),
        );
        break;

      case EntryType.expense:
      case EntryType.recurringProjection:
        // Tap a money node (or a generated instance) → edit it
        final node =
            context.read<NodeCubit>().byId(entry.sourceId);
        if (node != null) {
          showNodeEditor(context, existing: node);
        }
        break;
    }
  }

  void _showWaterfallConfigDialog(
      BuildContext context, WaterfallState state) {
    final monthlyController =
        TextEditingController(text: state.monthlyThresholdDays.toString());
    final weeklyController =
        TextEditingController(text: state.weeklyThresholdDays.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Waterfall Thresholds'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Configure when the waterfall view switches granularity based on how far away events are.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: monthlyController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Show monthly beyond (days)',
                helperText: 'Events further than this show as monthly',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: weeklyController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Show daily within (days)',
                helperText: 'Events closer than this show as daily',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final monthly = int.tryParse(monthlyController.text);
              final weekly = int.tryParse(weeklyController.text);
              if (monthly != null && weekly != null) {
                context.read<WaterfallCubit>().setWaterfallThresholds(
                      monthlyThresholdDays: monthly,
                      weeklyThresholdDays: weekly,
                    );
                Navigator.pop(ctx);
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
