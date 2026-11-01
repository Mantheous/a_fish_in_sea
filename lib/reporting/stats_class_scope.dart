import '../nodes/model/node.dart';

/// One display identity for planned blocks, timers and manual reports.
/// Uses explicit membership, class ancestors, then bound import sources.
class StatsClassScope {
  final Map<String, Node> nodes;
  final _aliases = <String, Set<String>>{};
  final _sources = <String, String>{};
  final _labels = <String, String>{};

  StatsClassScope(this.nodes) {
    for (final cls in nodes.values.where((n) => n.isClassNode)) {
      final names = [cls.title, for (final s in cls.classFacet!.sources) s.classLabel,
        for (final n in nodes.values)
          if (n.classNodeId == cls.id) n.classLabel];
      final codes = names.whereType<String>().map(_code).whereType<String>().toList()..sort();
      _labels[cls.id] = codes.isEmpty ? cls.title.trim() : codes.first;
      for (final name in names.whereType<String>()) {
        if (name.trim().isEmpty) continue;
        _aliases.putIfAbsent(_key(name), () => {}).add(cls.id);
      }
      for (final source in cls.classFacet!.sources) {
        _sources[source.key] = cls.id;
      }
    }
  }

  ({String key, String label, String? classLabel}) resolve(Node? owner, String? label, {String? feedId}) {
    final pending = <String>[if (owner != null) owner.id];
    final seen = <String>{};
    String? classId;
    while (pending.isNotEmpty && classId == null) {
      final id = pending.removeAt(0);
      if (!seen.add(id)) continue;
      final node = nodes[id];
      if (node == null) continue;
      if (node.isClassNode) { classId = id; break; }
      if (nodes[node.classNodeId]?.isClassNode == true) {
        classId = node.classNodeId; break;
      }
      pending.addAll(node.parentIds);
    }
    final name = _clean(owner?.classLabel) ?? _clean(label);
    final source = classSourceOfNode(feedId: owner?.feedId ?? feedId,
      classId: owner?.classId, classLabel: name);
    classId ??= source == null ? null : _sources[source.key];
    final matches = name == null ? null : _aliases[_key(name)];
    if (classId == null && matches?.length == 1) classId = matches!.single;
    final display = classId == null ? name : _labels[classId];
    if (display == null || display.isEmpty) {
      return (key: 'unassigned', label: 'No class', classLabel: null);
    }
    final canonical = _code(display) ?? display;
    return (key: _key(canonical), label: canonical, classLabel: canonical);
  }
}

String? _clean(String? value) => value == null || value.trim().isEmpty ? null : value.trim();
String _key(String value) => (_code(value)?.replaceAll(' ', '') ?? value).trim().toLowerCase();
String? _code(String value) {
  final match = RegExp(r'^([A-Za-z]{2,8})\s*(\d{3}[A-Za-z]?)(?:-\d+)?$').firstMatch(value.trim());
  return match == null ? null : '${match[1]!.toUpperCase()} ${match[2]!.toUpperCase()}';
}
