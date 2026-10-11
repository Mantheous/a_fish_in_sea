import 'package:a_fish_in_sea/nodes/model/node.dart';

/// A node's structural role.
///
/// The Project Time Management Ontology partitions its types with
/// `{disjoint, complete}` — every process is *either* general or specific,
/// every activity *either* simple or composite, and the partition is
/// checked rather than assumed. [roleOf] is that partition for nodes:
/// derived from the facets a node actually carries, so every node plays
/// exactly one role without anyone having to remember to set a type flag.
///
/// The role is a *view* of the facets, not stored state. Nothing is
/// persisted here, so this cannot break old data.
enum NodeRole {
  /// No facets at all: undated, unestimated. Valid by design — planning
  /// stays cheap until you commit to a shape.
  placeholder,

  /// A due date only: an obligation for the priority queue.
  obligation,

  /// A start/end block on the calendar.
  block,

  /// Carries a recurrence and generates dated instances. Dateless by
  /// design — [NodeRole.instance] carries the dates.
  template,

  /// Generated from a template ([Node.instanceOfId]). The dated,
  /// mutable realization of a prescription.
  instance,

  /// Evaluated by query at read time instead of storing children.
  derived,
}

/// The role [node] plays. Deterministic and total: precedence is
/// instance → template → derived → block → obligation → placeholder, so a
/// node with several facets resolves to the most structural one.
///
/// The order matters most for template vs instance: an instance can inherit
/// its template's recurrence facet, and `Node.isTemplate` is defined as
/// `recurrence != null && instanceOfId == null`, so the instance test has
/// to come first for the partition to be disjoint.
NodeRole roleOf(Node node) {
  if (node.instanceOfId != null) return NodeRole.instance;
  if (node.recurrence != null) return NodeRole.template;
  if (node.rule != null && node.rule!.kind != NodeRuleKind.none) {
    return NodeRole.derived;
  }
  if (node.hasCalendarBlock) return NodeRole.block;
  if (node.hasDue) return NodeRole.obligation;
  return NodeRole.placeholder;
}

/// The declared parent count for a role, or null when the role accepts
/// any number.
///
/// This is the multiplicity half of the partition. PTMO states its
/// whole/part relations with explicit multiplicities (a specific project
/// process is composed of 0..* project activities) so the constraint is
/// written down rather than discovered by whoever hits it first.
int? declaredParentCount(NodeRole role) {
  switch (role) {
    case NodeRole.instance:
      return 1;
    case NodeRole.placeholder:
    case NodeRole.obligation:
    case NodeRole.block:
    case NodeRole.template:
    case NodeRole.derived:
      return null;
  }
}

/// Role-level statement of which parents a role may have.
///
/// The DAG is deliberately permissive — a node may contribute to several
/// parents at once — so this is one hard rule rather than a whitelist:
/// an [NodeRole.instance] may not be a parent. Instances are generated
/// records owned by a template's horizon; children hanging off one would
/// be silently orphaned when the template's next roll recreates or deletes
/// it. Everything else may parent everything else.
bool canBeParentOf(NodeRole parent, NodeRole child) {
  if (parent == NodeRole.instance) return false;
  return true;
}

/// The structural relation rules for a node and the parents proposed for
/// it, as a user-facing error string or null.
///
/// These sit *on top of* `NodeCubit.validateParents`, which already
/// handles the purely graph-shaped failures (self-parenting, duplicates,
/// missing ids, cycles through [Node.parentIds]). What is added here is
/// everything that check cannot see, because it is expressed through a
/// different relation than `parentIds`:
///
///  1. **Instance ↔ template multiplicity.** An instance's structural
///     parent is the template that generated it — exactly one, and it must
///     be the template. Without this an instance can be reparented away
///     from its template, which strands it: [NodeCubit.instancesOf] and
///     the instance cascade in `deleteNode` both key off `instanceOfId`,
///     not `parentIds`, so the instance would survive deletion of its own
///     template.
///  2. **Cycles through `instanceOfId`.** `descendantIds` walks only
///     `parentIds`, so a template nested under one of its own instances
///     forms a cycle no reachability check can see. Rejected here.
///
/// Both rules only ever *refuse* states that were previously unvalidated;
/// neither rewrites anything.
String? validateNodeRelations({
  required Node draft,
  required List<Node> all,
  required List<String> parentIds,
}) {
  final byId = {for (final n in all) n.id: n};

  // 1. Instance ↔ template multiplicity.
  final templateId = draft.instanceOfId;
  if (templateId != null) {
    if (parentIds.length != 1) {
      return 'A generated instance must have exactly one parent: its '
          'template.';
    }
    if (parentIds.single != templateId) {
      return 'A generated instance must be parented to its template '
          '($templateId).';
    }
  }

  // 2. No template may sit under one of its own instances.
  if (draft.recurrence != null) {
    final instances = <String>{};
    final queue = <String>[draft.id];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final n in all) {
        if (n.instanceOfId == current && instances.add(n.id)) {
          queue.add(n.id);
        }
      }
    }
    for (final p in parentIds) {
      if (instances.contains(p)) {
        return 'That parent is generated by this template — nesting the '
            'template under it would create a cycle.';
      }
    }
  }

  // 3. Instances may not be parents at all (see [canBeParentOf]).
  for (final p in parentIds) {
    final parent = byId[p];
    if (parent == null) continue;
    if (!canBeParentOf(roleOf(parent), roleOf(draft))) {
      return 'Generated instances cannot have children of their own. '
          'Parent to the template (${parent.instanceOfId}) instead.';
    }
  }

  return null;
}

/// An unbounded (abstract) goal is an ongoing direction with no dates, no
/// targets, and no generated instances — concrete subgoals underneath carry
/// all of that. Returns a user-facing error string, or null when [draft]
/// is fine.
///
/// Always safe to run on every write: payloads written before the flag
/// existed load with `isUnbounded: false`, so stored data can never already
/// violate this.
String? validateUnbounded(Node draft) {
  if (!draft.isUnbounded) return null;
  if (draft.schedule != null) {
    return 'An unbounded goal cannot have a due date or calendar block. '
        'Remove the schedule first.';
  }
  if (draft.money != null) {
    return 'An unbounded goal cannot track money. '
        'Remove the money target first.';
  }
  if (draft.effort != null) {
    return 'An unbounded goal cannot have a time target. '
        'Remove the time target first.';
  }
  if (draft.recurrence != null) {
    return 'An unbounded goal cannot repeat. '
        'Turn off repeats first.';
  }
  final ruleKind = draft.rule?.kind;
  if (ruleKind != null && ruleKind != NodeRuleKind.none) {
    return 'An unbounded goal cannot be a derived goal. '
        'Remove the rule first.';
  }
  if (draft.instanceOfId != null) {
    return 'A generated instance cannot be unbounded — it carries the '
        'template\'s dates.';
  }
  return null;
}
