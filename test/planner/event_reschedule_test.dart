import 'package:a_fish_in_sea/planner/model/event_reschedule.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent _event({
  DateTime? start,
  DateTime? end,
  bool allDay = false,
  String recurrenceRule = '',
  String? feedId,
}) =>
    PlannerEvent(
      id: 'evt:1',
      subject: 'Test',
      start: start ?? DateTime(2026, 9, 7, 10, 0),
      end: end ?? DateTime(2026, 9, 7, 11, 0),
      allDay: allDay,
      recurrenceRule: recurrenceRule,
      feedId: feedId,
    );

void main() {
  group('isDraggableEvent', () {
    test('plain event is draggable', () {
      expect(isDraggableEvent(_event()), isTrue);
    });

    test('feed event is not draggable', () {
      expect(isDraggableEvent(_event(feedId: 'feed:1')), isFalse);
    });

    test('recurring event is not draggable', () {
      expect(
        isDraggableEvent(_event(recurrenceRule: 'FREQ=DAILY;INTERVAL=1')),
        isFalse,
      );
    });
  });

  group('snapToInterval', () {
    test('rounds to the nearest snap boundary', () {
      expect(
        snapToInterval(DateTime(2026, 9, 9, 14, 7), 15),
        DateTime(2026, 9, 9, 14, 0),
      );
      expect(
        snapToInterval(DateTime(2026, 9, 9, 14, 8), 15),
        DateTime(2026, 9, 9, 14, 15),
      );
    });

    test('rolls over midnight', () {
      expect(
        snapToInterval(DateTime(2026, 9, 9, 23, 53), 15),
        DateTime(2026, 9, 10),
      );
    });

    test('snap of 1 keeps minute precision', () {
      expect(
        snapToInterval(DateTime(2026, 9, 9, 14, 5, 42), 1),
        DateTime(2026, 9, 9, 14, 5),
      );
    });
  });

  group('shiftEvent', () {
    test('preserves duration when moved', () {
      final moved = shiftEvent(
        _event(
          start: DateTime(2026, 9, 7, 10, 0),
          end: DateTime(2026, 9, 7, 11, 30),
        ),
        DateTime(2026, 9, 9, 14, 0),
      );
      expect(moved.start, DateTime(2026, 9, 9, 14, 0));
      expect(moved.end, DateTime(2026, 9, 9, 15, 30));
    });

    test('strips seconds from drop time', () {
      final moved = shiftEvent(
        _event(),
        DateTime(2026, 9, 9, 14, 5, 42, 123),
      );
      expect(moved.start, DateTime(2026, 9, 9, 14, 5));
      expect(moved.end, DateTime(2026, 9, 9, 15, 5));
    });

    test('snaps the drop to the snap interval', () {
      final moved = shiftEvent(
        _event(),
        DateTime(2026, 9, 9, 14, 7),
        snapMinutes: 15,
      );
      expect(moved.start, DateTime(2026, 9, 9, 14, 0));
      expect(moved.end, DateTime(2026, 9, 9, 15, 0));
    });

    test('all-day drop normalizes to midnight', () {
      final moved = shiftEvent(
        _event(
          start: DateTime(2026, 9, 7),
          end: DateTime(2026, 9, 8),
          allDay: true,
        ),
        DateTime(2026, 9, 10, 15, 30),
      );
      expect(moved.start, DateTime(2026, 9, 10));
      expect(moved.end, DateTime(2026, 9, 11));
    });
  });

  group('resizeEvent', () {
    test('applies new start and end', () {
      final resized = resizeEvent(
        _event(),
        DateTime(2026, 9, 7, 9, 0),
        DateTime(2026, 9, 7, 12, 0),
      );
      expect(resized.start, DateTime(2026, 9, 7, 9, 0));
      expect(resized.end, DateTime(2026, 9, 7, 12, 0));
    });

    test('enforces a minimum duration', () {
      final resized = resizeEvent(
        _event(),
        DateTime(2026, 9, 7, 10, 0),
        DateTime(2026, 9, 7, 10, 5),
      );
      expect(resized.end.difference(resized.start), minEventDuration);
    });

    test('snaps resized edges to the snap interval', () {
      final resized = resizeEvent(
        _event(),
        DateTime(2026, 9, 7, 9, 7),
        DateTime(2026, 9, 7, 12, 8),
        snapMinutes: 15,
      );
      expect(resized.start, DateTime(2026, 9, 7, 9, 0));
      expect(resized.end, DateTime(2026, 9, 7, 12, 15));
    });

    test('keeps one side when the other is null', () {
      final original = _event();
      final resized = resizeEvent(original, null, DateTime(2026, 9, 7, 12, 0));
      expect(resized.start, original.start);
      expect(resized.end, DateTime(2026, 9, 7, 12, 0));
    });
  });
}
