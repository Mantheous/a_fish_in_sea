import 'package:equatable/equatable.dart';

import 'assignment_template.dart';

/// A user rule for one repeating homework type: "everything shaped like
/// MATH 290's Video Quizzes is due N days earlier/later in my plan".
///
/// Matching is feed-scoped exact template-key equality (see
/// [assignmentTemplateKey]): the rule stores the [feedId] + [templateKey]
/// pair, so it can never leak across classes or swallow similarly-named
/// one-offs. [displayName] + [classLabel] are display-only; renames never
/// break matching.
///
/// The stored feed due is never rewritten at the source: [dueOffsetDays]
/// shifts the node deadline the app plans around (negative = earlier, so
/// the item surfaces in Today/Home sooner). Imported nodes keep the feed
/// window in schedule.start/end, which is also how bulk apply/revert
/// tells shifted items apart from hand-edited ones.
class AssignmentRule extends Equatable {
  final String id;
  final String feedId;
  final String? classLabel;
  final String templateKey;
  final String displayName;

  /// Days added to the feed due date. -2 = plan it two days early.
  /// Clamped to ±30 on load.
  final int dueOffsetDays;

  /// Expected minutes of work for this type, or null to use the learned
  /// average. Clamped to 5..1440 on load so a stray payload can never
  /// schedule a 40-hour block. Additive: payloads written before this
  /// existed load as null and keep learning.
  final int? estimateMinutes;

  final DateTime createdAt;

  const AssignmentRule({
    required this.id,
    required this.feedId,
    required this.templateKey,
    required this.displayName,
    required this.dueOffsetDays,
    required this.createdAt,
    this.classLabel,
    this.estimateMinutes,
  });

  /// Scope key shared with [detectRepeatingGroups] output.
  String get groupKey => '$feedId|$templateKey';

  bool get shiftsEarlier => dueOffsetDays < 0;
  bool get shiftsLater => dueOffsetDays > 0;

  AssignmentRule copyWith({
    String? displayName,
    String? classLabel,
    bool clearClassLabel = false,
    int? dueOffsetDays,
    int? estimateMinutes,
    bool clearEstimateMinutes = false,
  }) =>
      AssignmentRule(
        id: id,
        feedId: feedId,
        classLabel:
            clearClassLabel ? null : (classLabel ?? this.classLabel),
        templateKey: templateKey,
        displayName: displayName ?? this.displayName,
        dueOffsetDays: dueOffsetDays ?? this.dueOffsetDays,
        createdAt: createdAt,
        estimateMinutes: clearEstimateMinutes
            ? null
            : (estimateMinutes ?? this.estimateMinutes),
      );

  factory AssignmentRule.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final feedId = json['feedId'];
    final templateKey = json['templateKey'];
    if (id is! String ||
        id.isEmpty ||
        feedId is! String ||
        feedId.isEmpty ||
        templateKey is! String ||
        templateKey.isEmpty) {
      throw const FormatException('AssignmentRule needs id/feed/template');
    }
    final rawOffset = (json['dueOffsetDays'] as num?)?.toInt() ?? 0;
    // Tolerant + clamped: absent or nonsense falls back to "learn it"
    // rather than throwing away the user's whole rule.
    final rawEstimate = (json['estimateMinutes'] as num?)?.toInt();
    final estimate =
        rawEstimate == null || rawEstimate <= 0 ? null : rawEstimate.clamp(5, 1440);
    DateTime createdAt = DateTime.fromMillisecondsSinceEpoch(0);
    final rawCreated = json['createdAt'];
    if (rawCreated is String) {
      createdAt = DateTime.tryParse(rawCreated) ?? createdAt;
    }
    return AssignmentRule(
      id: id,
      feedId: feedId,
      classLabel: json['classLabel'] as String?,
      templateKey: templateKey,
      displayName: (json['displayName'] as String?) ?? templateKey,
      dueOffsetDays: rawOffset.clamp(-30, 30),
      estimateMinutes: estimate,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'feedId': feedId,
        'classLabel': classLabel,
        'templateKey': templateKey,
        'displayName': displayName,
        'dueOffsetDays': dueOffsetDays,
        'estimateMinutes': estimateMinutes,
        'createdAt': createdAt.toIso8601String(),
      };

  @override
  List<Object?> get props => [
        id,
        feedId,
        classLabel,
        templateKey,
        displayName,
        dueOffsetDays,
        estimateMinutes,
        createdAt,
      ];
}

/// Whether [rule] governs a homework item from [feedId]/[classId] titled
/// [title]. Exact key equality inside one feed — never substring.
bool assignmentRuleMatches(
  AssignmentRule rule, {
  required String? feedId,
  required String? classId,
  required String title,
}) {
  final scope = feedId ?? classId;
  if (scope == null || scope != rule.feedId) return false;
  return assignmentTemplateKey(title) == rule.templateKey;
}

/// First rule governing the item, or null.
AssignmentRule? assignmentRuleFor(
  List<AssignmentRule> rules, {
  required String? feedId,
  required String? classId,
  required String title,
}) {
  for (final rule in rules) {
    if (assignmentRuleMatches(rule,
        feedId: feedId, classId: classId, title: title)) {
      return rule;
    }
  }
  return null;
}

/// Planned-due shift for a fresh import, or 0 when no rule governs it.
int assignmentOffsetFor(
  List<AssignmentRule> rules, {
  required String feedId,
  required String title,
}) =>
    assignmentRuleFor(rules, feedId: feedId, classId: null, title: title)
            ?.dueOffsetDays ??
        0;

/// "2 days early" / "On time" / "3 days late".
String describeDueOffset(int days) {
  if (days == 0) return 'On time';
  final n = days.abs();
  final unit = n == 1 ? 'day' : 'days';
  return days < 0 ? '$n $unit early' : '$n $unit late';
}

/// Compact chip text: "−2d" / "±0" / "+3d".
String compactDueOffset(int days) {
  if (days == 0) return '±0';
  return days < 0 ? '−${-days}d' : '+${days}d';
}
