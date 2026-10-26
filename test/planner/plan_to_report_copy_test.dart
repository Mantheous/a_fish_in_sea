import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_projection.dart';
import 'package:a_fish_in_sea/planner/view/plan_to_report_copy.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent event(String id, DateTime start, {bool allDay = false}) =>
    PlannerEvent(
      id: id,
      subject: 'Event $id',
      start: start,
      end: start.add(const Duration(hours: 1)),
      allDay: allDay,
    );

ReportedEntry manual(String id, String eventId, DateTime start) =>
    ReportedEntry(
      id: id,
      eventId: eventId,
      title: 'Manual $id',
      start: start,
      end: start.add(const Duration(hours: 1)),
      status: ReportStatus.attended,
      auto: false,
    );

void main() {
  group('isCopyablePlanEvent', () {
    final base = event('e1', DateTime(2026, 9, 4, 9));

    test('plain timed events are copyable', () {
      expect(
        isCopyablePlanEvent(base, reportedEventIds: const {}),
        isTrue,
      );
    });

    test('all-day events are not copyable (lane skips them)', () {
      expect(
        isCopyablePlanEvent(
          event('e2', DateTime(2026, 9, 4), allDay: true),
          reportedEventIds: const {},
        ),
        isFalse,
      );
    });

    test('drafts, reports and node blocks are not copyable', () {
      expect(
        isCopyablePlanEvent(
          event('__draft__', DateTime(2026, 9, 4, 9)),
          reportedEventIds: const {},
        ),
        isFalse,
      );
      expect(
        isCopyablePlanEvent(
          event('report:rep:e1', DateTime(2026, 9, 4, 9)),
          reportedEventIds: const {},
        ),
        isFalse,
      );
      expect(
        isCopyablePlanEvent(
          event('node:abc', DateTime(2026, 9, 4, 9)),
          reportedEventIds: const {},
        ),
        isFalse,
      );
    });

    test('already-reported events are not copyable', () {
      // Covered by a report block.
      expect(
        isCopyablePlanEvent(base, reportedEventIds: {'e1'}),
        isFalse,
      );
      // Recording now.
      expect(
        isCopyablePlanEvent(
          base.copyWith(timerStartedAt: DateTime(2026, 9, 4, 9, 10)),
          reportedEventIds: const {},
        ),
        isFalse,
      );
      // Timer sessions logged.
      expect(
        isCopyablePlanEvent(
          base.copyWith(
            actualStart: DateTime(2026, 9, 4, 9, 5),
            actualEnd: DateTime(2026, 9, 4, 9, 50),
          ),
          reportedEventIds: const {},
        ),
        isFalse,
      );
    });
  });

  group('planEventHasManualReport', () {
    test('finds manual entries by event id', () {
      final entry = manual('rep:e1', 'e1', DateTime(2026, 9, 4, 9));
      expect(
        planEventHasManualReport({'2026-09-04': [entry]}, 'e1'),
        isTrue,
      );
      expect(
        planEventHasManualReport({'2026-09-04': [entry]}, 'missing'),
        isFalse,
      );
      expect(planEventHasManualReport(const {}, 'e1'), isFalse);
    });
  });

  group('buildPlanCopyEntry', () {
    final base = event('e1', DateTime(2026, 9, 4, 9));

    test('seeds the entry from the planned time', () {
      final entry = buildPlanCopyEntry(
        base,
        reportedEventIds: const {},
        reportsByDay: const {},
      );
      expect(entry, isNotNull);
      expect(entry!.id, 'rep:e1');
      expect(entry.eventId, 'e1');
      expect(entry.start, DateTime(2026, 9, 4, 9));
      expect(entry.end, DateTime(2026, 9, 4, 10));
      expect(entry.auto, isFalse);
    });

    test('null when already covered or already copied', () {
      expect(
        buildPlanCopyEntry(
          base,
          reportedEventIds: const {'e1'},
          reportsByDay: const {},
        ),
        isNull,
      );
      expect(
        buildPlanCopyEntry(
          base,
          reportedEventIds: const {},
          reportsByDay: {
            '2026-09-04': [manual('rep:e1', 'e1', DateTime(2026, 9, 4, 9))],
          },
        ),
        isNull,
      );
      expect(
        buildPlanCopyEntry(
          event('e2', DateTime(2026, 9, 4), allDay: true),
          reportedEventIds: const {},
          reportsByDay: const {},
        ),
        isNull,
      );
    });
  });

  group('projection reportedEventIds', () {
    CalendarProjection projection() => CalendarProjection();

    test('tracks timer, live and accepted blocks by event', () {
      final p = projection();
      final planned = event('e1', DateTime(2026, 9, 4, 9));
      final other = event('e2', DateTime(2026, 9, 4, 11));
      p.update(
        events: [planned, other],
        feeds: const <Feed>[],
        visibility: const CalendarVisibilityState(),
        nodes: const <Node>[],
        reports: {
          '2026-09-04': [manual('rep:e1', 'e1', DateTime(2026, 9, 4, 9))],
        },
        showReports: true,
        showReportLanes: true,
        visibleDays: [DateTime(2026, 9, 4)],
        now: DateTime(2026, 9, 4, 12),
      );
      expect(p.reportedEventIds, contains('e1'));
      expect(p.reportedEventIds, isNot(contains('e2')));
      // The accepted block itself is built too.
      expect(
        p.reportById.values.any(
          (b) =>
              b.eventId == 'e1' && b.kind == ReportBlockKind.accepted,
        ),
        isTrue,
      );
    });

    test('clears when reports are hidden', () {
      final p = projection();
      p.update(
        events: [event('e1', DateTime(2026, 9, 4, 9))],
        feeds: const <Feed>[],
        visibility: const CalendarVisibilityState(),
        nodes: const <Node>[],
        reports: {
          '2026-09-04': [manual('rep:e1', 'e1', DateTime(2026, 9, 4, 9))],
        },
        showReports: true,
        showReportLanes: true,
        visibleDays: [DateTime(2026, 9, 4)],
        now: DateTime(2026, 9, 4, 12),
      );
      expect(p.reportedEventIds, isNotEmpty);
      p.update(
        events: [event('e1', DateTime(2026, 9, 4, 9))],
        feeds: const <Feed>[],
        visibility: const CalendarVisibilityState(),
        nodes: const <Node>[],
        reports: const {},
        showReports: false,
        now: DateTime(2026, 9, 4, 12),
      );
      expect(p.reportedEventIds, isEmpty);
    });
  });
}
