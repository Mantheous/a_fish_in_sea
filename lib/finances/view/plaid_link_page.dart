import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/finances/view/bank_connection_card.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Bank connection page — connect via Plaid Link or sandbox shortcuts.
class PlaidLinkPage extends StatefulWidget {
  const PlaidLinkPage({super.key, this.showBottomNav = true});

  final bool showBottomNav;

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
      bottomNavigationBar:
          widget.showBottomNav ? const NavBar() : null,
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
                            ConnectionStatusChip(state: plaidState),
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
                  child: BankConnectionCard(state: plaidState),
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
                          onPressed: () => syncPlaidTransactions(context),
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
