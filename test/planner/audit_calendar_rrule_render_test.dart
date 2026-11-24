import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_data_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

/// Rendering-boundary regression for the blank-screen RRULE incident.
///
/// The Home fix (CalendarCubit.occurrencesOf) guards the app's own recurrence
/// expansion, but the Calendar page hands the raw event to SfCalendar, which
/// expands `getRecurrenceRule` internally. A valid RFC 5545 rule that
/// Syncfusion cannot expand (FREQ=WEEKLY without BYDAY) must not blank the
/// calendar widget, and valid rules must still expand normally.
void main() {
  final start = DateTime(2026, 11, 24, 9);

  PlannerEvent event(String id, String rule, [DateTime? at]) {
    final eventStart = at ?? start;
    return PlannerEvent(
      id: id,
      subject: 'Recurring',
      start: eventStart,
      end: eventStart.add(const Duration(hours: 1)),
      recurrenceRule: rule,
    );
  }

  PlannerCalendarDataSource sourceFor(String rule) =>
      PlannerCalendarDataSource([event('series', rule)], const {});

  Future<void> pumpCalendar(
    WidgetTester tester,
    PlannerCalendarDataSource source, {
    void Function(CalendarAppointmentDetails details)? onBuild,
  }) async {
    final controller = CalendarController()..displayDate = start;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SfCalendar(
            view: CalendarView.week,
            controller: controller,
            dataSource: source,
            appointmentBuilder: onBuild == null
                ? null
                : (context, details) {
                    onBuild(details);
                    return const SizedBox.shrink();
                  },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('calendar widget survives an unsupported weekly RRULE', (
    tester,
  ) async {
    final source = sourceFor('FREQ=WEEKLY');
    await pumpCalendar(tester, source);
    expect(
      tester.takeException(),
      isNull,
      reason: 'one unsupported imported rule must not blank the calendar',
    );
    source.dispose();
  });

  testWidgets('unsupported rule still shows the original occurrence', (
    tester,
  ) async {
    final built = <CalendarAppointmentDetails>[];
    final source = sourceFor('FREQ=WEEKLY');
    await pumpCalendar(tester, source, onBuild: built.add);
    expect(tester.takeException(), isNull);
    expect(built, isNotEmpty, reason: 'the event must remain visible');
    expect(
      built.expand((d) => d.appointments).map((a) => (a as PlannerEvent).start),
      contains(start),
      reason: 'its original start should render as a single appointment',
    );
    source.dispose();
  });

  testWidgets('an empty first BYDAY clause is guarded even with a valid duplicate', (
    tester,
  ) async {
    // Syncfusion's _findWeeklyRule stops at the first BYDAY clause. The empty
    // first clause reaches the weekly expander and asserts; the later valid
    // `BYDAY=MO` is never consulted, so it must not rescue the rule.
    const rule = 'FREQ=WEEKLY;BYDAY=;BYDAY=MO';
    final source = sourceFor(rule);
    await pumpCalendar(tester, source);
    expect(tester.takeException(), isNull);
    expect(source.getRecurrenceRule(0), isEmpty);
    expect(source.events.single.recurrenceRule, rule);
    source.dispose();
  });

  testWidgets('an invalid first BYDAY clause is guarded with a valid duplicate', (
    tester,
  ) async {
    const rule = 'FREQ=WEEKLY;BYDAY=XX;BYDAY=MO';
    final source = sourceFor(rule);
    await pumpCalendar(tester, source);
    expect(tester.takeException(), isNull);
    expect(source.getRecurrenceRule(0), isEmpty);
    source.dispose();
  });

  test('valid daily rule still expands through the data source', () {
    const rule = 'FREQ=DAILY;COUNT=3';
    final source = sourceFor(rule);
    final handedToWidget = source.getRecurrenceRule(0);
    expect(handedToWidget, rule);
    final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
      handedToWidget,
      start,
      specificStartDate: DateTime(2026, 11, 24),
      specificEndDate: DateTime(2026, 11, 30),
    );
    expect(occurrences.length, 3);
    source.dispose();
  });

  test('valid weekly rule still expands through the data source', () {
    const rule = 'FREQ=WEEKLY;BYDAY=TU,TH;COUNT=4';
    final source = sourceFor(rule);
    final handedToWidget = source.getRecurrenceRule(0);
    expect(handedToWidget, rule);
    final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
      handedToWidget,
      start,
      specificStartDate: DateTime(2026, 11, 24),
      specificEndDate: DateTime(2026, 12, 8),
    );
    expect(occurrences.length, 4);
    source.dispose();
  });

  // Rules below are valid RFC 5545 / Syncfusion-supported grammar that the
  // app's editor subset (RepeatConfig.tryParse) cannot represent. They must
  // reach the widget verbatim and still expand through the real engine.
  void expectVerbatimAndExpands(
    String rule,
    DateTime recurrenceStart,
    List<DateTime> expected,
  ) {
    final source = PlannerCalendarDataSource(
      [event('imported', rule, recurrenceStart)],
      const {},
    );
    final handedToWidget = source.getRecurrenceRule(0);
    expect(
      handedToWidget,
      rule,
      reason: 'a Syncfusion-supported rule must not be stripped',
    );
    final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
      handedToWidget,
      recurrenceStart,
      specificStartDate: DateTime(2026, 11, 1),
      specificEndDate: DateTime(2027, 5, 1),
    );
    expect(occurrences, expected);
    source.dispose();
  }

  test('every-N-day rule survives the render boundary', () {
    final day = DateTime(2026, 11, 2, 9);
    expectVerbatimAndExpands(
      'FREQ=DAILY;INTERVAL=3;COUNT=3',
      day,
      [
        DateTime(2026, 11, 2, 9),
        DateTime(2026, 11, 5, 9),
        DateTime(2026, 11, 8, 9),
      ],
    );
  });

  test('INTERVAL=3 weekly rule survives the render boundary', () {
    final monday = DateTime(2026, 11, 2, 9);
    expectVerbatimAndExpands(
      'FREQ=WEEKLY;INTERVAL=3;BYDAY=MO,TH;COUNT=4',
      monday,
      [
        DateTime(2026, 11, 2, 9),
        DateTime(2026, 11, 5, 9),
        DateTime(2026, 11, 23, 9),
        DateTime(2026, 11, 26, 9),
      ],
    );
  });

  // Syncfusion 29.2.11 expands these two imported shapes with incorrect RFC
  // 5545 semantics: it ignores the ordinal prefix in `1MO` and keeps only the
  // first comma-delimited BYDAY token (recurrence_helper.dart:1966-1970).
  // They are passthrough-only compatibility checks — no engine dates are
  // asserted, so the suite does not codify the library's wrong expansion.
  test('monthly ordinal BYDAY + BYSETPOS passes through verbatim', () {
    const rule = 'FREQ=MONTHLY;BYDAY=1MO;BYSETPOS=1;COUNT=3';
    final source = sourceFor(rule);
    expect(source.getRecurrenceRule(0), rule);
    expect(source.events.single.recurrenceRule, rule);
    source.dispose();
  });

  test('monthly multi-weekday BYDAY + BYSETPOS passes through verbatim', () {
    const rule = 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1;COUNT=3';
    final source = sourceFor(rule);
    expect(source.getRecurrenceRule(0), rule);
    expect(source.events.single.recurrenceRule, rule);
    source.dispose();
  });

  test('engine-supported monthly BYDAY=MO + BYSETPOS expands correctly', () {
    final monday = DateTime(2026, 11, 2, 9);
    expectVerbatimAndExpands(
      'FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=3',
      monday,
      [
        DateTime(2026, 11, 2, 9),
        DateTime(2026, 12, 7, 9),
        DateTime(2027, 1, 4, 9),
      ],
    );
  });

  testWidgets('weekly rule without BYDAY is guarded even with COUNT', (
    tester,
  ) async {
    const rule = 'FREQ=WEEKLY;COUNT=3';
    final source = sourceFor(rule);
    expect(source.getRecurrenceRule(0), isEmpty);
    expect(source.events.single.recurrenceRule, rule);
    await pumpCalendar(tester, source);
    expect(tester.takeException(), isNull);
    source.dispose();
  });

  testWidgets('a preserved INTERVAL=3 weekly rule renders without crashing', (
    tester,
  ) async {
    final source = PlannerCalendarDataSource(
      [
        event(
          'imported',
          'FREQ=WEEKLY;INTERVAL=3;BYDAY=MO,TH;COUNT=4',
          DateTime(2026, 11, 2, 9),
        ),
      ],
      const {},
    );
    await pumpCalendar(tester, source);
    expect(tester.takeException(), isNull);
    source.dispose();
  });

  test('adaptation is display-only; stored rule is unchanged', () {
    const rule = 'FREQ=WEEKLY';
    final original = event('bad', rule);
    final source = PlannerCalendarDataSource([original], const {});
    expect(source.getRecurrenceRule(0), isEmpty);
    expect(original.recurrenceRule, rule);
    expect(source.events.single.recurrenceRule, rule);
    expect(original.toJson()['recurrenceRule'], rule);
    source.dispose();
  });
}
