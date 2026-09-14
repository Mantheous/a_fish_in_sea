import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../model/tracked_point.dart';
import '../reporting_logic.dart';

class TrackingState extends Equatable {
  final bool isRecording;
  final DateTime? startedAt;
  final List<TrackedPoint> points;

  const TrackingState({
    this.isRecording = false,
    this.startedAt,
    this.points = const [],
  });

  TrackingState copyWith({
    bool? isRecording,
    DateTime? startedAt,
    bool clearStartedAt = false,
    List<TrackedPoint>? points,
  }) =>
      TrackingState(
        isRecording: isRecording ?? this.isRecording,
        startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
        points: points ?? this.points,
      );

  List<TrackedPoint> pointsOnDay(DateTime day) =>
      points.where((p) => isSameDay(p.timestamp, day)).toList();

  @override
  List<Object?> get props => [isRecording, startedAt, points];
}

class TrackingCubit extends HydratedCubit<TrackingState> {
  static const int maxPoints = 5000;
  static const int retentionDays = 30;

  TrackingCubit() : super(const TrackingState());

  void startRecording() {
    if (state.isRecording) return;
    emit(state.copyWith(isRecording: true, startedAt: DateTime.now()));
  }

  void stopRecording() {
    if (!state.isRecording) return;
    emit(state.copyWith(isRecording: false, clearStartedAt: true));
  }

  bool _isDuplicateOfLast(TrackedPoint last, TrackedPoint point) {
    if (point.timestamp.difference(last.timestamp).inMinutes >= 1) {
      return false;
    }
    if (last.id == point.id) return true;
    // Exact double equality almost never fires for real GPS; treat points
    // within ~15 m of the previous fix as stationary duplicates.
    const degToM = 111320.0;
    final avgLatRad =
        (last.lat + point.lat) / 2 * 3.141592653589793 / 180;
    final dx = (point.lat - last.lat) * degToM;
    final dy = (point.lng - last.lng) * degToM * math.cos(avgLatRad);
    return (dx * dx + dy * dy) < 15 * 15;
  }

  List<TrackedPoint> _appendAll(
      List<TrackedPoint> current, List<TrackedPoint> incoming) {
    var next = [...current];
    for (final point in incoming) {
      final last = next.isEmpty ? null : next.last;
      if (last != null && _isDuplicateOfLast(last, point)) continue;
      next.add(point);
    }
    if (next.length > maxPoints) {
      next = next.sublist(next.length - maxPoints);
    }
    final cutoff = DateTime.now().subtract(const Duration(days: retentionDays));
    next = next.where((p) => p.timestamp.isAfter(cutoff)).toList();
    return next;
  }

  void addPoint(TrackedPoint point) {
    final last = state.points.isEmpty ? null : state.points.last;
    if (last != null && _isDuplicateOfLast(last, point)) return;
    emit(state.copyWith(points: _appendAll(state.points, [point])));
  }

  void mergePoints(List<TrackedPoint> incoming) {
    if (incoming.isEmpty) return;
    final known = {for (final p in state.points) p.id};
    final fresh = incoming.where((p) => !known.contains(p.id)).toList();
    if (fresh.isEmpty) return;
    fresh.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Single emit: the old per-point loop re-emitted (and re-filtered the
    // 30-day retention + 5000-point cap) for every point, which is O(n^2)
    // for background batches.
    emit(state.copyWith(points: _appendAll(state.points, fresh)));
  }

  void clearDay(DateTime day) {
    emit(state.copyWith(
      points: state.points.where((p) => !isSameDay(p.timestamp, day)).toList(),
    ));
  }

  /// Sync apply: replaces the point set from merged server data.
  /// Recording flags stay device-local (a phone records GPS; the server
  /// must not remote-control that). Caps/retention still apply.
  void applySyncedPoints(List<Map<String, dynamic>> items) {
    final points = <TrackedPoint>[];
    for (final item in items) {
      try {
        points.add(TrackedPoint.fromJson(item));
      } catch (_) {}
    }
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    emit(state.copyWith(points: _appendAll(const [], points)));
  }

  @override
  TrackingState? fromJson(Map<String, dynamic> json) {
    try {
      final list = json['points'] as List<dynamic>?;
      final points = <TrackedPoint>[];
      if (list != null) {
        for (final item in list) {
          try {
            points.add(
              TrackedPoint.fromJson(Map<String, dynamic>.from(item as Map)),
            );
          } catch (_) {}
        }
      }
      DateTime? startedAt;
      try {
        startedAt = json['startedAt'] == null
            ? null
            : DateTime.parse(json['startedAt'] as String);
      } catch (_) {
        startedAt = null;
      }
      return TrackingState(
        isRecording: json['isRecording'] as bool? ?? false,
        startedAt: startedAt,
        points: points,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, dynamic> toJson(TrackingState state) => {
        'isRecording': state.isRecording,
        'startedAt': state.startedAt?.toIso8601String(),
        'points': state.points.map((p) => p.toJson()).toList(),
      };
}
