import 'package:bloc/bloc.dart';

import '../service/goal_graph_filter.dart';

/// Which Goals view is showing. The graph is the landing view: it is the
/// only view that keeps the relationships between goals visible, and
/// filtering collapses non-matching ancestors into path markers instead of
/// deleting them.
enum GoalsViewMode {
  graph,
  all,
  leaves,
  automated,
  favorites,
  due,
  scheduled,
  money,
  habits,
}

/// Goals-page view state that outlives the page: which view is showing, the
/// search text, the filter selection, the page-level expand-all toggle, and
/// the graph's folded subtrees.
///
/// Deliberately NOT hydrated. This is view state, not data: it lives above
/// the page (`main.dart`) only so switching tabs and coming back shows the
/// same page instead of resetting to defaults. A fresh app start starts
/// clean, and no stored node id can go stale across sessions.
class GoalsViewState {
  const GoalsViewState({
    this.mode = GoalsViewMode.graph,
    this.query = '',
    this.filter = const GoalGraphFilter(),
    this.expandAll = false,
    this.collapsedIds,
  });

  final GoalsViewMode mode;

  /// Search text, as typed on the Goals page.
  final String query;

  /// Filter-menu selection (date/kind/status/star/topic).
  final GoalGraphFilter filter;

  /// Page-level "Expand all" toggle. The graph and the goal tree seed their
  /// expansion from it when the page mounts.
  final bool expandAll;

  /// Graph subtree ids folded by the user (or by the graph's default seed
  /// of repeating templates and wide goals). Null until the graph has seeded
  /// defaults; an empty set means "nothing is folded".
  final Set<String>? collapsedIds;
}

/// Keeps [GoalsViewState] alive while the Goals page is off screen.
///
/// The page owns its fields and saves a snapshot after each change (see
/// `_NodesPageState._persistView`); this cubit is only the keeper. Nothing
/// watches it, so the page restores itself once on mount instead of every
/// widget above it rebuilding on each keystroke.
class GoalsViewCubit extends Cubit<GoalsViewState> {
  GoalsViewCubit() : super(const GoalsViewState());

  /// Replaces the snapshot. No-op after close so a late post-frame save
  /// during teardown cannot throw.
  void save(GoalsViewState next) {
    if (isClosed) return;
    emit(next);
  }
}
