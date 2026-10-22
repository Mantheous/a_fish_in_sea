import 'package:a_fish_in_sea/nodes/bloc/schedule_prefs_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('SchedulePrefs persistence', () {
    test('round-trips last-used granularity', () {
      final cubit = SchedulePrefsCubit();
      addTearDown(cubit.close);
      expect(cubit.state.lastUsed, ScheduleGranularity.day);
      cubit.setGranularity(ScheduleGranularity.timed);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);
      expect(restored?.lastUsed, ScheduleGranularity.timed);
    });

    test('unknown enum values fall back to day', () {
      final cubit = SchedulePrefsCubit();
      addTearDown(cubit.close);
      expect(
        cubit.fromJson(const {'lastUsed': 'renamed-value'})?.lastUsed,
        ScheduleGranularity.day,
      );
      expect(
        cubit.fromJson(const {'lastUsed': 42})?.lastUsed,
        ScheduleGranularity.day,
      );
      expect(
        cubit.fromJson(const {})?.lastUsed,
        ScheduleGranularity.day,
      );
    });

    test('initialFor prefers existing data over the pref', () {
      final day = DateTime(2026, 10, 18, 12);
      expect(
        SchedulePrefsCubit.initialFor(
          schedule: ScheduleFacet(due: day),
          fallback: ScheduleGranularity.timed,
        ),
        ScheduleGranularity.day,
      );
      expect(
        SchedulePrefsCubit.initialFor(
          schedule: ScheduleFacet(
            start: day,
            end: day.add(const Duration(hours: 1)),
          ),
          fallback: ScheduleGranularity.day,
        ),
        ScheduleGranularity.timed,
      );
      expect(
        SchedulePrefsCubit.initialFor(
          fallback: ScheduleGranularity.timed,
        ),
        ScheduleGranularity.timed,
      );
    });
  });
}
