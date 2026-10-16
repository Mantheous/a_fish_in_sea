import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../../nodes/model/node.dart';
import '../model/assignment_estimate.dart';

/// Learned "how long does this kind of assignment take, and when do I
/// usually start it" data, keyed by feed + classified template key.
///
/// Purely local, like [AssignmentRulesCubit]: per-device planning
/// knowledge that comes from the user's own recorded sessions. It is
/// derived data — [rebuildFrom] recomputes the whole index from the node
/// list, so nothing is lost if storage is empty and nothing drifts if it
/// is rebuilt twice. Groups with no recent session are kept so a quiet
/// week does not erase what the app learned.
/// Additive-only JSON: a payload missing every new key loads as an empty
/// index (no estimate, falls back to an hour), and a corrupt entry is
/// skipped so one bad row never wipes the rest.
class AssignmentEstimatesCubit extends HydratedCubit<List<AssignmentTypeEffort>> {
  AssignmentEstimatesCubit() : super(const []);

  AssignmentTypeEffort? forType({
    required String? feedId,
    required String? classId,
    required String title,
  }) =>
      effortFor(
        feedId: feedId,
        classId: classId,
        title: title,
        efforts: state,
      );

  /// Recompute the learned index from every recorded homework session.
  ///
  /// Safe to call often (app start, after a timer stops, on every sync):
  /// the result is a pure function of the node list plus the currently
  /// stored groups. Emits only when something actually changed, so a
  /// listener on the node list does not rewrite storage every edit.
  void rebuildFrom(List<Node> nodes, {DateTime? now}) {
    final next = learnEffortIndex(nodes, existing: state, now: now);
    if (_signature(next) == _signature(state)) return;
    emit(next);
  }

  /// Stable content fingerprint: enough to detect a change without
  /// triggering a write when nothing moved.
  static String _signature(List<AssignmentTypeEffort> list) => list
      .map((e) =>
          '${e.groupKey}:${e.samples}:${e.totalMinutes}:'
          '${e.minutes.join(',')}:${e.startMinutes.join(',')}')
      .join('|');

  /// Drops learned data for one class/feed — used when the user removes a
  /// class, so deleted coursework stops showing up in the stats.
  void forgetFeed(String feedId) {
    final next = state.where((e) => e.feedId != feedId).toList();
    if (next.length == state.length) return;
    emit(next);
  }

  @override
  List<AssignmentTypeEffort>? fromJson(Map<String, dynamic> json) {
    final list = json['efforts'] as List<dynamic>?;
    if (list == null) return null;
    final out = <AssignmentTypeEffort>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        out.add(AssignmentTypeEffort.fromJson(
            Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<AssignmentTypeEffort> state) => {
        'efforts': state.map((e) => e.toJson()).toList(),
      };
}
