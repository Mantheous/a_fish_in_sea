import '../../common/undo/revertable_hydrated_cubit.dart';
import '../model/reported_entry.dart';
import '../reporting_logic.dart';

class ReportingCubit extends RevertableHydratedCubit<Map<String, List<ReportedEntry>>> {
  ReportingCubit() : super(const {});

  List<ReportedEntry> entriesForDay(DateTime day) =>
      state[dayKey(day)] ?? const [];

  void runAutoReport({
    required DateTime day,
    required List<PlannedSlice> planned,
    required List<Dwell> dwells,
    required Map<String, String> placeNames,
  }) {
    final generated = autoReport(
      planned: planned,
      dwells: dwells,
      placeNames: placeNames,
    );
    final manual =
        entriesForDay(day).where((e) => !e.auto).toList();
    final manualIds = {for (final e in manual) e.id};
    final kept = [
      ...manual,
      ...generated.where((e) => !manualIds.contains(e.id)),
    ]..sort((a, b) => a.start.compareTo(b.start));
    emitChange({...state, dayKey(day): kept});
  }

  void upsertEntry(DateTime day, ReportedEntry entry) {
    final current = [...entriesForDay(day)];
    final index = current.indexWhere((e) => e.id == entry.id);
    if (index >= 0) {
      current[index] = entry.copyWith(auto: false);
    } else {
      current.add(entry.copyWith(auto: false));
      current.sort((a, b) => a.start.compareTo(b.start));
    }
    emitChange({...state, dayKey(day): current});
  }

  void deleteEntry(DateTime day, String id) {
    emitChange({
      ...state,
      dayKey(day): entriesForDay(day).where((e) => e.id != id).toList(),
    });
  }

  void clearDay(DateTime day) {
    final next = {...state}..remove(dayKey(day));
    emitChange(next);
  }

  @override
  Map<String, List<ReportedEntry>>? fromJson(Map<String, dynamic> json) {
    try {
      final days = json['days'] as Map<String, dynamic>?;
      if (days == null) return const {};
      final out = <String, List<ReportedEntry>>{};
      for (final entry in days.entries) {
        try {
          final items = entry.value as List<dynamic>;
          final decoded = <ReportedEntry>[];
          for (final item in items) {
            try {
              decoded.add(
                ReportedEntry.fromJson(Map<String, dynamic>.from(item as Map)),
              );
            } catch (_) {}
          }
          out[entry.key] = decoded;
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, dynamic> toJson(Map<String, List<ReportedEntry>> state) => {
        'days': {
          for (final entry in state.entries)
            entry.key: entry.value.map((e) => e.toJson()).toList(),
        },
      };
}
