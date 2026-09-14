import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';

/// One-time adoption from the retired Goal/Task/Budget/Expense/Tag/Rule
/// cubits into [NodeCubit].
///
/// Reads the legacy Hydrated storage boxes directly (keyed by the old
/// cubits' runtimeType names) and maps each item through the NodeCubit
/// importers. Safe to run repeatedly: importers dedupe by id, and
/// children whose parents are missing fall back to roots instead of
/// being dropped. Legacy boxes are left untouched — old data is never
/// wiped, just superseded.
class NodeLegacyMigration {
  const NodeLegacyMigration._();

  static const _boxes = [
    'GoalCubit',
    'TaskCubit',
    'TagCubit',
    'ExpenseCubit',
    'BudgetCubit',
    'RecurringRulesCubit',
  ];

  static Future<dynamic> _readBox(String key) async {
    try {
      return await Future.value(HydratedBloc.storage.read(key));
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _items(dynamic box, String key) {
    if (box is! Map) return const [];
    final list = box[key];
    if (list is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in list) {
      if (item is Map) {
        try {
          out.add(Map<String, dynamic>.from(item));
        } catch (_) {}
      }
    }
    return out;
  }

  /// True when any legacy box still holds items.
  static Future<bool> hasLegacy() async {
    for (final box in _boxes) {
      final raw = await _readBox(box);
      if (raw is Map &&
          raw.values.any((v) => v is List && v.isNotEmpty)) {
        return true;
      }
    }
    return false;
  }

  static Future<({int nodes, int txns})> importAll(
    NodeCubit nodes,
    TransactionsCubit transactions,
  ) async {
    var made = 0;

    // Goals: roots first so parent links validate; orphans fall back
    // to roots rather than being dropped.
    final goalBox = await _readBox('GoalCubit');
    final goals = <Goal>[];
    for (final json in _items(goalBox, 'goals')) {
      try {
        goals.add(Goal.fromJson(json));
      } catch (_) {}
    }
    goals.sort((a, b) => a.parentId == null
        ? (b.parentId == null ? 0 : -1)
        : (b.parentId == null ? 1 : 0));
    for (final goal in goals) {
      final before = nodes.state.length;
      final id = nodes.importGoal(goal);
      if (nodes.state.length > before) {
        made++;
      } else if (nodes.byId(id) == null) {
        // Parent missing (e.g. partial box): adopt as root.
        final fallback = Goal(
          id: goal.id,
          title: goal.title,
          type: goal.type,
          startDate: goal.startDate,
          deadline: goal.deadline,
        );
        nodes.importGoal(fallback);
        made++;
      }
    }

    final taskBox = await _readBox('TaskCubit');
    for (final json in _items(taskBox, 'tasks')) {
      try {
        final before = nodes.state.length;
        nodes.importTask(Task.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }

    final budgetBox = await _readBox('BudgetCubit');
    for (final json in _items(budgetBox, 'budgets')) {
      try {
        final before = nodes.state.length;
        nodes.importBudget(Budget.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }

    final expenseBox = await _readBox('ExpenseCubit');
    final expenseJsons = _items(expenseBox, 'expenses');
    expenseJsons.sort((a, b) =>
        (a['parentExpenseId'] == null ? 0 : 1)
            .compareTo((b['parentExpenseId'] == null ? 0 : 1)));
    for (final json in expenseJsons) {
      try {
        final before = nodes.state.length;
        nodes.importExpense(Expense.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }

    final ruleBox = await _readBox('RecurringRulesCubit');
    for (final json in _items(ruleBox, 'rules')) {
      try {
        final before = nodes.state.length;
        nodes.importRecurringRule(RecurringRule.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }

    // Transactions: point expense assignments at the matching nodes.
    // Legacy expense links are kept — both mechanisms coexist.
    var linked = 0;
    for (final t in transactions.state) {
      final expenseId = t.assignedExpenseId;
      if (expenseId == null || t.isAssignedToNode) continue;
      final nodeId = 'node:$expenseId';
      if (nodes.byId(nodeId) != null) {
        transactions.assignNode(t.id, nodeId);
        linked++;
      }
    }
    // Also pick up transactions stored with assignments that the live
    // cubit hasn't hydrated yet — nothing to do; they load with the box.

    return (nodes: made, txns: linked);
  }

  /// Test helper: import from in-memory payloads without storage.
  static int importPayloads(
    NodeCubit nodes, {
    List<Map<String, dynamic>> goals = const [],
    List<Map<String, dynamic>> tasks = const [],
    List<Map<String, dynamic>> budgets = const [],
    List<Map<String, dynamic>> expenses = const [],
    List<Map<String, dynamic>> rules = const [],
  }) {
    var made = 0;
    for (final json in goals) {
      try {
        final before = nodes.state.length;
        nodes.importGoal(Goal.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }
    for (final json in tasks) {
      try {
        final before = nodes.state.length;
        nodes.importTask(Task.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }
    for (final json in budgets) {
      try {
        final before = nodes.state.length;
        nodes.importBudget(Budget.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }
    for (final json in expenses) {
      try {
        final before = nodes.state.length;
        nodes.importExpense(Expense.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }
    for (final json in rules) {
      try {
        final before = nodes.state.length;
        nodes.importRecurringRule(RecurringRule.fromJson(json));
        if (nodes.state.length > before) made++;
      } catch (_) {}
    }
    return made;
  }
}
