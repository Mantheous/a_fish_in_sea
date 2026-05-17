import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/finances/service/plaid_link_handler.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Bank connection page — connect via Plaid Link or sandbox shortcuts.
class PlaidLinkPage extends StatefulWidget {
  const PlaidLinkPage({super.key});

  @override
  State<PlaidLinkPage> createState() => _PlaidLinkPageState();
}

class _PlaidLinkPageState extends State<PlaidLinkPage> {
  static final _currencyFormat = NumberFormat.currency(symbol: '\$');

  @override
  void initState() {
    super.initState();
    final plaidCubit = context.read<PlaidCubit>();
    if (!plaidCubit.state.isConnected) {
      plaidCubit.checkExistingConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      bottomNavigationBar: const NavBar(),
      body: BlocBuilder<PlaidCubit, PlaidState>(
        builder: (context, plaidState) {
          return CustomScrollView(
            slivers: [
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
                          colorScheme.tertiary,
                          colorScheme.tertiaryContainer,
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
                              'Bank Connection',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: colorScheme.onTertiary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _buildStatusChip(plaidState, colorScheme),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _buildConnectionCard(context, plaidState, theme),
                ),
              ),
              if (plaidState.currentBalance != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Icon(Icons.account_balance_wallet,
                                color: colorScheme.primary, size: 32),
                            const SizedBox(width: 16),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Total Balance',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant)),
                                Text(
                                  _currencyFormat
                                      .format(plaidState.currentBalance),
                                  style:
                                      theme.textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: plaidState.currentBalance! >= 0
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (plaidState.accounts.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child:
                        Text('Accounts', style: theme.textTheme.titleMedium),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final account = plaidState.accounts[index];
                      final name = account['name'] ?? 'Account';
                      final type = account['type'] ?? '';
                      final balances =
                          account['balances'] as Map<String, dynamic>?;
                      final current =
                          (balances?['current'] as num?)?.toDouble();

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        child: Card(
                          child: ListTile(
                            leading: Icon(
                              type == 'depository'
                                  ? Icons.savings
                                  : type == 'credit'
                                      ? Icons.credit_card
                                      : Icons.account_balance,
                              color: colorScheme.primary,
                            ),
                            title: Text(name as String),
                            subtitle: Text(type as String),
                            trailing: current != null
                                ? Text(
                                    _currencyFormat.format(current),
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      );
                    },
                    childCount: plaidState.accounts.length,
                  ),
                ),
              ],
              if (plaidState.isConnected)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _syncTransactions(context),
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync Transactions'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () =>
                              context.read<PlaidCubit>().disconnect(),
                          icon: const Icon(Icons.link_off),
                          label: const Text('Disconnect Bank'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (plaidState.isConnected)
                SliverToBoxAdapter(
                  child: _buildRecentTransactions(context, theme),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusChip(PlaidState state, ColorScheme colorScheme) {
    final Color chipColor;
    final String label;
    final IconData icon;

    switch (state.status) {
      case PlaidConnectionStatus.connected:
        chipColor = Colors.green;
        label = 'Connected';
        icon = Icons.check_circle;
        break;
      case PlaidConnectionStatus.connecting:
        chipColor = Colors.orange;
        label = 'Connecting…';
        icon = Icons.sync;
        break;
      case PlaidConnectionStatus.error:
        chipColor = Colors.red;
        label = 'Error';
        icon = Icons.error;
        break;
      case PlaidConnectionStatus.disconnected:
        chipColor = Colors.grey;
        label = 'Disconnected';
        icon = Icons.link_off;
        break;
    }

    return Chip(
      avatar: Icon(icon, color: chipColor, size: 18),
      label: Text(label),
      backgroundColor: chipColor.withValues(alpha: 0.15),
      side: BorderSide.none,
    );
  }

  Widget _buildConnectionCard(
      BuildContext context, PlaidState state, ThemeData theme) {
    if (state.status == PlaidConnectionStatus.connecting) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(PlaidLinkHandler.isSupported
                    ? 'Opening Plaid Link…'
                    : 'Connecting to sandbox bank…'),
              ],
            ),
          ),
        ),
      );
    }

    if (state.status == PlaidConnectionStatus.error) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
              const SizedBox(height: 8),
              Text(state.errorMessage ?? 'Unknown error',
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Make sure the Plaid server is running (see launch config "Flutter & Plaid Server").',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => context.read<PlaidCubit>().connectBank(),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (!state.isConnected) {
      final showDesktopHint = !PlaidLinkHandler.isSupported;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.account_balance,
                  size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Connect Your Bank', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                showDesktopHint
                    ? 'On desktop, use sandbox quick connect. On mobile or web, Plaid Link lets you sign in to a test bank.'
                    : 'Link your bank account to import transactions and track your balance. In sandbox mode, use Plaid test credentials.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.read<PlaidCubit>().connectBank(),
                icon: const Icon(Icons.link),
                label: Text(showDesktopHint
                    ? 'Connect Bank (Sandbox)'
                    : 'Connect Bank'),
              ),
              if (showDesktopHint && kDebugMode) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () =>
                      context.read<PlaidCubit>().sandboxAutoConnect(),
                  child: const Text('Sandbox quick connect'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Card(
      child: ListTile(
        leading: Icon(Icons.check_circle, color: Colors.green.shade600),
        title: const Text('Bank connected'),
        subtitle: Text('User id: ${state.userId.substring(0, 8)}…'),
      ),
    );
  }

  Future<void> _syncTransactions(BuildContext context) async {
    final plaidCubit = context.read<PlaidCubit>();
    final transactionsCubit = context.read<TransactionsCubit>();

    final rawTransactions = await plaidCubit.fetchTransactions();
    final transactions =
        rawTransactions.map((json) => Transaction.fromPlaid(json)).toList();

    transactionsCubit.syncFromPlaid(transactions);
    await plaidCubit.fetchBalance();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Synced ${transactions.length} transactions')),
      );
    }
  }

  Widget _buildRecentTransactions(BuildContext context, ThemeData theme) {
    return BlocBuilder<TransactionsCubit, List<Transaction>>(
      builder: (context, transactions) {
        if (transactions.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.receipt_long,
                        size: 48, color: Colors.grey.shade400),
                    const SizedBox(height: 8),
                    const Text('No transactions yet',
                        style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 4),
                    const Text('Tap "Sync Transactions" to import.',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ),
            ),
          );
        }

        final recent = transactions.toList()
          ..sort((a, b) => b.date.compareTo(a.date));
        final display = recent.take(10).toList();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Recent Transactions',
                      style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text('${transactions.length} total',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
              ...display.map((t) => Card(
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        t.amount > 0
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        color: t.amount > 0
                            ? Colors.green.shade600
                            : Colors.red.shade600,
                        size: 20,
                      ),
                      title: Text(t.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(DateFormat('M/d/yy').format(t.date)),
                      trailing: Text(
                        _currencyFormat.format(t.amount),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: t.amount > 0
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                        ),
                      ),
                    ),
                  )),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
