import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';

enum PlannerPage { home, calendar, tasks, nodes, stats, finances, feedback, settings }

class NavigationCubit extends Cubit<PlannerPage> {
  NavigationCubit() : super(PlannerPage.home);

  String? _focusedNodeId;
  int _focusToken = 0;
  int _revision = 0;

  /// Bumped on every focus change (set or cleared) so [NodesPage] can
  /// react even when the page itself doesn't change — [emit] suppresses
  /// duplicate states, so requesting Nodes while already there would
  /// otherwise be invisible to listeners.
  final ValueNotifier<int> focusRevision = ValueNotifier<int>(0);

  /// Node id to reveal in the goal tree, or null when no reveal is pending.
  /// Transient UI state only: never persisted.
  String? get focusedNodeId => _focusedNodeId;

  /// Increments per [showNodeInGoals]; lets consumers tell a fresh request
  /// apart from an already-consumed one.
  int get focusToken => _focusToken;

  void setPage(PlannerPage page) {
    // A manual navigation drops any pending tree reveal so a stale
    // highlight never follows the user back to Nodes.
    if (_focusedNodeId != null) {
      _focusedNodeId = null;
      focusRevision.value = ++_revision;
    }
    emit(page);
  }

  /// Opens the Nodes page with [nodeId] revealed in the All tree view:
  /// ancestors expanded, target highlighted.
  void showNodeInGoals(String nodeId) {
    _focusedNodeId = nodeId;
    _focusToken++;
    focusRevision.value = ++_revision;
    emit(PlannerPage.nodes);
  }

  @override
  Future<void> close() {
    focusRevision.dispose();
    return super.close();
  }
}
