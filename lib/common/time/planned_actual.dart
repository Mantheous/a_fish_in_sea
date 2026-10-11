/// Planned versus actual, computed once.
///
/// The Project Time Management Ontology's central distinction is that a
/// commitment, its appointment and its occurrence are three different
/// things — and that being able to line them up is what makes progress
/// tracking possible at all. This app already carries both halves on
/// [Node], [ScheduleFacet] and [PlannerEvent], but each of the three
/// re-derived the duration arithmetic independently (and disagreed about
/// the degenerate cases). This is that arithmetic in one place.
///
/// Everything here is derived from datetimes that already exist in the
/// persisted models; nothing new is stored.
class PlannedActual {
  /// The commitment: when the work was supposed to happen. Either bound
  /// may be null.
  final DateTime? plannedStart;
  final DateTime? plannedEnd;

  /// The occurrence: when the work actually happened. Either bound may
  /// be null.
  final DateTime? actualStart;
  final DateTime? actualEnd;

  const PlannedActual({
    this.plannedStart,
    this.plannedEnd,
    this.actualStart,
    this.actualEnd,
  });

  /// No plan and no record — the "undated, unestimated placeholder" case.
  const PlannedActual.empty()
      : plannedStart = null,
        plannedEnd = null,
        actualStart = null,
        actualEnd = null;

  /// Whether either planned bound is set.
  bool get isPlanned => plannedStart != null || plannedEnd != null;

  /// Whether both actual bounds are set, i.e. the work has a record.
  bool get hasReported => actualStart != null && actualEnd != null;

  /// Whether the plan and the record both exist.
  bool get isComparable => isPlanned && hasReported;

  /// The planned interval. Null unless both bounds exist and the end
  /// strictly follows the start — a zero or backwards interval is not a
  /// duration, and this is the semantics all three callers already used.
  Duration? get plannedDuration =>
      _span(plannedStart, plannedEnd);

  /// The actual interval. Same rule as [plannedDuration].
  Duration? get actualDuration => _span(actualStart, actualEnd);

  /// Actual minus planned. Positive = it took longer than planned,
  /// negative = quicker, null = not comparable. Returns [Duration.zero]
  /// when both durations are zero-length, not a degenerate interval.
  Duration? get variance {
    final planned = plannedDuration;
    final actual = actualDuration;
    if (planned == null || actual == null) return null;
    return actual - planned;
  }

  /// Actual over planned. 1.0 = bang on, 2.0 = took twice as long, 0.5 =
  /// half as long. Null when either side is missing or zero, because the
  /// ratio would be meaningless.
  double? get accuracyRatio {
    final planned = plannedDuration;
    final actual = actualDuration;
    if (planned == null || actual == null) return null;
    if (planned.inMinutes <= 0) return null;
    return actual.inMinutes / planned.inMinutes;
  }

  /// Whether the occurrence overran the appointment.
  bool get overran {
    final v = variance;
    return v != null && v > Duration.zero;
  }

  /// Whether the work started after the planned start. Null when either
  /// bound is missing.
  bool? get startedLate {
    final p = plannedStart;
    final a = actualStart;
    if (p == null || a == null) return null;
    return a.isAfter(p);
  }

  /// Whether the work finished after the planned end. Null when either
  /// bound is missing.
  bool? get finishedLate {
    final p = plannedEnd;
    final a = actualEnd;
    if (p == null || a == null) return null;
    return a.isAfter(p);
  }

  /// Copy with an occurrence recorded. Purely additive: nulls stay null
  /// unless a replacement is supplied.
  PlannedActual copyWithRecord({
    DateTime? actualStart,
    DateTime? actualEnd,
    bool clearActualStart = false,
    bool clearActualEnd = false,
  }) =>
      PlannedActual(
        plannedStart: plannedStart,
        plannedEnd: plannedEnd,
        actualStart: clearActualStart ? null : (actualStart ?? this.actualStart),
        actualEnd: clearActualEnd ? null : (actualEnd ?? this.actualEnd),
      );

  @override
  bool operator ==(Object other) =>
      other is PlannedActual &&
      other.plannedStart == plannedStart &&
      other.plannedEnd == plannedEnd &&
      other.actualStart == actualStart &&
      other.actualEnd == actualEnd;

  @override
  int get hashCode => Object.hash(
        plannedStart,
        plannedEnd,
        actualStart,
        actualEnd,
      );

  @override
  String toString() =>
      'PlannedActual(planned: $plannedStart→$plannedEnd, '
      'actual: $actualStart→$actualEnd)';

  /// A two-bound span is a duration only when both bounds exist and the
  /// end strictly follows the start.
  static Duration? _span(DateTime? start, DateTime? end) {
    if (start == null || end == null) return null;
    if (!end.isAfter(start)) return null;
    return end.difference(start);
  }
}
