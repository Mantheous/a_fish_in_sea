import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/parent_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Node node(
    String id,
    String title, {
    List<String> parents = const [],
    String? instanceOf,
    NodeRecurrence? recurrence,
    NodeCalendarLink? calendarLink,
    String? calendarEventId,
    DateTime? createdAt,
    DateTime? completedAt,
  }) => Node(
    id: id,
    title: title,
    parentIds: parents,
    instanceOfId: instanceOf,
    recurrence: recurrence,
    calendarLink: calendarLink,
    calendarEventId: calendarEventId,
    createdAt: createdAt ?? DateTime(2026, 1, 1),
    completedAt: completedAt,
  );

  Node occurrence(
    String id, {
    String template = 'temple',
    String title = 'Attend the temple',
    DateTime? createdAt,
    DateTime? completedAt,
    NodeCalendarLink? calendarLink,
  }) => node(
    id,
    title,
    parents: [template],
    instanceOf: template,
    calendarLink: calendarLink,
    createdAt: createdAt,
    completedAt: completedAt,
  );

  test('collapses a repeating series into its template', () {
    final candidates = parentCandidates([
      node(
        'temple',
        'Attend the temple',
        recurrence: const NodeRecurrence(frequency: TimeScale.weekly),
      ),
      for (var i = 0; i < 6; i++) occurrence('temple-$i'),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.node.id, 'temple');
    expect(candidates.single.occurrences, 6);
  });

  test('orphaned occurrences are not offered as parents', () {
    // An instance may never be a parent, so with its template missing there
    // is no legal row left.
    expect(parentCandidates([occurrence('orphan')]), isEmpty);
  });

  test('a non-goal template still earns a row for its goal occurrences', () {
    final candidates = parentCandidates([
      node(
        'temple',
        'Attend the temple',
        calendarEventId: 'event-1',
        recurrence: const NodeRecurrence(frequency: TimeScale.weekly),
      ),
      occurrence(
        'occurrence',
        calendarLink: const NodeCalendarLink(seriesKey: 'series-1'),
      ),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.node.id, 'temple');
    expect(candidates.single.occurrences, 1);
  });

  test('orders by the freshest activity anywhere in the series', () {
    final candidates = parentCandidates([
      node(
        'temple',
        'Attend the temple',
        createdAt: DateTime(2025, 1, 1),
        recurrence: const NodeRecurrence(frequency: TimeScale.weekly),
      ),
      occurrence(
        'temple-now',
        createdAt: DateTime(2026, 1, 1),
        completedAt: DateTime(2026, 10, 24),
      ),
      node('newer', 'Newer goal', createdAt: DateTime(2026, 5, 1)),
    ]);

    expect([for (final c in candidates) c.node.id], ['temple', 'newer']);
  });

  test('keeps the edited node and its descendants out', () {
    final candidates = parentCandidates([
      node('self', 'Self'),
      node('kid', 'Child', parents: const ['self']),
      node('other', 'Other goal'),
    ], excludeId: 'self');

    expect([for (final c in candidates) c.node.id], ['other']);
  });

  test('two templates for one calendar series collapse into one row', () {
    final candidates = parentCandidates([
      node(
        'old-template',
        'Attend the temple',
        createdAt: DateTime(2026, 1, 1),
        calendarLink: const NodeCalendarLink(seriesKey: 'series-1'),
      ),
      node(
        'duplicate-template',
        'Attend the temple',
        createdAt: DateTime(2026, 2, 1),
        calendarLink: const NodeCalendarLink(seriesKey: 'series-1'),
      ),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.node.title, 'Attend the temple');
    expect(candidates.single.node.id, 'old-template');
  });
}
