import '../../common/time/local_date.dart';
import '../model/node.dart';

/// Builds a fresh goal copy while retaining its plan and remapping parents.
/// Purchase history belongs to the original goal, including on descendants.
Node copySubtreeNode(
  Node n, {
  required String sourceId,
  required Map<String, String> remap,
  required DateTime at,
  String? attachToParentId,
}) => Node(
  id: remap[n.id]!,
  title: n.id == sourceId ? '${n.title} (copy)' : n.title,
  notes: n.notes,
  parentIds: [
    for (final p in n.parentIds) remap[p] ?? p,
    if (n.id == sourceId && attachToParentId != null) attachToParentId,
  ],
  status: NodeStatus.open,
  createdAt: at,
  isUnbounded: n.isUnbounded,
  isFavorite: n.isFavorite,
  schedule: n.schedule,
  money: n.money?.copyWith(
    status: MoneyStatus.projected,
    clearActual: true,
    linkedTransactionIds: const [],
  ),
  effort: n.effort,
  // A copy is a fresh goal: same deck and target, but the review
  // count starts over (like money actuals, which are cleared too).
  anki: n.anki?.copyWith(clearReviewsActual: true, clearLastSyncedAt: true),
  recurrence: n.recurrence,
  auto: n.auto,
  extraMetrics: n.extraMetrics,
  classFacet: n.classFacet,
  classNodeId: n.classNodeId,
  rule: n.rule,
  instanceOfId: n.instanceOfId == null
      ? null
      : (remap[n.instanceOfId] ?? n.instanceOfId),
  overriddenFields: Set.of(n.overriddenFields),
  sourceEventId: null,
  calendarEventId: null,
  feedId: n.feedId,
  classId: n.classId,
  classLabel: n.classLabel,
  assignees: n.assignees,
);

/// Result of [planBreakdown]: one slice per child step to create.
class BreakdownSlice {
  final String title;
  final DateTime? due;
  final double? targetAmount;
  final int? targetMinutes;

  const BreakdownSlice({
    required this.title,
    this.due,
    this.targetAmount,
    this.targetMinutes,
  });
}

/// Plan N ordered step children for [parent].
///
/// - Dates spread evenly across the parent window
///   ([ScheduleFacet.start]..[ScheduleFacet.due]/end). When the parent has
///   no end date the window defaults to [now]..[now] + [count] days, so the
///   bottom of a big goal tree always lands on day-to-day granularity.
/// - Money splits to the cent (last slice takes the rounding remainder).
/// - Effort splits whole minutes (first slices take the remainder).
///
/// Pure: no ids minted, no clock reads except the passed [now].
List<BreakdownSlice> planBreakdown({
  required Node parent,
  required int count,
  required DateTime now,
  String stepPrefix = 'Step',
  bool spreadDates = true,
  bool splitMoney = true,
  bool splitEffort = true,
}) {
  final n = count.clamp(2, 30);
  final dues = _spreadDues(
    parent: parent,
    count: n,
    now: now,
    spreadDates: spreadDates,
  );
  final amounts = _splitMoney(
    parent: parent,
    count: n,
    split: splitMoney,
  );
  final minutes = _splitEffort(
    parent: parent,
    count: n,
    split: splitEffort,
  );
  return [
    for (var i = 0; i < n; i++)
      BreakdownSlice(
        title: '$stepPrefix ${i + 1} of $n',
        due: dues?[i],
        targetAmount: amounts?[i],
        targetMinutes: minutes?[i],
      ),
  ];
}

List<DateTime>? _spreadDues({
  required Node parent,
  required int count,
  required DateTime now,
  required bool spreadDates,
}) {
  if (!spreadDates) return null;
  final schedule = parent.schedule;
  DateTime? end = schedule?.due ?? schedule?.end;
  DateTime start = schedule?.start ?? now;
  end ??= shiftByCalendarDays(start, count);
  if (start.isAfter(end)) start = end;
  final spanMs = end.millisecondsSinceEpoch - start.millisecondsSinceEpoch;
  return [
    for (var i = 0; i < count; i++)
      DateTime.fromMillisecondsSinceEpoch(
        start.millisecondsSinceEpoch + (spanMs * (i + 1) ~/ count),
      ),
  ];
}

List<double>? _splitMoney({
  required Node parent,
  required int count,
  required bool split,
}) {
  final target = parent.money?.effectiveTarget;
  if (!split || target == null || target <= 0) return null;
  final cents = (target * 100).round();
  final each = cents ~/ count;
  final remainder = cents % count;
  return [
    for (var i = 0; i < count; i++)
      ((each + (i == count - 1 ? remainder : 0)) / 100),
  ];
}

List<int>? _splitEffort({
  required Node parent,
  required int count,
  required bool split,
}) {
  final target = parent.effort?.targetMinutes;
  if (!split || target == null || target <= 0) return null;
  final each = target ~/ count;
  final remainder = target % count;
  return [
    for (var i = 0; i < count; i++) each + (i < remainder ? 1 : 0),
  ];
}

/// All descendant ids of [rootId] (cycle-safe). Shared DAG children are
/// listed once; traversal never leaves the closure.
Set<String> subtreeIds(String rootId, List<Node> all) {
  final byParent = <String, List<Node>>{};
  for (final n in all) {
    for (final p in n.parentIds) {
      byParent.putIfAbsent(p, () => []).add(n);
    }
  }
  final out = <String>{};
  final queue = <String>[rootId];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final kid in byParent[current] ?? const <Node>[]) {
      if (out.add(kid.id)) queue.add(kid.id);
    }
  }
  return out;
}

/// Case-insensitive title/notes match.
bool matchesQuery(Node node, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return node.title.toLowerCase().contains(q) ||
      (node.notes?.toLowerCase().contains(q) ?? false);
}

/// Ids to keep visible for [query]: matches plus their ancestors (context)
/// plus their descendants (so an expanded match shows its subtree).
Set<String> filterTreeIds(List<Node> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return {for (final n in all) n.id};
  final byId = {for (final n in all) n.id: n};
  final byParent = <String, List<Node>>{};
  for (final n in all) {
    for (final p in n.parentIds) {
      byParent.putIfAbsent(p, () => []).add(n);
    }
  }
  final keep = <String>{};
  final walkedUp = <String>{};
  final walkedDown = <String>{};
  for (final n in all) {
    if (!matchesQuery(n, q)) continue;
    keep.add(n.id);
    // Ancestors: context path to the root (BFS over parent links).
    final ancestors = <String>[...n.parentIds];
    while (ancestors.isNotEmpty) {
      final current = ancestors.removeLast();
      keep.add(current);
      if (!walkedUp.add(current)) continue;
      final parent = byId[current];
      if (parent != null) ancestors.addAll(parent.parentIds);
    }
    // Descendants: the matching subtree stays visible.
    final queue = <String>[n.id];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!walkedDown.add(current)) continue;
      for (final kid in byParent[current] ?? const <Node>[]) {
        keep.add(kid.id);
        queue.add(kid.id);
      }
    }
  }
  return keep;
}
