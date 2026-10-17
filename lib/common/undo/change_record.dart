import 'package:equatable/equatable.dart';

abstract interface class Revertable {
  String get changeId;
  void applyState(Object? state);
  void applyJson(Map<String, dynamic>? json);
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
