import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/view/expense_detail_dialog.dart';
import 'package:a_fish_in_sea/finances/view/transaction_assignment_dialog.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// The main waterfall ledger screen.
///
/// Displays the chronological cascade of confirmed and projected entries
/// with running balance, time-until labels, and a granularity selector
/// analogous to Google Calendar's week/month view toggle.
class WaterfallLedgerPage extends StatefulWidget {
  const WaterfallLedgerPage({super.key, this.showBottomNav = true});

  final bool showBottomNav;

  @override
  State<WaterfallLedgerPage> createState() => _WaterfallLedgerPageState();
}

class _WaterfallLedgerPageState extends State<WaterfallLedgerPage> {
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToPresent = false;

  static final _dateFormat = DateFormat('M/d/yy');
  static final _currencyFormat = NumberFormat.currency(symbol: '\$');

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
      bottomNavigationBar: widget.showBottomNav ? const NavBar() : null,
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
                        '${state.rows.length} entries',
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
                          'Connect your bank, add recurring rules,\nor create expenses to get started.',
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
                      final entry = state.rows[index];
                      return _buildWaterfallRow(context, entry, theme);
                    },
                    childCount: state.rows.length,
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddExpenseDialog(context),
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
        // Tap a transaction → assign to an expense
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
        // Tap an expense → edit it
        final expense = context.read<ExpenseCubit>().findById(entry.sourceId);
        if (expense != null) {
          showDialog(
            context: context,
            builder: (_) => ExpenseDetailDialog(expense: expense),
          );
        }
        break;

      case EntryType.recurringProjection:
        // Tap a projection → create a concrete expense from it
        _showCreateExpenseFromProjection(context, entry);
        break;
    }
  }

  void _showCreateExpenseFromProjection(BuildContext context, LedgerEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Expense'),
        content: Text(
          'Create an editable expense from this projection?\n\n'
          '${entry.name}\n'
          '${_currencyFormat.format(entry.amount)} on ${_dateFormat.format(entry.date)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              context.read<ExpenseCubit>().addExpense(Expense(
                id: 'exp_${DateTime.now().millisecondsSinceEpoch}',
                name: entry.name,
                amount: entry.amount,
                date: entry.date,
                category: entry.category,
                sourceRuleId: entry.sourceId.contains('_gen_')
                    ? entry.sourceId.split('_gen_').first
                    : null,
                status: ExpenseStatus.projected,
              ));
              Navigator.pop(ctx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────
  // Dialogs
  // ──────────────────────────────────────────────────────────────────

  void _showAddExpenseDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    DateTime date = DateTime.now();
    bool isExpense = true;
    String? category;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Expense'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name'),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Amount', prefixText: '\$ '),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  ChoiceChip(
                      label: const Text('Expense'),
                      selected: isExpense,
                      onSelected: (_) =>
                          setDialogState(() => isExpense = true)),
                  const SizedBox(width: 8),
                  ChoiceChip(
                      label: const Text('Income'),
                      selected: !isExpense,
                      onSelected: (_) =>
                          setDialogState(() => isExpense = false)),
                ]),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Date: ${DateFormat('yyyy-MM-dd').format(date)}'),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setDialogState(() => date = picked);
                  },
                ),
                TextField(
                  decoration: const InputDecoration(
                      labelText: 'Category (optional)'),
                  onChanged: (v) => category = v.isEmpty ? null : v,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final parsed = double.tryParse(amountCtrl.text.trim());
                if (name.isEmpty || parsed == null) return;

                final amount = isExpense ? -parsed.abs() : parsed.abs();
                context.read<ExpenseCubit>().addExpense(Expense(
                  id: 'exp_${DateTime.now().millisecondsSinceEpoch}_${name.hashCode}',
                  name: name,
                  amount: amount,
                  date: date,
                  category: category,
                  status: date.isBefore(DateTime.now())
                      ? ExpenseStatus.due
                      : ExpenseStatus.projected,
                ));
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
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
