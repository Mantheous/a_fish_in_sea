import '../model/node.dart';

/// Deleting/unmarking a calendar event detaches a goal occurrence instead
/// of deleting its goal history. Plain event-only backing nodes retain the
/// previous removal behavior. Also remember the opt-out on the template.
List<Node> detachEventNodes(List<Node> all, Set<String> eventIds) {
  final detached = <String, Node>{};
  final removed = <String>{};
  final exclusions = <String, Set<String>>{};
  final links = <String, NodeCalendarLink>{};
  for (final node in all) {
    final matched = {
      node.sourceEventId,
      node.calendarEventId,
    }.whereType<String>().where(eventIds.contains).toSet();
    if (matched.isEmpty) continue;
    if (!node.isInstance || node.calendarLink == null) {
      removed.add(node.id);
      continue;
    }
    (exclusions[node.instanceOfId!] ??= {}).addAll(matched);
    links[node.instanceOfId!] = node.calendarLink!;
    detached[node.id] = node.copyWith(
      clearSourceEvent: true,
      clearCalendarEvent: true,
      clearFeed: true,
      clearClassId: true,
      clearClassLabel: true,
      schedule: node.schedule?.copyWith(clearStart: true, clearEnd: true),
    );
  }
  if (removed.isEmpty && detached.isEmpty) return all;
  return [
    for (final node in all)
      if (!removed.contains(node.id))
        if (exclusions[node.id] case final Set<String> ids)
          node.copyWith(
            calendarLink: NodeCalendarLink(
              seriesKey: (node.calendarLink ?? links[node.id]!).seriesKey,
              isEnabled: node.calendarLink?.isEnabled ?? true,
              records: node.calendarLink?.records ?? const {},
              excludedEventIds: {
                ...?node.calendarLink?.excludedEventIds,
                ...ids,
              },
            ),
          )
        else
          detached[node.id] ?? node,
  ];
}
