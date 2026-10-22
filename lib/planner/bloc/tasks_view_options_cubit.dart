import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../../common/persistence/migration.dart';
import '../model/task_filter.dart';
import '../model/task_rule.dart';

class TasksViewOptionsState extends Equatable {
  /// Saved views. The first three are the legacy All/Today/Overdue
  /// presets; the user can edit, add, and delete (except 'all', which is
  /// the escape hatch back to everything). Exactly one is active: views
  /// only ever hide.
  final List<TaskFilter> filters;

  /// Id of the active view. Unknown ids (deleted filter, corrupt payload)
  /// fall back to 'all'.
  final String activeFilterId;

  /// Ordered display rules applied on top of the active view. Hiding
  /// always wins over tinting; the topmost matching highlight rule wins
  /// the tint. Reordered by dragging on the rules page.
  final List<TaskRule> rules;

  const TasksViewOptionsState({
    this.filters = const [
      TaskFilter(
        id: 'all',
        name: 'All',
        date: TaskFilterDate.all,
        showCompleted: true,
        showUndated: true,
      ),
      TaskFilter(
        id: 'today',
        name: 'Today',
        date: TaskFilterDate.today,
      ),
      TaskFilter(
        id: 'overdue',
        name: 'Overdue',
        date: TaskFilterDate.overdue,
      ),
    ],
    this.activeFilterId = 'all',
    this.rules = const [
      TaskRule(
        id: 'rule:week',
        enabled: false,
        selector: TaskFilter(
          id: 'rule:week',
          name: 'Due this week',
          date: TaskFilterDate.thisWeek,
        ),
      ),
    ],
  });

  TaskFilter get activeFilter {
    for (final f in filters) {
      if (f.id == activeFilterId) return f;
    }
    for (final f in filters) {
      if (f.id == 'all') return f;
    }
    return const TaskFilter(
      id: 'all',
      name: 'All',
      date: TaskFilterDate.all,
      showCompleted: true,
      showUndated: true,
    );
  }

  /// Any enabled hide rule hides rows, whatever the view.
  bool get hasHidingRule => rules.any(
        (r) => r.enabled && r.effect == TaskRuleEffect.hide,
      );

  /// Any enabled highlight rule tints rows.
  bool get hasHighlightRule => rules.any(
        (r) => r.enabled && r.effect == TaskRuleEffect.highlight,
      );

  /// True when any rows are hidden: a restrictive view or an enabled
  /// hide rule. Drives the filtered empty state.
  bool get isFiltering => !activeFilter.isShowAll || hasHidingRule;

  bool get hasActiveOptions => isFiltering || hasHighlightRule;

  /// True when the saved views differ from the three legacy presets, for
  /// the sheet's "Reset to defaults" affordance.
  bool get hasCustomFilters {
    final defaults = defaultTaskFilters();
    if (filters.length != defaults.length) return true;
    for (var i = 0; i < filters.length; i++) {
      if (filters[i] != defaults[i]) return true;
    }
    return false;
  }

  /// True when the rules differ from the stock disabled week tint.
  bool get hasCustomRules {
    final defaults = defaultTaskRules();
    if (rules.length != defaults.length) return true;
    for (var i = 0; i < rules.length; i++) {
      if (rules[i] != defaults[i]) return true;
    }
    return false;
  }

  TasksViewOptionsState copyWith({
    List<TaskFilter>? filters,
    String? activeFilterId,
    List<TaskRule>? rules,
  }) =>
      TasksViewOptionsState(
        filters: filters ?? this.filters,
        activeFilterId: activeFilterId ?? this.activeFilterId,
        rules: rules ?? this.rules,
      );

  @override
  List<Object?> get props => [filters, activeFilterId, rules];
}

/// Per-device Tasks views + display rules, picked from the layers button.
/// Mirrors [CalendarVisibilityCubit]: purely local (never synced),
/// additive-only JSON, and wrong-typed values fall back to defaults so a
/// corrupt payload never wipes the other prefs.
class TasksViewOptionsCubit extends HydratedCubit<TasksViewOptionsState> {
  TasksViewOptionsCubit() : super(const TasksViewOptionsState());

  void setActiveFilter(String id) {
    if (id == state.activeFilterId) return;
    if (state.filters.every((f) => f.id != id)) return;
    emit(state.copyWith(activeFilterId: id));
  }

  void addFilter(TaskFilter filter) {
    if (filter.id.isEmpty) return;
    final next = [
      ...state.filters,
      if (state.filters.every((f) => f.id != filter.id)) filter,
    ].take(20).toList();
    if (next.length == state.filters.length &&
        state.filters.any((f) => f.id == filter.id)) {
      updateFilter(filter);
      return;
    }
    emit(state.copyWith(filters: next, activeFilterId: filter.id));
  }

  void updateFilter(TaskFilter filter) {
    final next = [
      for (final f in state.filters) f.id == filter.id ? filter : f,
    ];
    if (next.every((f) => f.id != filter.id)) next.add(filter);
    emit(state.copyWith(filters: next.take(20).toList()));
  }

  /// Custom filters can go; the 'all' escape hatch cannot. Deleting the
  /// active view falls back to 'all'.
  void deleteFilter(String id) {
    if (id == 'all') return;
    final next = state.filters.where((f) => f.id != id).toList();
    if (next.length == state.filters.length) return;
    emit(state.copyWith(
      filters: next,
      activeFilterId:
          state.activeFilterId == id ? 'all' : state.activeFilterId,
    ));
  }

  void addRule(TaskRule rule) {
    if (rule.id.isEmpty) return;
    final next = [
      ...state.rules,
      if (state.rules.every((r) => r.id != rule.id)) rule,
    ].take(20).toList();
    if (next.length == state.rules.length &&
        state.rules.any((r) => r.id == rule.id)) {
      updateRule(rule);
      return;
    }
    emit(state.copyWith(rules: next));
  }

  void updateRule(TaskRule rule) {
    final next = [
      for (final r in state.rules) r.id == rule.id ? rule : r,
    ];
    if (next.every((r) => r.id != rule.id)) next.add(rule);
    emit(state.copyWith(rules: next.take(20).toList()));
  }

  void deleteRule(String id) {
    final next = state.rules.where((r) => r.id != id).toList();
    if (next.length == state.rules.length) return;
    emit(state.copyWith(rules: next));
  }

  /// Drag-to-reorder on the rules page. Both indices refer to the current
  /// list (callers following the [ReorderableListView] convention adjust
  /// [newIndex] past the removal first).
  void moveRule(int oldIndex, int newIndex) {
    final next = [...state.rules];
    if (oldIndex < 0 || oldIndex >= next.length) return;
    if (newIndex < 0 || newIndex > next.length) return;
    if (oldIndex == newIndex) return;
    final rule = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), rule);
    emit(state.copyWith(rules: next));
  }

  void setRuleEnabled(String id, bool enabled) {
    final next = [
      for (final r in state.rules)
        r.id == id && r.enabled != enabled
            ? r.copyWith(enabled: enabled)
            : r,
    ];
    emit(state.copyWith(rules: next));
  }

  /// Null restores the theme-default tint.
  void setRuleColor(String id, int? colorValue) {
    final next = [
      for (final r in state.rules)
        if (r.id == id)
          colorValue == null
              ? r.copyWith(clearColor: true)
              : r.copyWith(colorValue: colorValue)
        else
          r,
    ];
    emit(state.copyWith(rules: next));
  }

  void setRuleEffect(String id, TaskRuleEffect effect) {
    final next = [
      for (final r in state.rules)
        r.id == id && r.effect != effect
            // Switching to hide drops the tint; switching back starts
            // from the theme default.
            ? r.copyWith(effect: effect, clearColor: true)
            : r,
    ];
    emit(state.copyWith(rules: next));
  }

  /// The empty state's way back: hiding rules switch off, tints stay —
  /// tints never remove rows.
  void disableHidingRules() {
    if (!state.hasHidingRule) return;
    emit(state.copyWith(
      rules: [
        for (final r in state.rules)
          r.isHide && r.enabled ? r.copyWith(enabled: false) : r,
      ],
    ));
  }

  void clearAll() {
    if (!state.hasActiveOptions &&
        !state.hasCustomFilters &&
        !state.hasCustomRules &&
        state.activeFilterId == 'all') {
      return;
    }
    emit(const TasksViewOptionsState());
  }

  @override
  TasksViewOptionsState? fromJson(Map<String, dynamic> json) {
    try {
      if (json.containsKey('filters') ||
          json.containsKey('activeFilterId') ||
          json.containsKey('rules') ||
          json.containsKey('highlight')) {
        return _parseCurrent(json);
      }
      // This marker is source-scanned; it never disables a runtime restore.
      if (Migration.removeAfter('2026-10-19')) return _parseLegacy(json);
      return _parseLegacy(json);
    } catch (_) {
      return const TasksViewOptionsState();
    }
  }

  TasksViewOptionsState _parseCurrent(Map<String, dynamic> json) {
    final rawFilters = json['filters'];
    var filters = <TaskFilter>[];
    if (rawFilters is List) {
      for (final item in rawFilters) {
        final parsed = TaskFilter.tryParse(item);
        if (parsed != null) filters.add(parsed);
        if (filters.length >= 20) break;
      }
    }
    if (filters.isEmpty) filters = defaultTaskFilters();
    if (filters.every((f) => f.id != 'all')) {
      filters = [defaultTaskFilters().first, ...filters];
    }
    final rawActive = json['activeFilterId'];
    final active = rawActive is String &&
            filters.any((f) => f.id == rawActive)
        ? rawActive
        : 'all';
    return TasksViewOptionsState(
      filters: filters,
      activeFilterId: active,
      rules: _parseRules(json),
    );
  }

  /// New 'rules' list wins; otherwise the pre-rules single highlight maps
  /// onto one equivalent rule so the upgrade keeps the user's window,
  /// color, and hide behavior. Wrong-shaped entries drop per-item.
  List<TaskRule> _parseRules(Map<String, dynamic> json) {
    final rawRules = json['rules'];
    if (rawRules is List) {
      final rules = <TaskRule>[];
      for (final item in rawRules) {
        final parsed = TaskRule.tryParse(item);
        if (parsed != null) rules.add(parsed);
        if (rules.length >= 20) break;
      }
      return rules;
    }
    final highlight =
        TaskHighlight.tryParse(json['highlight']) ?? const TaskHighlight();
    if (json.containsKey('highlight')) {
      return [TaskRule.fromHighlight(highlight)];
    }
    return defaultTaskRules();
  }

  /// Payloads written before custom filters existed only carry the week
  /// tint flag and the All/Today/Overdue enum. Map them onto the matching
  /// default preset + rule so the upgrade keeps the user's view.
  /// Gated — delete this branch (and the import) once expired.
  TasksViewOptionsState _parseLegacy(Map<String, dynamic> json) {
    const legacyIds = {'all', 'today', 'overdue'};
    final rawFilter = json['dueFilter'];
    final active = rawFilter is String && legacyIds.contains(rawFilter)
        ? rawFilter
        : 'all';
    final rawHighlight = json['highlightDueThisWeek'];
    return TasksViewOptionsState(
      filters: defaultTaskFilters(),
      activeFilterId: active,
      rules: [
        defaultTaskRules().first.copyWith(
              enabled: rawHighlight is bool ? rawHighlight : false,
            ),
      ],
    );
  }

  @override
  Map<String, dynamic> toJson(TasksViewOptionsState state) => {
        'version': 2,
        'filters': state.filters.map((f) => f.toJson()).toList(),
        'activeFilterId': state.activeFilterId,
        'rules': state.rules.map((r) => r.toJson()).toList(),
      };
}
