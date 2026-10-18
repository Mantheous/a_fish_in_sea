import 'package:equatable/equatable.dart';

import '../../nodes/model/node.dart';
import 'task_filter.dart';

/// What a matching rule does to a task row. [highlight] tints the row
/// (or the theme tint when no color is set); [hide] removes it from both
/// task lists.
enum TaskRuleEffect { highlight, hide }

/// One ordered display rule for the Tasks page: a [TaskFilter] selector
/// ("which tasks") plus the visual change for matching rows ("what
/// happens to them").
///
/// Priority is the list order, changed by dragging on the rules page:
/// hiding always wins over tinting, and the topmost matching highlight
/// rule wins the tint. Disabled rules are skipped entirely.
///
/// A highlight rule only ever matches open nodes (done rows never glow,
/// like the legacy week tint it replaces); a hide rule matches whatever
/// its selector matches, including done rows when the selector keeps
/// completed items.
class TaskRule extends Equatable {
  /// Stable id. The built-in week rule uses 'rule:week'; user-built rules
  /// use [newId].
  final String id;

  /// Off rules stay saved but change nothing — the quick toggle in the
  /// sheet and on the rules page.
  final bool enabled;

  /// Which tasks this rule applies to. The rule's display name is
  /// [TaskFilter.name] on the selector.
  final TaskFilter selector;

  final TaskRuleEffect effect;

  /// ARGB tint for [TaskRuleEffect.highlight]. Null means the theme
  /// default (the legacy week look). Ignored for hides.
  final int? colorValue;

  const TaskRule({
    required this.id,
    required this.selector,
    this.enabled = true,
    this.effect = TaskRuleEffect.highlight,
    this.colorValue,
  });

  /// Id for a user-built rule.
  static String newId() => 'rule:${DateTime.now().microsecondsSinceEpoch}';

  String get name => selector.name;

  bool get isHide => effect == TaskRuleEffect.hide;
  bool get isHighlight => effect == TaskRuleEffect.highlight;

  /// True when this enabled rule changes [node]: highlight rules need an
  /// open node, hide rules defer to the selector (done included when the
  /// selector keeps completed items). [plannedNodeIds] is forwarded to the
  /// selector's planned narrows (see [TaskFilter.matches]).
  bool matches(Node node, DateTime now, {Set<String>? plannedNodeIds}) {
    if (!enabled) return false;
    if (isHighlight && !node.isOpen) return false;
    return selector.matches(node, now, plannedNodeIds: plannedNodeIds);
  }

  TaskRule copyWith({
    String? id,
    bool? enabled,
    TaskFilter? selector,
    TaskRuleEffect? effect,
    int? colorValue,
    bool clearColor = false,
  }) =>
      TaskRule(
        id: id ?? this.id,
        enabled: enabled ?? this.enabled,
        selector: selector ?? this.selector,
        effect: effect ?? this.effect,
        colorValue: clearColor ? null : (colorValue ?? this.colorValue),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'enabled': enabled,
        'effect': effect.name,
        'colorValue': colorValue,
        'selector': selector.toJson(),
      };

  /// Null when [raw] is not a usable rule (missing id, wrong shape, or an
  /// unusable selector) so callers keep the valid entries and drop the
  /// garbage per-item. Unknown effects fall back to highlight — the
  /// non-destructive effect — and wrong-typed flags switch the rule off.
  static TaskRule? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    final id = map['id'];
    if (id is! String || id.isEmpty) return null;
    final selector = TaskFilter.tryParse(map['selector']);
    if (selector == null) return null;
    var effect = TaskRuleEffect.highlight;
    final rawEffect = map['effect'];
    if (rawEffect is String) {
      for (final e in TaskRuleEffect.values) {
        if (e.name == rawEffect) effect = e;
      }
    }
    int? color;
    final rawColor = map['colorValue'];
    if (rawColor is int && rawColor >= 0 && rawColor <= 0xFFFFFFFF) {
      color = rawColor;
    }
    return TaskRule(
      id: id.length > 64 ? id.substring(0, 64) : id,
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      selector: selector,
      effect: effect,
      colorValue: effect == TaskRuleEffect.highlight ? color : null,
    );
  }

  /// Maps the pre-rules single highlight onto an equivalent rule so
  /// existing prefs keep their window, color, and hide behavior.
  factory TaskRule.fromHighlight(TaskHighlight highlight) {
    final date = taskFilterDateFromHighlight(highlight.date);
    return TaskRule(
      id: 'rule:highlight',
      enabled: highlight.enabled,
      selector: TaskFilter(
        id: 'rule:highlight',
        name: taskHighlightDateLabel(highlight.date),
        date: date,
      ),
      effect: highlight.hideMatching
          ? TaskRuleEffect.hide
          : TaskRuleEffect.highlight,
      colorValue: highlight.hideMatching ? null : highlight.colorValue,
    );
  }

  @override
  List<Object?> get props => [id, enabled, selector, effect, colorValue];
}

/// The stock rules: one disabled week tint, the old "highlight due this
/// week" switch in rule form. Enabling it reproduces the legacy look.
List<TaskRule> defaultTaskRules() => const [
      TaskRule(
        id: 'rule:week',
        enabled: false,
        selector: TaskFilter(
          id: 'rule:week',
          name: 'Due this week',
          date: TaskFilterDate.thisWeek,
        ),
      ),
    ];

/// Outcome of running the ordered rules over one node.
class TaskRuleOutcome {
  /// Any enabled hide rule matched — the row leaves both lists.
  final bool hidden;

  /// Topmost matching highlight rule, or null when nothing tints the row
  /// (hidden rows never tint).
  final TaskRule? tint;

  const TaskRuleOutcome({required this.hidden, required this.tint});
}

/// Runs [rules] over [node] in list order: hiding always wins, the first
/// highlight match wins the tint, hidden rows never tint. [plannedNodeIds]
/// is forwarded to selector matching (see [TaskFilter.matches]).
TaskRuleOutcome evaluateTaskRules(
  List<TaskRule> rules,
  Node node,
  DateTime now, {
  Set<String>? plannedNodeIds,
}) {
  var hidden = false;
  TaskRule? tint;
  for (final rule in rules) {
    if (!rule.enabled) continue;
    if (rule.isHide) {
      if (rule.selector.matches(node, now, plannedNodeIds: plannedNodeIds)) {
        hidden = true;
      }
    } else if (tint == null &&
        node.isOpen &&
        rule.selector.matches(node, now, plannedNodeIds: plannedNodeIds)) {
      tint = rule;
    }
  }
  return TaskRuleOutcome(hidden: hidden, tint: hidden ? null : tint);
}

/// True when any enabled hide rule matches [node]. [plannedNodeIds] is
/// forwarded to selector matching (see [TaskFilter.matches]).
bool taskHiddenByRules(
  List<TaskRule> rules,
  Node node,
  DateTime now, {
  Set<String>? plannedNodeIds,
}) {
  for (final rule in rules) {
    if (rule.isHide &&
        rule.enabled &&
        rule.selector.matches(node, now, plannedNodeIds: plannedNodeIds)) {
      return true;
    }
  }
  return false;
}

/// Human summary, e.g. "Due this week · highlighted" or
/// "Physics · hidden".
String describeTaskRule(TaskRule rule) {
  final effect = rule.isHide ? 'hidden' : 'highlighted';
  return '${describeTaskFilter(rule.selector)} · $effect';
}
