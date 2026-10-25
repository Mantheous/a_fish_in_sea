import 'package:equatable/equatable.dart';

/// One feed source that reports into a class.
///
/// Canvas usually gives one feed per course, so [classLabel] is null and
/// [feedId] alone identifies the class. Learning Suite merges every course
/// into one feed, so the class identity is the pair
/// ([feedId], [classLabel]). Binding a list of these lets one class node
/// own both kinds without inventing a second class concept.
class ClassSource extends Equatable {
  final String feedId;
  final String? classLabel;

  const ClassSource({required this.feedId, this.classLabel});

  /// Stable comparison key. Labels are trimmed and case-folded so a feed
  /// that changes capitalization does not split the class.
  String get key => sourceKey(feedId, classLabel);

  factory ClassSource.fromJson(Map<String, dynamic> json) => ClassSource(
    feedId: (json['feedId'] as String?)?.trim() ?? '',
    classLabel: _cleanLabel(json['classLabel']),
  );

  Map<String, dynamic> toJson() => {'feedId': feedId, 'classLabel': classLabel};

  @override
  List<Object?> get props => [feedId, classLabel];
}

/// Class-node facet: the durable identity of a course.
///
/// A class node is a regular [Node] carrying this facet. Its subtree (plus
/// any task whose [Node.classNodeId] points at it) is the class scope that
/// metrics evaluate. Sources are bindings, not membership: removing a feed
/// leaves the class and its manual work intact.
class ClassFacet extends Equatable {
  final List<ClassSource> sources;

  const ClassFacet({this.sources = const []});

  ClassFacet copyWith({List<ClassSource>? sources}) =>
      ClassFacet(sources: sources ?? this.sources);

  /// Whether imported homework [node] belongs to this class by provenance.
  bool matchesNodeSource(ClassSource? source) {
    if (source == null) return false;
    final wanted = source.key;
    for (final bound in sources) {
      if (bound.key == wanted) return true;
    }
    return false;
  }

  factory ClassFacet.fromJson(Map<String, dynamic> json) {
    final raw = json['sources'];
    final out = <ClassSource>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          final source = ClassSource.fromJson(Map<String, dynamic>.from(item));
          if (source.feedId.isEmpty) continue;
          if (out.any((s) => s.key == source.key)) continue;
          out.add(source);
        } catch (_) {
          // Per-source tolerance: one bad binding never drops the class.
        }
        if (out.length >= 32) break;
      }
    }
    return ClassFacet(sources: out);
  }

  Map<String, dynamic> toJson() => {
    'sources': [for (final source in sources) source.toJson()],
  };

  @override
  List<Object?> get props => [
    // Sorted for stable equality across restores.
    [...sources]..sort((a, b) => a.key.compareTo(b.key)),
  ];
}

/// The source key an imported homework node came from, or null for manual
/// work. `classId` is the fallback for older payloads that predate `feedId`.
ClassSource? classSourceOfNode({
  String? feedId,
  String? classId,
  String? classLabel,
}) {
  final id = (feedId ?? classId)?.trim();
  if (id == null || id.isEmpty) return null;
  return ClassSource(feedId: id, classLabel: _cleanLabel(classLabel));
}

String sourceKey(String feedId, String? classLabel) {
  final label = _cleanLabel(classLabel)?.toLowerCase() ?? '';
  return '${feedId.trim()}\u0000$label';
}

String? _cleanLabel(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}
