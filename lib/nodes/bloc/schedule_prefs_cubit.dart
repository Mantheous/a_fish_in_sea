import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../../common/persistence/stable_storage_keys.dart';
import '../model/node.dart';

/// Day vs hour/minute granularity for scheduling a node.
///
/// Day = due date ([ScheduleFacet.due]); timed = calendar block
/// ([ScheduleFacet.start]/[ScheduleFacet.end]). Both live on the same
/// backend facet — this only remembers which UI the user picked last.
enum ScheduleGranularity { day, timed }

class SchedulePrefsState extends Equatable {
  final ScheduleGranularity lastUsed;

  const SchedulePrefsState({this.lastUsed = ScheduleGranularity.day});

  SchedulePrefsState copyWith({ScheduleGranularity? lastUsed}) =>
      SchedulePrefsState(lastUsed: lastUsed ?? this.lastUsed);

  @override
  List<Object?> get props => [lastUsed];
}

/// Per-device schedule UI preference: which granularity the unified
/// schedule entry opens on when the node has no schedule yet.
///
/// Local only (never synced): purely which picker the user saw last.
/// Additive-only JSON with an `orElse` fallback so unknown values read
/// as day instead of wiping the pref.
class SchedulePrefsCubit extends HydratedCubit<SchedulePrefsState> {
  SchedulePrefsCubit() : super(const SchedulePrefsState());

  @override
  String get storagePrefix => StableStorageKeys.schedulePrefs;

  void setGranularity(ScheduleGranularity value) {
    if (value == state.lastUsed) return;
    emit(state.copyWith(lastUsed: value));
  }

  /// Initial sheet/section mode: existing data wins (a block-only node
  /// opens timed, a due-only node opens day); otherwise the last-used
  /// preference. Both-or-neither falls back to the preference.
  static ScheduleGranularity initialFor({
    ScheduleFacet? schedule,
    ScheduleGranularity fallback = ScheduleGranularity.day,
  }) {
    final hasDue = schedule?.due != null;
    final hasBlock = schedule?.hasCalendarBlock ?? false;
    if (hasBlock && !hasDue) return ScheduleGranularity.timed;
    if (hasDue && !hasBlock) return ScheduleGranularity.day;
    return fallback;
  }

  static ScheduleGranularity _parseGranularity(Object? raw) {
    if (raw is String) {
      return ScheduleGranularity.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => ScheduleGranularity.day,
      );
    }
    return ScheduleGranularity.day;
  }

  @override
  SchedulePrefsState? fromJson(Map<String, dynamic> json) {
    try {
      if (!json.containsKey('lastUsed')) {
        return const SchedulePrefsState();
      }
      return SchedulePrefsState(
        lastUsed: _parseGranularity(json['lastUsed']),
      );
    } catch (_) {
      return const SchedulePrefsState();
    }
  }

  @override
  Map<String, dynamic> toJson(SchedulePrefsState state) => {
        'lastUsed': state.lastUsed.name,
      };
}
