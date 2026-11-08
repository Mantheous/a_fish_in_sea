import '../../common/time/local_date.dart';
import '../model/node.dart';

/// Financial defaults shared by generation and conservative refreshes.
MoneyFacet? recurringInstanceMoney(MoneyFacet? money) => money == null
    ? null
    : MoneyFacet(
        targetAmount: money.targetAmount,
        direction: money.direction,
        status: MoneyStatus.projected,
        period: money.period,
        customPeriodDays: money.customPeriodDays,
        isRecurring: false,
        autoRollover: money.autoRollover,
        rolloverAmount: 0.0,
        isFixed: money.isFixed,
      );

/// The same generated snapshot for new copies and template reconciliation.
Node spawnRecurringInstance(Node template, String id, DateTime date) {
  final block = template.schedule;
  Duration? length;
  if (block?.start != null && block?.end != null) {
    final d = block!.end!.difference(block.start!);
    if (d.inMinutes > 0) length = d;
  }
  final day = localDay(date);
  ScheduleFacet? schedule;
  if (block != null) {
    final dueTime = block.due;
    final due = dueTime == null
        ? day
        : DateTime(day.year, day.month, day.day, dueTime.hour, dueTime.minute);
    DateTime? start;
    DateTime? end;
    if (length != null) {
      final base = block.start;
      start = base == null
          ? day
          : DateTime(day.year, day.month, day.day, base.hour, base.minute);
      end = start.add(length);
    }
    schedule = ScheduleFacet(
      due: due,
      start: start,
      end: end,
      allDay: block.allDay,
      isFixed: block.isFixed,
    );
  } else {
    schedule = ScheduleFacet(due: day);
  }
  return Node(
    id: id,
    title: template.title,
    notes: template.notes,
    parentIds: [template.id],
    createdAt: date,
    schedule: schedule,
    money: recurringInstanceMoney(template.money),
    effort: template.effort,
    // Instances inherit the deck and target but start unreviewed: the
    // template's cached count belongs to its own period, not the new
    // instance's.
    anki: template.anki?.copyWith(
      clearReviewsActual: true,
      clearLastSyncedAt: true,
    ),
    instanceOfId: template.id,
    sourceEventId: template.sourceEventId,
    calendarEventId: template.calendarEventId,
    feedId: template.feedId,
    classId: template.classId,
    classLabel: template.classLabel,
    classNodeId: template.classNodeId,
    assignees: template.assignees,
  );
}
