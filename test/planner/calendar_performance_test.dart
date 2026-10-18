import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_data_source.dart';
import 'package:a_fish_in_sea/planner/view/calendar_projection.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

final _day = DateTime(2026, 10, 18, 9);
PlannerEvent _event(String id, {String? feedId}) => PlannerEvent(
  id: id,
  subject: id,
  start: _day,
  end: _day.add(const Duration(hours: 1)),
  feedId: feedId,
);

class _CountedEvent extends PlannerEvent {
  static int comparisons = 0;
  _CountedEvent(String id)
    : super(
        id: id,
        subject: id,
        start: _day,
        end: _day.add(const Duration(hours: 1)),
      );

  @override
  bool operator ==(Object other) {
    comparisons++;
    return super == other;
  }

  @override
  // ignore: unnecessary_overrides
  int get hashCode => super.hashCode;
}

void main() {
  test('2730 custom appointment lookups avoid quadratic equality scans', () {
    final events = List.generate(2730, (i) => _CountedEvent('$i'));
    final source = PlannerCalendarDataSource(events, const {});
    final baselineWatch = Stopwatch()..start();
    _CountedEvent.comparisons = 0;
    for (var i = 0; i < events.length; i++) {
      expect(events.indexOf(events[i]), i);
    }
    baselineWatch.stop();
    final baselineComparisons = _CountedEvent.comparisons;
    final indexedWatch = Stopwatch()..start();
    _CountedEvent.comparisons = 0;
    for (var i = 0; i < events.length; i++) {
      expect(source.appointments!.indexOf(events[i]), i);
    }
    indexedWatch.stop();
    expect(baselineComparisons, greaterThan(3700000));
    expect(_CountedEvent.comparisons, lessThanOrEqualTo(events.length));
    // Diagnostic timing only: equality counts, not wall-clock noise, gate.
    // ignore: avoid_print
    print(
      '2730 lookups: list ${baselineWatch.elapsedMicroseconds}us / '
      '$baselineComparisons comparisons; indexed '
      '${indexedWatch.elapsedMicroseconds}us / '
      '${_CountedEvent.comparisons} comparisons',
    );
    expect(source.appointments!.indexOf(events.first, 1), -1);
    final plain = _event('plain');
    final plainSource = PlannerCalendarDataSource([plain], const {});
    expect(plainSource.appointments!.indexOf(plain.copyWith()), 0);
    plainSource.dispose();
    source.dispose();
  });

  test('native drag list mutations rebuild lookup without mutating state', () {
    final events = [_event('one'), _event('two')];
    final source = PlannerCalendarDataSource(events, const {});
    final appointments = source.appointments!;
    expect(appointments.indexOf(events.last), 1);
    appointments.remove(events.first);
    final moved = events.first.copyWith(subject: 'Moved');
    appointments.add(moved);
    expect(appointments.indexOf(moved), 1);
    expect(source.getSubject(0), 'two');
    expect(source.getSubject(1), 'Moved');
    expect(events.map((e) => e.subject), ['one', 'two']);
    source.dispose();
  });

  test('one edit removes and adds only the changed event', () {
    final events = List.generate(1000, (i) => _event('$i'));
    final source = PlannerCalendarDataSource(events, const {});
    final notifications = <(CalendarDataSourceAction, List<dynamic>)>[];
    source.addListener((action, data) => notifications.add((action, data)));
    final moved = events[500].copyWith(
      start: _day.add(const Duration(hours: 2)),
    );
    final next = [...events]..[500] = moved;
    source.update(next, const {});
    expect(notifications.map((e) => e.$1), [
      CalendarDataSourceAction.remove,
      CalendarDataSourceAction.add,
    ]);
    expect(notifications.first.$2, [events[500]]);
    expect(notifications.last.$2, [moved]);
    expect(source.getStartTime(500), moved.start);
    notifications.clear();
    source.update([...next], const {});
    expect(notifications, isEmpty);
    source.dispose();
  });

  test('colors and bulk imports refresh internal appointment copies', () {
    final events = List.generate(100, (i) => _event('$i'));
    final source = PlannerCalendarDataSource(events, const {});
    final actions = <CalendarDataSourceAction>[];
    source.addListener((action, _) => actions.add(action));
    source.update(events, const {}, {'0': Colors.red});
    expect(actions, [CalendarDataSourceAction.reset]);
    expect(source.getColor(0), Colors.red);
    actions.clear();
    source.update(
      [for (final event in events) event.copyWith(subject: 'new')],
      const {},
      {'0': Colors.red},
    );
    expect(actions, [CalendarDataSourceAction.reset]);
    source.dispose();
  });

  test(
    'draft and selection frames reuse node blocks and report projections',
    () {
      final projection = CalendarProjection();
      final events = [_event('event')];
      final nodes = [
        Node(
          id: 'node',
          createdAt: _day,
          title: 'Node',
          schedule: ScheduleFacet(
            start: _day,
            end: _day.add(const Duration(hours: 1)),
          ),
        ),
      ];
      final reports = <String, List<ReportedEntry>>{
        '2026-10-18': [
          ReportedEntry(
            id: 'manual',
            title: 'Reported',
            start: _day,
            end: _day.add(const Duration(hours: 1)),
            status: ReportStatus.attended,
            auto: false,
          ),
        ],
      };
      void update({PlannerEvent? draft}) => projection.update(
        events: events,
        feeds: const [],
        visibility: const CalendarVisibilityState(),
        nodes: nodes,
        reports: reports,
        showReports: true,
        now: _day,
        draft: draft,
      );
      update();
      final firstShown = projection.shown;
      final firstColors = projection.colorById;
      final firstNodes = projection.nodeById;
      final report = projection.reportById;
      final block = firstShown.singleWhere((event) => event.id == 'node:node');
      update();
      expect(identical(projection.shown, firstShown), isTrue);
      expect(identical(projection.colorById, firstColors), isTrue);
      update(draft: _event('draft'));
      expect(identical(projection.nodeById, firstNodes), isTrue);
      expect(identical(projection.reportById, report), isTrue);
      expect(identical(projection.shown.last, block), isTrue);
      expect(projection.shown.any((event) => event.id == 'draft'), isTrue);
    },
  );

  test('visibility, feed enablement, node edits and preview invalidation', () {
    final projection = CalendarProjection();
    final event = _event('personal');
    final imported = _event('imported', feedId: 'feed');
    final unknown = _event('unknown', feedId: 'deleted');
    final events = [event, imported, unknown];
    final nodes = [
      Node(
        id: 'node',
        createdAt: _day,
        title: 'Node',
        schedule: ScheduleFacet(
          start: _day,
          end: _day.add(const Duration(hours: 1)),
        ),
      ),
    ];
    void update({
      bool enabled = true,
      CalendarVisibilityState visibility = const CalendarVisibilityState(),
      List<Node>? nextNodes,
      PlannerEvent? edit,
      PlannerEvent? resize,
    }) {
      projection.update(
        events: events,
        feeds: [Feed(id: 'feed', name: 'Feed', url: '', enabled: enabled)],
        visibility: visibility,
        nodes: nextNodes ?? nodes,
        reports: const {},
        showReports: false,
        now: _day,
        edit: edit,
        resize: resize,
      );
    }

    update(enabled: false);
    expect(projection.shown.map((e) => e.id), [
      'personal',
      'unknown',
      'node:node',
    ]);
    update(visibility: const CalendarVisibilityState(hiddenIds: {'personal'}));
    expect(projection.shown.map((e) => e.id), [
      'imported',
      'unknown',
      'node:node',
    ]);
    final edited = event.copyWith(subject: 'Edited');
    final resized = event.copyWith(end: _day.add(const Duration(hours: 3)));
    update(edit: edited, resize: resized);
    expect(projection.shown.first, resized);
    update(edit: edited);
    expect(projection.shown.first, edited);
    update(nextNodes: [nodes.single.copyWith(title: 'Updated')]);
    expect(projection.shown.first, event);
    expect(projection.shown.last.subject, 'Updated');
  });

  test(
    'live reports refresh after 15 seconds and reporting toggles safely',
    () {
      final projection = CalendarProjection();
      final events = [_event('running').copyWith(timerStartedAt: _day)];
      void update(int seconds, {bool show = true}) => projection.update(
        events: events,
        feeds: const [],
        visibility: const CalendarVisibilityState(),
        nodes: const [],
        reports: const {},
        showReports: show,
        now: _day.add(Duration(seconds: seconds)),
      );
      update(120);
      final report = projection.reportById;
      update(130);
      expect(identical(projection.reportById, report), isTrue);
      update(136);
      expect(
        projection.reportById.values.single.end,
        _day.add(const Duration(seconds: 136)),
      );
      update(137, show: false);
      expect(projection.shown, events);
      update(138);
      expect(projection.shown.length, 2);
    },
  );
}
