import 'package:equatable/equatable.dart';

/// One completed run of a timer.
///
/// A task or event can have many of these — stop the timer, start it again
/// later, and both runs are kept. The older single interval
/// (`actualStart`/`actualEnd`) is still the aggregate span of this list so
/// existing readers keep working; [legacySession] lifts payloads saved
/// before sessions existed into the same shape.
class TimeSession extends Equatable {
  final String id;
  final DateTime start;
  final DateTime end;

  const TimeSession({required this.id, required this.start, required this.end});

  bool get isValid => end.isAfter(start);

  Duration get duration => isValid ? end.difference(start) : Duration.zero;

  TimeSession copyWith({DateTime? start, DateTime? end}) =>
      TimeSession(id: id, start: start ?? this.start, end: end ?? this.end);

  /// Stable id derived from the interval. Mirrored copies of one session
  /// (task + its calendar events) share this id, so reports can count the
  /// work once. Editing a session keeps its original id.
  static String idFor(DateTime start, DateTime end) =>
      'ts:${start.toUtc().microsecondsSinceEpoch}:'
      '${end.toUtc().microsecondsSinceEpoch}';

  /// Lifts the pre-sessions single interval into a session. Returns null for
  /// missing or degenerate intervals.
  static TimeSession? legacySession(DateTime? start, DateTime? end) {
    if (start == null || end == null || !end.isAfter(start)) return null;
    return TimeSession(id: idFor(start, end), start: start, end: end);
  }

  /// Tolerant per-item parser: a malformed entry is skipped instead of
  /// failing the whole payload. Old payloads simply have no `sessions` key.
  static TimeSession? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final start = _date(raw['start']);
    final end = _date(raw['end']);
    if (start == null || end == null || !end.isAfter(start)) return null;
    final rawId = raw['id'];
    final id = rawId is String && rawId.isNotEmpty ? rawId : idFor(start, end);
    return TimeSession(id: id, start: start, end: end);
  }

  static List<TimeSession> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <TimeSession>[];
    final seen = <String>{};
    for (final item in raw) {
      final session = tryParse(item);
      if (session == null || !seen.add(session.id)) continue;
      out.add(session);
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static DateTime? _date(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [id, start, end];
}

/// Adds [session] to [sessions], replacing an entry with the same id so a
/// mirrored / already-present session is updated instead of duplicated.
List<TimeSession> withSession(
  Iterable<TimeSession> sessions,
  TimeSession session,
) {
  final out = <TimeSession>[
    for (final existing in sessions)
      if (existing.id != session.id) existing,
    session,
  ]..sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Removes [sessionId], keeping the rest in start order.
List<TimeSession> withoutSession(
  Iterable<TimeSession> sessions,
  String sessionId,
) => [
  for (final existing in sessions)
    if (existing.id != sessionId) existing,
]..sort((a, b) => a.start.compareTo(b.start));

TimeSession? sessionById(Iterable<TimeSession> sessions, String? id) {
  if (id == null || id.isEmpty) return null;
  for (final session in sessions) {
    if (session.id == id) return session;
  }
  return null;
}

/// Earliest start and latest end across [sessions], i.e. the aggregate span
/// stored in `actualStart`/`actualEnd`. Null when the list is empty.
({DateTime start, DateTime end})? sessionSpan(Iterable<TimeSession> sessions) {
  DateTime? start;
  DateTime? end;
  for (final session in sessions) {
    if (!session.isValid) continue;
    if (start == null || session.start.isBefore(start)) start = session.start;
    if (end == null || session.end.isAfter(end)) end = session.end;
  }
  if (start == null || end == null) return null;
  return (start: start, end: end);
}

/// Total recorded time across [sessions], excluding degenerate intervals.
Duration? totalSessionDuration(Iterable<TimeSession> sessions) {
  Duration? total;
  for (final session in sessions) {
    if (!session.isValid) continue;
    total = (total ?? Duration.zero) + session.duration;
  }
  return total;
}
