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

  void addPoint(TrackedPoint point) {
    final last = state.points.isEmpty ? null : state.points.last;
    if (last != null &&
        last.lat == point.lat &&
        last.lng == point.lng &&
        point.timestamp.difference(last.timestamp).inMinutes < 1) {
      return;
    }
    var next = [...state.points, point];
    if (next.length > maxPoints) {
      next = next.sublist(next.length - maxPoints);
    }
    final cutoff = DateTime.now().subtract(const Duration(days: retentionDays));
    next = next.where((p) => p.timestamp.isAfter(cutoff)).toList();
    emit(state.copyWith(points: next));
  }

  void mergePoints(List<TrackedPoint> incoming) {
    if (incoming.isEmpty) return;
    final known = {for (final p in state.points) p.id};
    final fresh = incoming.where((p) => !known.contains(p.id)).toList();
    if (fresh.isEmpty) return;
    for (final point in fresh) {
      addPoint(point);
    }
  }

  void clearDay(DateTime day) {
    emit(state.copyWith(
      points: state.points.where((p) => !isSameDay(p.timestamp, day)).toList(),
    ));
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
