import 'package:a_fish_in_sea/common/persistence/migration.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';

class GoalCubit extends RevertableHydratedCubit<List<Goal>> {
  GoalCubit() : super(const []);

  Goal? byId(String id) {
    try {
      return state.firstWhere((g) => g.id == id);
    } catch (_) {
      return null;
    }
  }

  List<Goal> childrenOf(String? parentId) =>
      state.where((g) => g.parentId == parentId).toList();

  List<Goal> get roots => childrenOf(null);

  String? validateParent(Goal draft, String? parentId) {
    if (parentId == null) return null;
    if (parentId == draft.id) return 'A goal cannot be its own parent.';
    final parent = byId(parentId);
    if (parent == null) return 'Parent goal not found.';
    if (!canNest(parent.type, draft.type)) {
      return 'A ${parent.type.name} goal can only contain ${parent.type.name} sub-goals.';
    }
    if (!spanFitsParent(
      childStart: draft.startDate,
      childDeadline: draft.deadline,
      parentStart: parent.startDate,
      parentDeadline: parent.deadline,
    )) {
      return 'Sub-goal time must sit inside the parent goal time.';
    }
    var current = parent.parentId;
    while (current != null) {
      if (current == draft.id) return 'That parent would create a cycle.';
      current = byId(current)?.parentId;
    }
    return null;
  }

  String? addGoal(Goal goal) {
    final error = validateParent(goal, goal.parentId);
    if (error != null) return error;
    emitChange([...state, goal]);
    return null;
  }

  String? updateGoal(Goal updated) {
    final error = validateParent(updated, updated.parentId);
    if (error != null) return error;
    emitChange(state.map((g) => g.id == updated.id ? updated : g).toList());
    return null;
  }

  void deleteGoal(String id) {
    final doomed = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final g in state) {
        if (g.parentId != null &&
            doomed.contains(g.parentId) &&
            doomed.add(g.id)) {
          grew = true;
        }
      }
    }
    emitChange(state.where((g) => !doomed.contains(g.id)).toList());
  }

  void toggleDone(String id) {
    final goal = byId(id);
    if (goal == null) return;
    final now = DateTime.now();
    final updated = goal.done
        ? goal.copyWith(done: false, clearCompletedAt: true)
        : goal.copyWith(done: true, completedAt: now, failed: false);
    emitChange(state.map((g) => g.id == id ? updated : g).toList());
  }

  void setFailed(String id, bool failed) {
    final goal = byId(id);
    if (goal == null) return;
    final updated = failed
        ? goal.copyWith(done: false, clearCompletedAt: true, failed: true)
        : goal.copyWith(failed: false);
    emitChange(state.map((g) => g.id == id ? updated : g).toList());
  }

  void detachTag(String tagId) {
    var changed = false;
    final next = [
      for (final g in state)
        if (g.tagIds.contains(tagId))
          () {
            changed = true;
            return g.copyWith(
                tagIds: g.tagIds.where((t) => t != tagId).toList());
          }()
        else
          g
    ];
    if (changed) emitChange(next);
  }

  void importBudgets(List<Budget> budgets) {
    if (!Migration.removeAfter('2026-09-10')) return;
    final existing = state.map((g) => g.id).toSet();
    final imported = [
      for (final b in budgets)
        Goal.fromBudget(b)
    ].where((g) => !existing.contains(g.id)).toList();
    if (imported.isNotEmpty) emitChange([...state, ...imported]);
  }

  @override
  List<Goal>? fromJson(Map<String, dynamic> json) {
    final list = json['goals'] as List<dynamic>?;
    if (list != null) {
      final out = <Goal>[];
      for (final item in list) {
        try {
          out.add(Goal.fromJson(Map<String, dynamic>.from(item as Map)));
        } catch (_) {}
      }
      return out;
    }
    if (Migration.removeAfter('2026-09-10')) {
      final legacy = json['budgets'] as List<dynamic>?;
      if (legacy != null) {
        final out = <Goal>[];
        for (final item in legacy) {
          try {
            out.add(Goal.fromBudget(Budget.fromJson(
                Map<String, dynamic>.from(item as Map))));
          } catch (_) {}
        }
        return out;
      }
    }
    return null;
  }

  @override
  Map<String, dynamic> toJson(List<Goal> state) =>
      {'goals': state.map((g) => g.toJson()).toList()};
}
