import '../model/node.dart';
import 'node_progress.dart';

/// One row in the "Add parent" picker.
class ParentCandidate {
  const ParentCandidate({required this.node, this.occurrences = 0});

  /// The node stored in `parentIds`. Always a legal parent: never a
  /// generated instance (instances cannot have children of their own).
  final Node node;

  /// Generated instances collapsed into this row. 0 when the goal does not
  /// repeat.
  final int occurrences;
}

/// Goals the user can parent something to, most recently touched first.
///
/// A repeating goal shows once, as its template. Generated instances
/// (`instanceOfId != null`) are never candidates — the relation rules refuse
/// them as parents — so listing them was showing the same title once per
/// occurrence and failing validation when one was picked.
///
/// Goals sort by last activity (created, completed, tracked) so the picker
/// opens on what the user just added or worked on instead of an
/// alphabetical wall.
///
/// [excludeId] and its descendants are omitted so the pick can't create a
/// cycle. Pass every node, not just goal nodes: the cycle check walks the
/// real graph, including homework shadows.
List<ParentCandidate> parentCandidates(List<Node> all, {String? excludeId}) {
  final goals = goalNodes(all);

  // Instances per template, plus the freshest activity in the series: a
  // habit completed today should float its template up even though the
  // template itself was created months ago.
  final occurrences = <String, int>{};
  final seriesActivity = <String, DateTime>{};
  for (final n in goals) {
    final templateId = n.instanceOfId;
    if (templateId == null) continue;
    occurrences[templateId] = (occurrences[templateId] ?? 0) + 1;
    final at = nodeLastActivity(n);
    final prior = seriesActivity[templateId];
    if (prior == null || at.isAfter(prior)) {
      seriesActivity[templateId] = at;
    }
  }

  final excluded = <String>{
    if (excludeId != null) excludeId,
    if (excludeId != null) ...descendantIds(excludeId, all),
  };

  final bySeries = <String, ParentCandidate>{};
  final rows = <ParentCandidate>[];
  for (final n in all) {
    if (n.instanceOfId != null) continue;
    if (excluded.contains(n.id)) continue;
    // The picker lists goal nodes. A series whose template is not a goal
    // node still earns a row when its instances are: that template is what
    // the duplicates belonged to, and it is the only legal parent.
    if (!isGoalNode(n) && !occurrences.containsKey(n.id)) continue;
    final candidate = ParentCandidate(
      node: n,
      occurrences: occurrences[n.id] ?? 0,
    );
    // Two templates left over from an older import of the same calendar
    // series collapse into one row; the one that owns the occurrences wins.
    final seriesKey = n.calendarLink?.seriesKey;
    if (seriesKey == null) {
      rows.add(candidate);
      continue;
    }
    final prior = bySeries[seriesKey];
    if (prior == null || candidate.occurrences > prior.occurrences) {
      bySeries[seriesKey] = candidate;
    }
  }
  rows.addAll(bySeries.values);

  rows.sort((a, b) {
    final aAt = nodeLastActivity(a.node);
    final bAt = nodeLastActivity(b.node);
    final aSeries = seriesActivity[a.node.id];
    final bSeries = seriesActivity[b.node.id];
    final aLast = aSeries != null && aSeries.isAfter(aAt) ? aSeries : aAt;
    final bLast = bSeries != null && bSeries.isAfter(bAt) ? bSeries : bAt;
    final byRecency = bLast.compareTo(aLast);
    if (byRecency != 0) return byRecency;
    return a.node.title.toLowerCase().compareTo(b.node.title.toLowerCase());
  });
  return rows;
}

/// When the node was last added or materially touched. There is no stored
/// `updatedAt`, so this is the freshest timestamp the node carries:
/// creation, completion, or a tracked run of work.
DateTime nodeLastActivity(Node n) {
  var at = n.createdAt;
  void bump(DateTime? value) {
    if (value != null && value.isAfter(at)) at = value;
  }

  bump(n.completedAt);
  bump(n.actualStart);
  bump(n.actualEnd);
  bump(n.timerStartedAt);
  for (final session in n.sessions) {
    bump(session.end);
  }
  return at;
}
