import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

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

  group('SettingsCubit snapMinutes', () {
    test('defaults to 15 minutes', () {
      expect(SettingsCubit().state.snapMinutes, 15);
    });

    test('setSnapMinutes stores the value', () {
      final cubit = SettingsCubit();
      cubit.setSnapMinutes(30);
      expect(cubit.state.snapMinutes, 30);
    });

    test('setSnapMinutes clamps to 1..60', () {
      final cubit = SettingsCubit();
      cubit.setSnapMinutes(0);
      expect(cubit.state.snapMinutes, 1);
      cubit.setSnapMinutes(120);
      expect(cubit.state.snapMinutes, 60);
    });

    test('toJson/fromJson round trip preserves snapMinutes', () {
      final cubit = SettingsCubit();
      cubit.setSnapMinutes(10);
      final json = cubit.toJson(cubit.state);
      final restored = cubit.fromJson(json);
      expect(restored?.snapMinutes, 10);
    });

    test('fromJson falls back to 15 when missing or invalid', () {
      final cubit = SettingsCubit();
      expect(cubit.fromJson({})?.snapMinutes, 15);
      expect(cubit.fromJson({'snapMinutes': 'nope'})?.snapMinutes, 15);
    });
  });

  group('platform default calendar view', () {
    test('mobile (android/ios) defaults to day', () {
      expect(
        platformDefaultFor(
            isWeb: false, platform: TargetPlatform.android),
        CalendarView.day,
      );
      expect(
        platformDefaultFor(isWeb: false, platform: TargetPlatform.iOS),
        CalendarView.day,
      );
    });

    test('mobile web defaults to day (app is served as web build)', () {
      expect(
        platformDefaultFor(isWeb: true, platform: TargetPlatform.android),
        CalendarView.day,
      );
      expect(
        platformDefaultFor(isWeb: true, platform: TargetPlatform.iOS),
        CalendarView.day,
      );
    });

    test('desktop defaults to week', () {
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          platformDefaultFor(isWeb: false, platform: platform),
          CalendarView.week,
        );
      }
    });

    test('fresh cubit uses the current platform default', () {
      expect(SettingsCubit().state.defaultCalendarView,
          platformDefaultCalendarView);
    });

    test('stored views round-trip; unknown views fall back, never throw',
        () {
      final cubit = SettingsCubit();
      cubit.setDefaultCalendarView(CalendarView.month);
      final restored =
          cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.defaultCalendarView, CalendarView.month);
      expect(cubit.fromJson({})?.defaultCalendarView,
          platformDefaultCalendarView);
      expect(
          cubit.fromJson(
              {'defaultCalendarView': 'renamed-value'})?.defaultCalendarView,
          platformDefaultCalendarView);
    });
  });
}
