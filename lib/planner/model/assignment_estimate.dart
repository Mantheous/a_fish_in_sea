/// What the app knows about how long one *kind* of assignment takes, and
/// when the user habitually starts it.
///
/// Assignment classification (see `assignment_template.dart`) already
/// groups homework by feed + template key — "MATH 290 | video quiz". This
/// library keeps time data on those groups so the estimate and the
/// habitual start time are learned from the user's own recordings instead
/// of being guessed:
///
/// - [AssignmentEffortSample] is one recorded work session (a homework
///   node that carries `actualStart`/`actualEnd`).
/// - [AssignmentTypeEffort] is the bounded aggregate for one group.
/// - [resolveAssignmentEstimate] turns a node + rule + aggregate into the
///   numbers the schedule-placement flow needs.
///
/// Everything is additive to what is already persisted: a group with no
/// samples has no estimate, and a rule with no explicit estimate falls
/// back to the learned one. Nothing here writes to a feed or rewrites a
/// due date.
///
/// Pure functions only: no Flutter, no cubits, fully unit-testable.
library;

import 'dart:math' as math;

import 'package:equatable/equatable.dart';

import '../../nodes/model/node.dart';
import 'assignment_rule.dart';
import 'assignment_template.dart';

/// Rolling window of remembered samples per type. Bounded so the learned
/// index cannot grow without limit in local storage; a semester of
/// quizzes is 15-25 items, so this holds a whole term plus one.
const int assignmentEffortWindow = 30;

/// Used when nothing is known: a plain one-hour study block.
const int defaultAssignmentMinutes = 60;

/// Minutes since local midnight. Habit data is stored in these units.
const int _minutesPerDay = 24 * 60;

/// One recorded work session on one homework item.
class AssignmentEffortSample extends Equatable {
  final String feedId;
  final String templateKey;
  final String? classLabel;
  final String title;

  /// When the work actually started (local). Null for a node whose report
  /// is missing its start bound — the duration still counts, the habit
  /// data does not.
  final DateTime? actualStart;
  final int minutes;

  const AssignmentEffortSample({
    required this.feedId,
    required this.templateKey,
    required this.title,
    required this.minutes,
    this.classLabel,
    this.actualStart,
  });

  @override
  List<Object?> get props => [
    feedId,
    templateKey,
    classLabel,
    title,
    actualStart,
    minutes,
  ];
}

/// Aggregate time knowledge for one classified assignment type.
class AssignmentTypeEffort extends Equatable {
  final String feedId;
  final String templateKey;
  final String? classLabel;

  /// Shortest member title seen, closest to the human base name.
  final String? displayName;

  /// Number of recorded sessions behind these numbers.
  final int samples;

  /// Summed minutes across [samples] — the honest total, unaffected by the
  /// rolling window.
  final int totalMinutes;

  /// Recent window (see [assignmentEffortWindow]).
  final List<int> minutes;

  /// Local minutes-since-midnight of each windowed sample's start.
  final List<int> startMinutes;

  final int minMinutes;
  final int maxMinutes;
  final DateTime updatedAt;

  const AssignmentTypeEffort({
    required this.feedId,
    required this.templateKey,
    required this.samples,
    required this.totalMinutes,
    required this.minutes,
    required this.startMinutes,
    required this.minMinutes,
    required this.maxMinutes,
    required this.updatedAt,
    this.classLabel,
    this.displayName,
  });

  /// Median of the recent window, or null when nothing was ever recorded.
  int? get medianMinutes => _median(minutes);

  /// Mean of the recent window, rounded. Coarser than the median but still
  /// useful when every session took a different amount of time.
  int? get averageMinutes {
    if (minutes.isEmpty) return null;
    final sum = minutes.fold<int>(0, (a, b) => a + b);
    return (sum / minutes.length).round();
  }

  /// Best single estimate: median first (robust to one bad session), then
  /// the mean.
  int? get estimateMinutes => medianMinutes ?? averageMinutes;

  /// Habitual start as local minutes-since-midnight, or null.
  ///
  /// Circular median: 11:40 PM and 12:10 AM are twenty minutes apart, not
  /// twenty-three hours and twenty minutes.
  int? get preferredStartMinute {
    if (startMinutes.isEmpty) return null;
    final anchor = startMinutes.first;
    final shifted = startMinutes.map((m) {
      var v = m - anchor;
      if (v > _minutesPerDay / 2) v -= _minutesPerDay;
      if (v < -_minutesPerDay / 2) v += _minutesPerDay;
      return v;
    }).toList()..sort();
    final middle = _median(shifted)!;
    final out = (anchor + middle) % _minutesPerDay;
    return out < 0 ? out + _minutesPerDay : out;
  }

  double? get averagePerSession => samples <= 0 ? null : totalMinutes / samples;

  /// Scope key shared with [AssignmentGroup] and [AssignmentRule].
  String get groupKey => '$feedId|$templateKey';

  AssignmentTypeEffort copyWith({
    String? classLabel,
    bool clearClassLabel = false,
    String? displayName,
    int? samples,
    int? totalMinutes,
    List<int>? minutes,
    List<int>? startMinutes,
    int? minMinutes,
    int? maxMinutes,
    DateTime? updatedAt,
  }) => AssignmentTypeEffort(
    feedId: feedId,
    templateKey: templateKey,
    samples: samples ?? this.samples,
    totalMinutes: totalMinutes ?? this.totalMinutes,
    minutes: minutes ?? this.minutes,
    startMinutes: startMinutes ?? this.startMinutes,
    minMinutes: minMinutes ?? this.minMinutes,
    maxMinutes: maxMinutes ?? this.maxMinutes,
    updatedAt: updatedAt ?? this.updatedAt,
    classLabel: clearClassLabel ? null : (classLabel ?? this.classLabel),
    displayName: displayName ?? this.displayName,
  );

  factory AssignmentTypeEffort.fromJson(Map<String, dynamic> json) {
    final feedId = json['feedId'];
    final templateKey = json['templateKey'];
    if (feedId is! String ||
        feedId.isEmpty ||
        templateKey is! String ||
        templateKey.isEmpty) {
      throw const FormatException(
        'AssignmentTypeEffort needs feedId/templateKey',
      );
    }
    DateTime updatedAt = DateTime.fromMillisecondsSinceEpoch(0);
    final rawUpdated = json['updatedAt'];
    if (rawUpdated is String) {
      updatedAt = DateTime.tryParse(rawUpdated) ?? updatedAt;
    }
    final minutes = _clampedIntList(json['minutes'], max: _minutesPerDay * 2);
    final startMinutes = _clampedIntList(
      json['startMinutes'],
      max: _minutesPerDay - 1,
    );
    var samples = (json['samples'] as num?)?.toInt() ?? minutes.length;
    if (samples < 0) samples = 0;
    var totalMinutes =
        (json['totalMinutes'] as num?)?.toInt() ??
        minutes.fold<int>(0, (a, b) => a + b);
    if (totalMinutes < 0) totalMinutes = 0;
    final minMinutes =
        (json['minMinutes'] as num?)?.toInt() ??
        (minutes.isEmpty ? 0 : minutes.reduce(math.min));
    final maxMinutes =
        (json['maxMinutes'] as num?)?.toInt() ??
        (minutes.isEmpty ? 0 : minutes.reduce(math.max));
    return AssignmentTypeEffort(
      feedId: feedId,
      templateKey: templateKey,
      samples: samples,
      totalMinutes: totalMinutes,
      minutes: minutes,
      startMinutes: startMinutes,
      minMinutes: minMinutes,
      maxMinutes: maxMinutes,
      updatedAt: updatedAt,
      classLabel: json['classLabel'] as String?,
      displayName: json['displayName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'feedId': feedId,
    'templateKey': templateKey,
    'classLabel': classLabel,
    'displayName': displayName,
    'samples': samples,
    'totalMinutes': totalMinutes,
    'minutes': minutes,
    'startMinutes': startMinutes,
    'minMinutes': minMinutes,
    'maxMinutes': maxMinutes,
    'updatedAt': updatedAt.toIso8601String(),
  };

  @override
  List<Object?> get props => [
    feedId,
    templateKey,
    classLabel,
    displayName,
    samples,
    totalMinutes,
    minutes,
    startMinutes,
    minMinutes,
    maxMinutes,
  ];
}

List<int> _clampedIntList(Object? raw, {required int max}) {
  if (raw is! List) return const [];
  final out = <int>[];
  for (final item in raw) {
    if (item is num) {
      final v = item.toInt();
      if (v >= 0 && v <= max) out.add(v);
    }
  }
  return out;
}

/// Median of [values], or null when empty. Sorts a copy.
int? _median(List<int> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

/// Build one sample from a homework node's first recorded session.
/// Null when the node is not classified homework or has no report.
AssignmentEffortSample? effortSampleFromNode(Node node) {
  final samples = effortSamplesFromNode(node);
  return samples.isEmpty ? null : samples.first;
}

/// One sample per recorded run: several short sittings should teach the
/// estimate the same way one long sitting does.
List<AssignmentEffortSample> effortSamplesFromNode(Node node) {
  if (!node.isHomework) return const [];
  final scope = node.feedId ?? node.classId;
  if (scope == null || scope.isEmpty) return const [];
  final key = assignmentTemplateKey(node.title);
  if (key.isEmpty) return const [];
  final out = <AssignmentEffortSample>[];
  for (final session in node.recordedSessions) {
    final minutes = session.duration.inMinutes;
    // A 0-minute report is a stray stop/start, not a study session.
    if (!session.isValid || minutes <= 0) continue;
    out.add(
      AssignmentEffortSample(
        feedId: scope,
        templateKey: key,
        classLabel: node.classLabel,
        title: node.title,
        actualStart: session.start,
        minutes: minutes,
      ),
    );
  }
  return out;
}

/// Every recorded session across [nodes], oldest first.
List<AssignmentEffortSample> collectEffortSamples(List<Node> nodes) {
  final out = <AssignmentEffortSample>[];
  for (final node in nodes) {
    out.addAll(effortSamplesFromNode(node));
  }
  out.sort((a, b) {
    final at = a.actualStart;
    final bt = b.actualStart;
    if (at == null || bt == null) return 0;
    return at.compareTo(bt);
  });
  return out;
}

/// Fold every recorded session in [nodes] into the learned index.
///
/// Idempotent: rebuilding from the same node list yields the same index,
/// so this can run on every app start without drifting. Groups that saw
/// no sessions are dropped only if [existing] is not supplied — passing
/// the stored index keeps quiet groups ("you usually take 45m on these")
/// alive through a week where the user recorded nothing.
List<AssignmentTypeEffort> learnEffortIndex(
  List<Node> nodes, {
  List<AssignmentTypeEffort> existing = const [],
  DateTime? now,
}) {
  final grouped = <String, List<AssignmentEffortSample>>{};
  for (final sample in collectEffortSamples(nodes)) {
    grouped
        .putIfAbsent('${sample.feedId}|${sample.templateKey}', () => [])
        .add(sample);
  }
  final at = now ?? DateTime.now();
  final out = <AssignmentTypeEffort>[];
  for (final entry in grouped.entries) {
    final members = entry.value;
    final priorIndex = {for (final e in existing) e.groupKey: e};
    final prior = priorIndex[entry.key];
    final window = members.length > assignmentEffortWindow
        ? members.sublist(members.length - assignmentEffortWindow)
        : members;
    final recentMinutes = [for (final m in window) m.minutes];
    final recentStarts = <int>[];
    for (final m in window) {
      final s = m.actualStart;
      if (s != null) recentStarts.add(s.hour * 60 + s.minute);
    }
    final allMinutes = [for (final m in members) m.minutes];
    var displayName = prior?.displayName;
    for (final m in members) {
      if (displayName == null ||
          m.title.trim().length < displayName.trim().length) {
        displayName = m.title.trim();
      }
    }
    out.add(
      AssignmentTypeEffort(
        feedId: members.first.feedId,
        templateKey: members.first.templateKey,
        classLabel: members.first.classLabel ?? prior?.classLabel,
        displayName: displayName,
        samples: allMinutes.length,
        totalMinutes: allMinutes.fold<int>(0, (a, b) => a + b),
        minutes: recentMinutes,
        startMinutes: recentStarts,
        minMinutes: allMinutes.reduce(math.min),
        maxMinutes: allMinutes.reduce(math.max),
        updatedAt: at,
      ),
    );
  }
  for (final e in existing) {
    if (!out.any((o) => o.groupKey == e.groupKey)) out.add(e);
  }
  out.sort((a, b) {
    final byClass = (a.classLabel ?? '').compareTo(b.classLabel ?? '');
    if (byClass != 0) return byClass;
    return b.samples.compareTo(a.samples);
  });
  return out;
}

/// Learned aggregate for one homework item, or null.
AssignmentTypeEffort? effortFor({
  required String? feedId,
  required String? classId,
  required String title,
  required List<AssignmentTypeEffort> efforts,
}) {
  final scope = feedId ?? classId;
  if (scope == null || scope.isEmpty) return null;
  final key = assignmentTemplateKey(title);
  if (key.isEmpty) return null;
  for (final e in efforts) {
    if (e.feedId == scope && e.templateKey == key) return e;
  }
  return null;
}

/// Where an estimate came from, for the "why this number" hint.
enum AssignmentEstimateSource {
  /// The user typed a number on the repeating-assignment rule.
  rule,

  /// Learned from this type's recorded sessions.
  learned,

  /// The node's own time target (`effort` facet).
  effort,

  /// No knowledge at all: [defaultAssignmentMinutes].
  fallback,
}

/// The numbers the schedule-placement flow needs for one assignment.
class AssignmentEstimate extends Equatable {
  /// Expected minutes of work.
  final int minutes;

  /// Habitual start as local minutes-since-midnight, or null when there is
  /// no habit to follow yet.
  final int? preferredStartMinute;
  final AssignmentEstimateSource source;

  /// The classified type behind this estimate, when there is one.
  final AssignmentTypeEffort? effort;

  const AssignmentEstimate({
    required this.minutes,
    required this.source,
    this.preferredStartMinute,
    this.effort,
  });

  @override
  List<Object?> get props => [
    minutes,
    preferredStartMinute,
    source,
    effort?.groupKey,
  ];
}

/// Resolve the estimate for one node.
///
/// Precedence: an explicit number on the user's repeating-assignment rule,
/// then the learned aggregate for that classified type, then the node's
/// own time target, then a plain hour. The habitual start time is only
/// ever learned — never guessed — so an unclassified one-off assignment
/// still lands on the default slot instead of a made-up habit.
AssignmentEstimate resolveAssignmentEstimate({
  required Node node,
  List<AssignmentRule> rules = const [],
  List<AssignmentTypeEffort> efforts = const [],
  int fallbackMinutes = defaultAssignmentMinutes,
}) {
  final learned = effortFor(
    feedId: node.feedId,
    classId: node.classId,
    title: node.title,
    efforts: efforts,
  );
  final ruleMinutes = assignmentRuleFor(
    rules,
    feedId: node.feedId,
    classId: node.classId,
    title: node.title,
  )?.estimateMinutes;
  if (ruleMinutes != null && ruleMinutes > 0) {
    return AssignmentEstimate(
      minutes: ruleMinutes,
      source: AssignmentEstimateSource.rule,
      preferredStartMinute: learned?.preferredStartMinute,
      effort: learned,
    );
  }
  final learnedMinutes = learned?.estimateMinutes;
  if (learnedMinutes != null && learnedMinutes > 0) {
    return AssignmentEstimate(
      minutes: learnedMinutes,
      source: AssignmentEstimateSource.learned,
      preferredStartMinute: learned!.preferredStartMinute,
      effort: learned,
    );
  }
  // A time-target goal that is also homework (rare, but allowed) still
  // knows its own target — that is the best estimate available.
  final effortTarget = node.effort?.targetMinutes;
  if (effortTarget != null && effortTarget > 0) {
    return AssignmentEstimate(
      minutes: effortTarget,
      source: AssignmentEstimateSource.effort,
      preferredStartMinute: learned?.preferredStartMinute,
      effort: learned,
    );
  }
  return AssignmentEstimate(
    minutes: fallbackMinutes,
    source: AssignmentEstimateSource.fallback,
    preferredStartMinute: learned?.preferredStartMinute,
    effort: learned,
  );
}

/// Snap a local minute-of-day to a multiple of [snap] (>= 1).
int snapMinuteOfDay(int minute, int snap) {
  final step = snap <= 0 ? 1 : snap;
  final rounded = ((minute + step ~/ 2) ~/ step) * step;
  // Clamp, never wrap: a time snapped past midnight stays at end-of-day
  // instead of becoming 00:00 (start of the day, in the past).
  return rounded.clamp(0, _minutesPerDay);
}

/// "45m" / "1h 30m" / "2h".
String describeMinutes(int minutes) {
  if (minutes <= 0) return '0m';
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  if (mins == 0) return '${hours}h';
  return '${hours}h ${mins}m';
}

/// "around 7 PM" / "around 9:30 AM".
String describeTimeOfDay(int minute) {
  final m = minute % _minutesPerDay;
  final hour24 = m ~/ 60;
  final mins = m % 60;
  final suffix = hour24 < 12 ? 'AM' : 'PM';
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  if (mins == 0) return 'around $hour12 $suffix';
  return 'around $hour12:${mins.toString().padLeft(2, '0')} $suffix';
}
