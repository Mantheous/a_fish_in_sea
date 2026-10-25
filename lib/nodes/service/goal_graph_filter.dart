import '../../common/time/local_date.dart';
import '../model/node.dart';
import 'node_tree_ops.dart';

/// Date window applied to goals in the goal graph.
///
/// "Date" means the goal's own schedule (due first, then its calendar
/// block), not the dates of its descendants: a parent goal with an
/// overdue child is not itself overdue.
enum GoalDateFilter { any, overdue, today, thisWeek, thisMonth, noDate }

/// What kind of goal to keep. Tasks are concrete work: an explicit task
/// flag, or a plain scheduled leaf with no facet; the rest mirror the
/// facets that make a node a goal.
enum GoalKindFilter {
  any,
  task,
  money,
  time,
  repeating,
  automated,
  homework,
  anki,
  unbounded,
}

/// A single filter selection for the goal graph.
///
/// Immutable and value-equal so it can live in page state and be compared
/// after a filter sheet returns. [topicRootId] scopes the graph to one
/// top-level branch (the app has no tag field: branches are topics).
class GoalGraphFilter {
  final GoalDateFilter date;
  final GoalKindFilter kind;
  final NodeStatus? status;
  final bool starredOnly;
  final String? topicRootId;

  const GoalGraphFilter({
    this.date = GoalDateFilter.any,
    this.kind = GoalKindFilter.any,
    this.status,
    this.starredOnly = false,
    this.topicRootId,
  });

  bool get isActive =>
      date != GoalDateFilter.any ||
      kind != GoalKindFilter.any ||
      status != null ||
      starredOnly ||
      topicRootId != null;

  /// Number of active conditions, for the filter button badge.
  int get activeCount =>
      (date != GoalDateFilter.any ? 1 : 0) +
      (kind != GoalKindFilter.any ? 1 : 0) +
      (status != null ? 1 : 0) +
      (starredOnly ? 1 : 0) +
      (topicRootId != null ? 1 : 0);

  GoalGraphFilter copyWith({
    GoalDateFilter? date,
    GoalKindFilter? kind,
    NodeStatus? status,
    bool clearStatus = false,
    bool? starredOnly,
    String? topicRootId,
    bool clearTopicRoot = false,
  }) => GoalGraphFilter(
    date: date ?? this.date,
    kind: kind ?? this.kind,
    status: clearStatus ? null : (status ?? this.status),
    starredOnly: starredOnly ?? this.starredOnly,
    topicRootId: clearTopicRoot ? null : (topicRootId ?? this.topicRootId),
  );

  GoalGraphFilter withoutDate() => copyWith(date: GoalDateFilter.any);

  GoalGraphFilter withoutKind() => copyWith(kind: GoalKindFilter.any);

  GoalGraphFilter withoutStatus() => copyWith(clearStatus: true);

  GoalGraphFilter withoutStarred() => copyWith(starredOnly: false);

  GoalGraphFilter withoutTopic() => copyWith(clearTopicRoot: true);

  /// True when [node] satisfies every selected condition.
  bool matches(
    Node node,
    DateTime now, {
    Map<String, Set<String>>? ancestorsById,
    int firstDayOfWeek = 1,
  }) {
    if (starredOnly && !node.isFavorite) return false;
    if (status != null && node.status != status) return false;
    if (!_matchesKind(node)) return false;
    if (!_matchesDate(node, now, firstDayOfWeek: firstDayOfWeek)) return false;
    final topic = topicRootId;
    if (topic != null) {
      final ancestors = ancestorsById?[node.id] ?? const <String>{};
      if (!ancestors.contains(topic)) return false;
    }
    return true;
  }

  bool _matchesKind(Node node) => switch (kind) {
    GoalKindFilter.any => true,
    GoalKindFilter.task => node.isTask,
    GoalKindFilter.money => node.money != null,
    GoalKindFilter.time => node.effort != null,
    GoalKindFilter.repeating => node.isTemplate,
    // Repeating goals generate their own occurrences, so the automated
    // bucket includes them alongside goals measured from data.
    GoalKindFilter.automated => node.isAutomatedGoal || node.isTemplate,
    GoalKindFilter.homework =>
      node.isHomework ||
      node.isClassNode ||
      (node.auto?.homeworkOnly ?? false),
    GoalKindFilter.anki => node.anki != null,
    GoalKindFilter.unbounded => node.isUnbounded,
  };

  bool _matchesDate(Node node, DateTime now, {int firstDayOfWeek = 1}) {
    final day = _dayOf(node);
    final today = localDay(now);
    switch (date) {
      case GoalDateFilter.any:
        return true;
      case GoalDateFilter.overdue:
        return node.isOverdueAt(now);
      case GoalDateFilter.today:
        return day != null && isSameLocalDay(day, today);
      case GoalDateFilter.thisWeek:
        if (day == null) return false;
        final startOffset = (today.weekday - firstDayOfWeek + 7) % 7;
        final weekStart = shiftLocalDay(today, -startOffset);
        final weekEnd = shiftLocalDay(weekStart, 7);
        final dayOnly = localDay(day);
        return !dayOnly.isBefore(weekStart) && dayOnly.isBefore(weekEnd);
      case GoalDateFilter.thisMonth:
        final dayOnly = day == null ? null : localDay(day);
        return dayOnly != null &&
            dayOnly.year == today.year &&
            dayOnly.month == today.month;
      case GoalDateFilter.noDate:
        return day == null;
    }
  }

  static DateTime? _dayOf(Node node) {
    final schedule = node.schedule;
    return schedule?.due ?? schedule?.start ?? schedule?.end;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GoalGraphFilter &&
          date == other.date &&
          kind == other.kind &&
          status == other.status &&
          starredOnly == other.starredOnly &&
          topicRootId == other.topicRootId;

  @override
  int get hashCode => Object.hash(date, kind, status, starredOnly, topicRootId);

  @override
  String toString() =>
      'GoalGraphFilter(date: ${date.name}, kind: ${kind.name}, '
      'status: ${status?.name}, starredOnly: $starredOnly, '
      'topicRootId: $topicRootId)';
}

/// The graph projection produced by a [GoalGraphFilter] plus search.
///
/// [matchedIds] are goals that pass every condition and get a full card.
/// [contextIds] are filtered-out ancestors kept as compact "collapsed"
/// nodes so the path from a match back to its branch stays visible.
/// [visibleIds] is their union: exactly what the graph should lay out.
class GoalGraphFilterResult {
  final Set<String> visibleIds;
  final Set<String> matchedIds;
  final Set<String> contextIds;
  final bool active;
  final bool filterActive;

  const GoalGraphFilterResult({
    required this.visibleIds,
    required this.matchedIds,
    required this.contextIds,
    required this.active,
    required this.filterActive,
  });

  static const empty = GoalGraphFilterResult(
    visibleIds: {},
    matchedIds: {},
    contextIds: {},
    active: false,
    filterActive: false,
  );

  bool get isEmpty => visibleIds.isEmpty;
}

/// Projects [nodes] through [filter] and [query].
///
/// Search alone keeps its historical shape ([filterTreeIds]: matches,
/// ancestors, and descendants). A filter is graph-shaped: only matches
/// plus the ancestor chain leading to them. Those ancestors are returned
/// as [GoalGraphFilterResult.contextIds] so the view can collapse them
/// instead of dropping the relationship.
GoalGraphFilterResult filterGoalGraph({
  required List<Node> nodes,
  required DateTime now,
  GoalGraphFilter filter = const GoalGraphFilter(),
  String query = '',
}) {
  if (nodes.isEmpty) return GoalGraphFilterResult.empty;
  final q = query.trim();
  final byId = {for (final n in nodes) n.id: n};
  final ancestorsById = filter.topicRootId == null
      ? const <String, Set<String>>{}
      : _ancestorsByNode(nodes);

  final matched = <String>{};
  for (final node in nodes) {
    if (!filter.matches(node, now, ancestorsById: ancestorsById)) continue;
    if (q.isNotEmpty && !matchesQuery(node, q)) continue;
    matched.add(node.id);
  }

  if (!filter.isActive) {
    if (q.isEmpty) {
      final all = {for (final n in nodes) n.id};
      return GoalGraphFilterResult(
        visibleIds: all,
        matchedIds: all,
        contextIds: const {},
        active: false,
        filterActive: false,
      );
    }
    // Search-only: keep the old matches + ancestors + descendants shape.
    return GoalGraphFilterResult(
      visibleIds: filterTreeIds(nodes, q),
      matchedIds: matched,
      contextIds: const {},
      active: true,
      filterActive: false,
    );
  }

  final context = <String>{};
  for (final id in matched) {
    final start = byId[id];
    if (start == null) continue;
    final pending = <String>[...start.parentIds];
    while (pending.isNotEmpty) {
      final parentId = pending.removeLast();
      final parent = byId[parentId];
      if (parent == null || matched.contains(parentId)) continue;
      if (context.add(parentId)) pending.addAll(parent.parentIds);
    }
  }

  final visible = <String>{...matched, ...context};
  return GoalGraphFilterResult(
    visibleIds: visible,
    matchedIds: matched,
    contextIds: context,
    active: true,
    filterActive: true,
  );
}

/// Topic options: goal branches the user can scope the graph to.
///
/// A topic is any root or any goal with children — scoping to a leaf would
/// just show that one goal, which search already does. The app has no tag
/// field, so these are the natural "topics" of the goal tree.
List<Node> goalTopicOptions(List<Node> nodes) {
  final ids = {for (final n in nodes) n.id};
  final branches = <String>{};
  for (final node in nodes) {
    for (final parent in node.parentIds) {
      if (ids.contains(parent)) branches.add(parent);
    }
  }
  final options = nodes
      .where((n) => !n.parentIds.any(ids.contains) || branches.contains(n.id))
      .toList(growable: false);
  final result = options.isEmpty ? List<Node>.of(nodes) : options;
  result.sort(_compareTopics);
  return result;
}

int _compareTopics(Node a, Node b) {
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
}

/// Every ancestor of each node, including the node itself. A node with no
/// parent in [nodes] is its own root. Shared DAG children carry every
/// branch they hang from, so a topic filter keeps a goal that belongs to
/// the selected branch. Cycle-safe.
Map<String, Set<String>> _ancestorsByNode(List<Node> nodes) {
  final byId = {for (final n in nodes) n.id: n};
  final memo = <String, Set<String>>{};

  Set<String> ancestorsOf(String id, Set<String> visiting) {
    final cached = memo[id];
    if (cached != null) return cached;
    if (!visiting.add(id)) return <String>{id};
    final node = byId[id];
    if (node == null) {
      visiting.remove(id);
      return const <String>{};
    }
    final ancestors = <String>{id};
    for (final parent in node.parentIds.where(byId.containsKey)) {
      ancestors.addAll(ancestorsOf(parent, visiting));
    }
    visiting.remove(id);
    memo[id] = ancestors;
    return ancestors;
  }

  for (final node in nodes) {
    ancestorsOf(node.id, <String>{});
  }
  return memo;
}
