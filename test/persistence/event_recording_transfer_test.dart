import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  final start = DateTime(2026, 11, 2, 9);
  final original = PlannerEvent(
    id: 'source',
    subject: 'Work',
    start: start,
    end: start.add(const Duration(hours: 1)),
    sessions: [
      TimeSession(
        id: 'run',
        start: start,
        end: start.add(const Duration(minutes: 10)),
      ),
    ],
    timerStartedAt: start.add(const Duration(minutes: 20)),
  );

  test('transfer marker survives model and full calendar round trips', () {
    final source = original.copyWith(
      recordingsTransferredTo: 'destination',
      sessions: const [],
      clearActualStart: true,
      clearActualEnd: true,
      clearTimerStartedAt: true,
    );
    expect(PlannerEvent.fromJson(source.toJson()), source);
    expect(
      source.copyWith(subject: 'Renamed').recordingsTransferredTo,
      'destination',
    );
    final calendar = CalendarCubit();
    addTearDown(calendar.close);
    expect(calendar.fromJson(calendar.toJson([source, original])), [
      source,
      original,
    ]);
  });

  test(
    'old and malformed optional transfer fields retain valid recordings',
    () {
      final calendar = CalendarCubit();
      addTearDown(calendar.close);
      final old = original.toJson()..remove('recordingsTransferredTo');
      expect(PlannerEvent.fromJson(old), original);
      for (final invalid in [null, '', 42, false, [], {}]) {
        final restored = calendar.fromJson({
          'events': [
            {...old, 'recordingsTransferredTo': invalid},
            {'id': 42},
            'broken',
          ],
        });
        expect(restored, [original]);
        expect(restored!.single.sessions, original.sessions);
        expect(restored.single.timerStartedAt, original.timerStartedAt);
      }
    },
  );
}
