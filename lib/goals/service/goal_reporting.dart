import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/goals/model/tag.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';

Set<String> subtreeTagIdsForGoal(
  Goal goal,
  List<Goal> allGoals,
  List<GoalTag> allTags,
) {
  final collected = <String>{...goal.tagIds};
  final queue = <String>[goal.id];
  final seen = <String>{goal.id};
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final g in allGoals) {
      if (g.parentId == current && seen.add(g.id)) {
        collected.addAll(g.tagIds);
        queue.add(g.id);
      }
    }
  }

  final expanded = <String>{};
  for (final id in collected) {
    expanded.addAll(tagSubtreeIds(id, allTags));
  }
  collected.addAll(expanded);
  return collected;
}

bool _inSpan(DateTime date, Goal goal) =>
    !date.isBefore(goal.startDate) && !date.isAfter(goal.deadline);

double timeActualForGoal({
  required Goal goal,
  required List<PlannerEvent> events,
  required List<Task> tasks,
  required List<ReportedEntry> entries,
}) {
  final tags = goal.tagIds.toSet();
  var minutes = 0.0;
  for (final e in events) {
    if (tags.isEmpty || e.tagIds.any(tags.contains)) {
      if (_inSpan(e.start, goal)) {
        final reported = e.reportedDuration;
        if (reported != null) {
          minutes += reported.inMinutes;
        } else if (e.hasReported) {
          minutes += e.plannedDuration.inMinutes;
        }
      }
    }
  }
  for (final t in tasks) {
    if (tags.isEmpty || t.tagIds.any(tags.contains)) {
      final d = t.reportedDuration;
      if (d != null && t.actualStart != null && _inSpan(t.actualStart!, goal)) {
        minutes += d.inMinutes;
      }
    }
  }
  for (final r in entries) {
    if (r.start.isBefore(goal.startDate) || r.start.isAfter(goal.deadline)) {
      continue;
    }
    if (tags.isEmpty || r.tagIds.any(tags.contains)) {
      final mins = r.minutesAtPlace > 0
          ? r.minutesAtPlace
          : r.end.difference(r.start).inMinutes;
      minutes += mins;
    }
  }
  return minutes;
}

double financialActualForGoal({
  required Goal goal,
  required List<Expense> expenses,
  required List<Transaction> transactions,
  List<GoalTag>? allTags,
}) {
  final tags = goal.tagIds.toSet();
  var categories = <String>{};
  if (allTags != null) {
    for (final id in goal.tagIds) {
      try {
        final tag = allTags.firstWhere((t) => t.id == id);
        final cat = tag.category;
        if (cat != null && cat.isNotEmpty) categories.add(cat.toLowerCase());
      } catch (_) {}
    }
  }
  var total = 0.0;
  for (final e in expenses) {
    if (!_inSpan(e.date, goal)) continue;
    final tagged = e.tagIds.any(tags.contains);
    final categorized = e.category != null &&
        categories.contains(e.category!.toLowerCase());
    if (tags.isEmpty || tagged || categorized) {
      total += e.amount.abs();
    }
  }
  for (final t in transactions) {
    if (!_inSpan(t.date, goal)) continue;
    if (tags.isEmpty || t.tagIds.any(tags.contains)) {
      total += t.amount.abs();
    }
  }
  return total;
}
