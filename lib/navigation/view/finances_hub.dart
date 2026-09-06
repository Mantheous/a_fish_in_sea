import 'package:flutter/material.dart';

import '../../common/undo/undo_bar.dart';
import '../../finances/view/plaid_link_page.dart';
import '../../finances/view/rules_and_budgets_page.dart';
import '../../finances/view/waterfall_ledger_page.dart';
import '../../navigation/view/navigation_bar.dart';

class FinancesHubPage extends StatelessWidget {
  const FinancesHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Finances'),
          actions: const [UndoRedoActions()],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Waterfall'),
              Tab(text: 'Rules & Budgets'),
              Tab(text: 'Bank'),
            ],
          ),
        ),
        bottomNavigationBar: const NavBar(),
        body: const TabBarView(
          children: [
            WaterfallLedgerPage(showBottomNav: false),
            RulesAndBudgetsPage(showBottomNav: false),
            PlaidLinkPage(showBottomNav: false),
          ],
        ),
      ),
    );
  }
}
