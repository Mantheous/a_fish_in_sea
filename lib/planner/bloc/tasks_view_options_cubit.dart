import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

/// Date-window filter for the Tasks page lists. [all] shows everything;
/// [today] shows open items due today; [overdue] shows open items past
/// their due date. Unknown stored values fall back to [all] so renames
/// never wipe prefs.
enum TasksDueFilter { all, today, overdue }

class TasksViewOptionsState extends Equatable {
  /// Tint rows for open items due in the rest of the calendar week
  /// (today through Sunday).
  final bool highlightDueThisWeek;

  /// Date-window filter. Anything but [TasksDueFilter.all] hides
  /// completed, undated, and out-of-window items in both task lists.
  final TasksDueFilter dueFilter;

  const TasksViewOptionsState({
    this.highlightDueThisWeek = false,
    this.dueFilter = TasksDueFilter.all,
  });

  bool get hasActiveOptions =>
      highlightDueThisWeek || dueFilter != TasksDueFilter.all;

  bool get isFiltering => dueFilter != TasksDueFilter.all;

  TasksViewOptionsState copyWith({
    bool? highlightDueThisWeek,
    TasksDueFilter? dueFilter,
  }) =>
      TasksViewOptionsState(
        highlightDueThisWeek:
            highlightDueThisWeek ?? this.highlightDueThisWeek,
        dueFilter: dueFilter ?? this.dueFilter,
      );

  @override
  List<Object?> get props => [highlightDueThisWeek, dueFilter];
}

/// Per-device view options for the Tasks page, toggled from the layers
/// button. Mirrors [CalendarVisibilityCubit]: purely local (never synced),
/// additive-only JSON, and wrong-typed values fall back to defaults so a
/// corrupt payload never wipes the other prefs.
class TasksViewOptionsCubit extends HydratedCubit<TasksViewOptionsState> {
  TasksViewOptionsCubit() : super(const TasksViewOptionsState());

  void setHighlightDueThisWeek(bool value) {
    if (value == state.highlightDueThisWeek) return;
    emit(state.copyWith(highlightDueThisWeek: value));
  }

  void setDueFilter(TasksDueFilter filter) {
    if (filter == state.dueFilter) return;
    emit(state.copyWith(dueFilter: filter));
  }

  void clearAll() {
    if (!state.hasActiveOptions) return;
    emit(const TasksViewOptionsState());
  }

  @override
  TasksViewOptionsState? fromJson(Map<String, dynamic> json) {
    try {
      final rawHighlight = json['highlightDueThisWeek'];
      final rawFilter = json['dueFilter'];
      return TasksViewOptionsState(
        highlightDueThisWeek:
            rawHighlight is bool ? rawHighlight : false,
        dueFilter: rawFilter is String
            ? TasksDueFilter.values.firstWhere(
                (e) => e.name == rawFilter,
                orElse: () => TasksDueFilter.all,
              )
            : TasksDueFilter.all,
      );
    } catch (_) {
      return const TasksViewOptionsState();
    }
  }

  @override
  Map<String, dynamic> toJson(TasksViewOptionsState state) => {
        'highlightDueThisWeek': state.highlightDueThisWeek,
        'dueFilter': state.dueFilter.name,
      };
}
