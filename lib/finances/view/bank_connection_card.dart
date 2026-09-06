import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/finances/service/plaid_link_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Colored chip summarizing the current Plaid connection status.
class ConnectionStatusChip extends StatelessWidget {
  const ConnectionStatusChip({super.key, required this.state});

  final PlaidState state;

  @override
  Widget build(BuildContext context) {
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
}

/// Card with the bank connection actions: connect, retry, disconnect.
class BankConnectionCard extends StatelessWidget {
  const BankConnectionCard({super.key, required this.state});

  final PlaidState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
}

/// Fetches transactions from Plaid, imports them into [TransactionsCubit],
/// and refreshes the balance.
Future<void> syncPlaidTransactions(BuildContext context) async {
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
