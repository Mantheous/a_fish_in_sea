import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  test(
    'scheduling flag round trips and tolerates missing or malformed values',
    () async {
      final storage = MockStorage();
      when(() => storage.read(any())).thenReturn(null);
      when(() => storage.write(any(), any())).thenAnswer((_) async {});
      HydratedBloc.storage = storage;
      final calendar = CalendarCubit();
      addTearDown(calendar.close);
      final event = PlannerEvent(
        id: 'assignment',
        subject: 'Assignment',
        start: DateTime(2030, 1, 1, 9),
        end: DateTime(2030, 1, 1, 10),
        feedId: 'class',
        isTask: true,
        workTimeScheduled: true,
      );
      expect(PlannerEvent.fromJson(event.toJson()), event);
      expect(event.copyWith(notes: 'Note').workTimeScheduled, isTrue);
      for (final bad in [null, 'true', 42, <String, dynamic>{}]) {
        final json = event.toJson()..['workTimeScheduled'] = bad;
        if (bad == null) json.remove('workTimeScheduled');
        final restored = calendar.fromJson({
          'events': [
            json,
            event.toJson(),
            {'id': 42},
          ],
        });
        expect(restored, hasLength(2));
        expect(restored!.first.workTimeScheduled, isFalse);
        expect(restored.last, event);
      }
    },
  );
}
