import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';

/// Persists the list of [RecurringRule]s.
///
/// Provides CRUD operations for recurring income/expense rules.
class RecurringRulesCubit extends HydratedCubit<List<RecurringRule>> {
  RecurringRulesCubit() : super([]);

  void addRule(RecurringRule rule) => emit([...state, rule]);

  void updateRule(RecurringRule updatedRule) {
    emit(state.map((r) => r.id == updatedRule.id ? updatedRule : r).toList());
  }

  void deleteRule(String ruleId) {
    emit(state.where((r) => r.id != ruleId).toList());
  }

  @override
  List<RecurringRule>? fromJson(Map<String, dynamic> json) {
    final list = json['rules'] as List<dynamic>?;
    if (list == null) return null;
    final out = <RecurringRule>[];
    for (final item in list) {
      try {
        out.add(RecurringRule.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<RecurringRule> state) {
    return {'rules': state.map((r) => r.toJson()).toList()};
  }
}
