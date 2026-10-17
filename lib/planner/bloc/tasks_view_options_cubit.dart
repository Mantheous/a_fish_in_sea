import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../../common/persistence/migration.dart';
import '../model/task_filter.dart';

class TasksViewOptionsState extends Equatable {
  /// Saved views. The first three are the legacy All/Today/Overdue
  /// presets; the user can edit, add, and delete (except 'all', which is
  /// the escape hatch back to everything).
  final List<TaskFilter> filters;

  /// Id of the active view. Unknown ids (deleted filter, corrupt payload)
  /// fall back to 'all'.
  final String activeFilterId;

  /// Independent tint-or-hide applied on top of the active view.
  final TaskHighlight highlight;

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
    this.highlight = const TaskHighlight(),
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

  /// True when any rows are hidden: a restrictive view, or a highlight in
  /// "Hide" mode. Drives the filtered empty state.
  bool get isFiltering =>
      !activeFilter.isShowAll ||
      (highlight.enabled && highlight.hideMatching);

  bool get hasActiveOptions => isFiltering || highlight.enabled;

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

  TasksViewOptionsState copyWith({
    List<TaskFilter>? filters,
    String? activeFilterId,
    TaskHighlight? highlight,
  }) =>
      TasksViewOptionsState(
        filters: filters ?? this.filters,
        activeFilterId: activeFilterId ?? this.activeFilterId,
        highlight: highlight ?? this.highlight,
      );

  @override
  List<Object?> get props => [filters, activeFilterId, highlight];
}

/// Per-device Tasks views, picked from the layers button. Mirrors
/// [CalendarVisibilityCubit]: purely local (never synced), additive-only
/// JSON, and wrong-typed values fall back to defaults so a corrupt payload
/// never wipes the other prefs.
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

  void setHighlightEnabled(bool value) {
    if (value == state.highlight.enabled) return;
    emit(state.copyWith(
        highlight: state.highlight.copyWith(enabled: value)));
  }

  void setHighlightDate(TaskHighlightDate date) {
    if (date == state.highlight.date) return;
    emit(
        state.copyWith(highlight: state.highlight.copyWith(date: date)));
  }

  /// Null restores the theme-default tint.
  void setHighlightColor(int? colorValue) {
    if (colorValue == state.highlight.colorValue) return;
    if (colorValue == null) {
      emit(state.copyWith(
          highlight: state.highlight.copyWith(clearColor: true)));
    } else {
      emit(state.copyWith(
          highlight: state.highlight.copyWith(colorValue: colorValue)));
    }
  }

  /// The "Hide" color: matching items are hidden instead of tinted.
  void setHighlightHideMatching(bool value) {
    if (value == state.highlight.hideMatching) return;
    emit(state.copyWith(
        highlight: state.highlight.copyWith(hideMatching: value)));
  }

  void clearAll() {
    if (!state.hasActiveOptions &&
        !state.hasCustomFilters &&
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
          json.containsKey('highlight')) {
        return _parseCurrent(json);
      }
      if (Migration.removeAfter('2026-10-19')) {
        return _parseLegacy(json);
      }
      return const TasksViewOptionsState();
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
    final highlight =
        TaskHighlight.tryParse(json['highlight']) ?? const TaskHighlight();
    return TasksViewOptionsState(
      filters: filters,
      activeFilterId: active,
      highlight: highlight,
    );
  }

  /// Payloads written before custom filters existed only carry the week
  /// tint flag and the All/Today/Overdue enum. Map them onto the matching
  /// default preset + highlight so the upgrade keeps the user's view.
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
      highlight: TaskHighlight(
        enabled: rawHighlight is bool ? rawHighlight : false,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson(TasksViewOptionsState state) => {
        'version': 1,
        'filters': state.filters.map((f) => f.toJson()).toList(),
        'activeFilterId': state.activeFilterId,
        'highlight': state.highlight.toJson(),
      };
}
