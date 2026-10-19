import 'dart:convert';

import 'package:equatable/equatable.dart';

abstract interface class Revertable {
  String get changeId;
  void applyState(Object? state);
  void applyJson(Map<String, dynamic>? json);

  /// Item-scoped undo: reverts only the ids this [entry] changed, leaving
  /// ids that arrived after the edit (e.g. via a background sync pull)
  /// untouched. See [mergeUndoJson].
  void applyUndo(StateSnapshot entry);

  /// Item-scoped redo: re-applies only the ids this [entry] changed.
  /// See [mergeUndoJson].
  void applyRedo(StateSnapshot entry);
}

class RevertableRegistry {
  static final Map<String, Revertable> _cubits = {};

  static void register(Revertable cubit) => _cubits[cubit.changeId] = cubit;

  static void unregister(Revertable cubit) {
    if (_cubits[cubit.changeId] == cubit) _cubits.remove(cubit.changeId);
  }

  static Revertable? byId(String id) => _cubits[id];

  static void reset() => _cubits.clear();
}

class StateSnapshot extends Equatable {
  final String cubitId;
  final Object? stateBefore;
  final Object? stateAfter;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  const StateSnapshot({
    required this.cubitId,
    this.stateBefore,
    this.stateAfter,
    this.before,
    this.after,
  });

  factory StateSnapshot.fromJson(Map<String, dynamic> json) => StateSnapshot(
        cubitId: json['cubitId'] as String,
        before: json['before'] != null
            ? Map<String, dynamic>.from(json['before'] as Map<dynamic, dynamic>)
            : null,
        after: json['after'] != null
            ? Map<String, dynamic>.from(json['after'] as Map<dynamic, dynamic>)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'cubitId': cubitId,
        'before': before ?? const <String, dynamic>{},
        'after': after ?? const <String, dynamic>{},
      };

  @override
  List<Object?> get props => [cubitId, stateBefore ?? before, stateAfter ?? after];
}

class ChangeRecord extends Equatable {
  final List<StateSnapshot> entries;

  const ChangeRecord({required this.entries});

  ChangeRecord.single(StateSnapshot snapshot)
      : entries = [snapshot];

  factory ChangeRecord.fromJson(Map<String, dynamic> json) {
    final entries = <StateSnapshot>[];
    final list = json['entries'] as List<dynamic>? ?? const [];
    for (final item in list) {
      try {
        entries.add(
          StateSnapshot.fromJson(Map<String, dynamic>.from(item as Map)),
        );
      } catch (_) {}
    }
    return ChangeRecord(entries: entries);
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  @override
  List<Object?> get props => [entries];
}

/// Deep-equality for JSON values. `jsonEncode` is deterministic for the
/// envelopes our cubits produce (same `toJson`, same key order), so equal
/// content encodes equally.
bool undoJsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a == b) return true;
  try {
    return jsonEncode(a) == jsonEncode(b);
  } catch (_) {
    return false;
  }
}

/// Item-scoped merge for undo/redo replay.
///
/// [before] is the collection envelope captured before the user's edit,
/// [after] the envelope right after it, and [current] the live envelope
/// (which may include ids pulled by a background sync since the edit).
/// With [isUndo] true the merge moves source=[after] towards target=[before]
/// (redo moves source=[before] towards target=[after]). Only ids whose
/// source/target content differs — i.e. ids the user's edit touched — are
/// reconciled, and only when the live copy still matches the source side
/// (no intervening external change to that id):
/// - id only in source (user added for undo / removed for redo): dropped
///   from the merged copy only if the live copy still equals the source.
/// - id only in target (user removed for undo / added for redo): restored
///   from the target only if the live copy is missing the id (a sync that
///   re-created the same id wins).
/// - id in both with different content (user edited): restored from the
///   target only if the live copy still equals the source.
///
/// Ids the edit never touched — including everything a sync pulled after
/// the edit — are carried over verbatim from [current]. Returns null when
/// the envelopes are not a recognized shape (single-list collection or
/// `days` map); callers then fall back to a conditional full restore.
///
/// Order: the merged list follows [current]'s order, with restored
/// (re-added) ids appended in target order. When nothing arrived between
/// the edit and the replay, callers should skip this and restore the
/// target snapshot directly so order is preserved exactly.
Map<String, dynamic>? mergeUndoJson(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
  Map<String, dynamic> current, {
  required bool isUndo,
}) {
  if (before['days'] is Map || after['days'] is Map || current['days'] is Map) {
    return _mergeDaysUndo(before, after, current, isUndo: isUndo);
  }
  String? listKey;
  for (final env in [before, after, current]) {
    for (final entry in env.entries) {
      if (entry.value is List) {
        listKey = entry.key;
        break;
      }
    }
    if (listKey != null) break;
  }
  if (listKey == null) return null;
  final b = before[listKey];
  final a = after[listKey];
  final c = current[listKey];
  if (b is! List || a is! List || c is! List) return null;
  final merged = _mergeIdListUndo(b, a, c, isUndo: isUndo);
  if (merged == null) return null;
  return {...current, listKey: merged};
}

Map<String, dynamic>? _mergeDaysUndo(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
  Map<String, dynamic> current, {
  required bool isUndo,
}) {
  final b = before['days'];
  final a = after['days'];
  final c = current['days'];
  if (b is! Map || a is! Map || c is! Map) return null;
  final source = isUndo ? a : b;
  final target = isUndo ? b : a;
  final changedDays = <String>{
    for (final k in {...source.keys, ...target.keys}.map((e) => e.toString()))
      if (!undoJsonEquals(source[k], target[k])) k,
  };
  final merged = Map<String, dynamic>.from(c);
  for (final day in changedDays) {
    final s = source[day];
    final t = target[day];
    final cur = merged[day];
    if (s != null && t == null) {
      if (cur != null && undoJsonEquals(cur, s)) merged.remove(day);
    } else if (s == null && t != null) {
      if (cur == null) merged[day] = t;
    } else {
      if (cur != null && undoJsonEquals(cur, s)) {
        if (t == null) {
          merged.remove(day);
        } else {
          merged[day] = t;
        }
      }
    }
  }
  return {...current, 'days': merged};
}

List<dynamic>? _mergeIdListUndo(
  List<dynamic> before,
  List<dynamic> after,
  List<dynamic> current, {
  required bool isUndo,
}) {
  Map<String, dynamic>? asItem(dynamic e) {
    if (e is! Map) return null;
    final m = Map<String, dynamic>.from(e);
    if (m['id'] is! String) return null;
    return m;
  }

  final beforeItems = <Map<String, dynamic>>[];
  for (final e in before) {
    final m = asItem(e);
    if (m == null) return null;
    beforeItems.add(m);
  }
  final afterItems = <Map<String, dynamic>>[];
  for (final e in after) {
    final m = asItem(e);
    if (m == null) return null;
    afterItems.add(m);
  }
  final currentItems = <Map<String, dynamic>>[];
  for (final e in current) {
    final m = asItem(e);
    if (m == null) return null;
    currentItems.add(m);
  }
  final sourceItems = isUndo ? afterItems : beforeItems;
  final targetItems = isUndo ? beforeItems : afterItems;
  final sourceById = {for (final m in sourceItems) m['id'] as String: m};
  final targetById = {for (final m in targetItems) m['id'] as String: m};
  final currentById = {for (final m in currentItems) m['id'] as String: m};
  final changedIds = <String>{
    for (final id in {...sourceById.keys, ...targetById.keys})
      if (!undoJsonEquals(sourceById[id], targetById[id])) id,
  };
  if (changedIds.isEmpty) return List<dynamic>.from(current);
  final mergedById = Map<String, Map<String, dynamic>>.of(currentById);
  for (final id in changedIds) {
    final s = sourceById[id];
    final t = targetById[id];
    final cur = mergedById[id];
    if (s != null && t == null) {
      if (cur != null && undoJsonEquals(cur, s)) mergedById.remove(id);
    } else if (s == null && t != null) {
      if (cur == null) mergedById[id] = t;
    } else if (s != null && t != null) {
      if (cur != null && undoJsonEquals(cur, s)) mergedById[id] = t;
    }
  }
  final out = <Map<String, dynamic>>[];
  for (final m in currentItems) {
    final merged = mergedById[m['id'] as String];
    if (merged == null) continue;
    out.add(merged);
  }
  final currentIds = {for (final m in currentItems) m['id'] as String};
  for (final m in targetItems) {
    final id = m['id'] as String;
    if (!currentIds.contains(id) && mergedById.containsKey(id)) {
      out.add(mergedById[id]!);
    }
  }
  return out;
}
