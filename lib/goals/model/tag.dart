import 'package:equatable/equatable.dart';

enum TagReporting { manual, timeAuto, financialAuto }

class GoalTag extends Equatable {
  final String id;
  final String name;
  final String? parentId;
  final TagReporting reporting;
  final String? placeId;
  final String? category;

  const GoalTag({
    required this.id,
    required this.name,
    this.parentId,
    this.reporting = TagReporting.manual,
    this.placeId,
    this.category,
  });

  GoalTag copyWith({
    String? name,
    String? parentId,
    bool clearParent = false,
    TagReporting? reporting,
    String? placeId,
    bool clearPlace = false,
    String? category,
    bool clearCategory = false,
  }) =>
      GoalTag(
        id: id,
        name: name ?? this.name,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        reporting: reporting ?? this.reporting,
        placeId: clearPlace ? null : (placeId ?? this.placeId),
        category: clearCategory ? null : (category ?? this.category),
      );

  factory GoalTag.fromJson(Map<String, dynamic> json) => GoalTag(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parentId'] as String?,
        reporting: TagReporting.values.firstWhere(
          (e) => e.name == json['reporting'],
          orElse: () => TagReporting.manual,
        ),
        placeId: json['placeId'] as String?,
        category: json['category'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'reporting': reporting.name,
        'placeId': placeId,
        'category': category,
      };

  @override
  List<Object?> get props => [id, name, parentId, reporting, placeId, category];
}

Set<String> tagSubtreeIds(String rootId, List<GoalTag> all) {
  final byParent = <String?, List<GoalTag>>{};
  for (final t in all) {
    byParent.putIfAbsent(t.parentId, () => []).add(t);
  }
  final out = <String>{rootId};
  final queue = [rootId];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final child in byParent[current] ?? const <GoalTag>[]) {
      if (out.add(child.id)) queue.add(child.id);
    }
  }
  return out;
}

Set<String> goalSubtreeTagIds(List<String> tagIds, List<GoalTag> all) {
  final out = <String>{};
  for (final id in tagIds) {
    out.addAll(tagSubtreeIds(id, all));
  }
  return out;
}

List<String> _tagIdsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final item in raw) {
    if (item is String && item.isNotEmpty) out.add(item);
  }
  return out;
}

List<String> parseTagIds(Object? raw) => _tagIdsFromJson(raw);
