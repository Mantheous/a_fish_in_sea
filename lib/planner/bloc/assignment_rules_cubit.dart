import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../model/assignment_rule.dart';

/// User rules for repeating homework types ("Video Quizzes are due 2 days
/// early in my plan"). Purely local, like [TasksViewOptionsCubit] and
/// [CalendarVisibilityCubit]: per-device planning preferences, never
/// synced, additive-only JSON, corrupt entries skipped so one bad rule
/// never wipes the rest.
///
/// Rules shift the deadline the app plans around; the feed's own dates
/// stay untouched in schedule.start/end. Fresh imports shift
/// automatically (via FeedCubit → NodeCubit.importFromFeed); existing
/// items shift through the explicit Apply/Revert buttons in the rules
/// sheet, each a single undoable NodeCubit write.
class AssignmentRulesCubit extends HydratedCubit<List<AssignmentRule>> {
  AssignmentRulesCubit() : super(const []);

  AssignmentRule? byId(String id) {
    for (final rule in state) {
      if (rule.id == id) return rule;
    }
    return null;
  }

  /// Rule governing one homework item, or null.
  AssignmentRule? ruleFor({
    required String? feedId,
    required String? classId,
    required String title,
  }) =>
      assignmentRuleFor(state,
          feedId: feedId, classId: classId, title: title);

  /// Governing offset for a fresh import, or 0.
  int offsetFor({required String feedId, required String title}) =>
      assignmentOffsetFor(state, feedId: feedId, title: title);

  /// Creates a rule for a detected group and returns it.
  AssignmentRule createRule({
    required String feedId,
    required String templateKey,
    required String displayName,
    required int dueOffsetDays,
    String? classLabel,
  }) {
    final existing = ruleForTemplate(
        feedId: feedId, templateKey: templateKey);
    final rule = AssignmentRule(
      id: existing?.id ??
          'ar-${DateTime.now().microsecondsSinceEpoch}',
      feedId: feedId,
      classLabel: classLabel,
      templateKey: templateKey,
      displayName: displayName,
      dueOffsetDays: dueOffsetDays,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
    upsertRule(rule);
    return rule;
  }

  AssignmentRule? ruleForTemplate({
    required String feedId,
    required String templateKey,
  }) {
    for (final rule in state) {
      if (rule.feedId == feedId && rule.templateKey == templateKey) {
        return rule;
      }
    }
    return null;
  }

  void upsertRule(AssignmentRule rule) {
    final next = [
      for (final r in state)
        if (r.id != rule.id) r,
      rule,
    ];
    emit(next);
  }

  void deleteRule(String id) {
    if (byId(id) == null) return;
    emit(state.where((r) => r.id != id).toList());
  }

  @override
  List<AssignmentRule>? fromJson(Map<String, dynamic> json) {
    final list = json['rules'] as List<dynamic>?;
    if (list == null) return null;
    final out = <AssignmentRule>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        out.add(AssignmentRule.fromJson(
            Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<AssignmentRule> state) =>
      {'rules': state.map((r) => r.toJson()).toList()};
}
