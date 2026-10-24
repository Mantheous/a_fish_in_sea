import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/color_prefs.dart';
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

    test('applySyncedJson keeps the device-local view, adopts roamed hours',
        () {
      final cubit = SettingsCubit();
      cubit.setDefaultCalendarView(CalendarView.month);
      cubit.applySyncedJson({
        'defaultCalendarView': 'day',
        'dayStartHour': 7,
        'dayEndHour': 22,
      });
      expect(cubit.state.defaultCalendarView, CalendarView.month);
      expect(cubit.state.dayStartHour, 7);
      expect(cubit.state.dayEndHour, 22);
    });
  });

  group('event colors', () {
    test('start automatic and applied to both surfaces', () {
      final state = SettingsCubit().state.colors;
      expect(state.homework, isNull);
      expect(state.personal, isNull);
      expect(state.classes, isEmpty);
      expect(state.applyToCalendar, isTrue);
      expect(state.applyToTaskLists, isTrue);
    });

    test('homework, personal, and class colors are settable and clearable',
        () {
      final cubit = SettingsCubit();
      cubit.setHomeworkColor(0xFF6A8FB5);
      cubit.setPersonalEventColor(0xFF7E7AB8);
      cubit.setClassColor('STAT 230', 0xFFB2706B);
      expect(cubit.state.colors.homework, 0xFF6A8FB5);
      expect(cubit.state.colors.personal, 0xFF7E7AB8);
      expect(cubit.state.colors.classColorFor(' STAT 230 '), 0xFFB2706B);

      cubit.setHomeworkColor(null);
      cubit.setPersonalEventColor(null);
      cubit.setClassColor('STAT 230', null);
      expect(cubit.state.colors.hasOverrides, isFalse);
    });

    test('surface switches are independent', () {
      final cubit = SettingsCubit();
      cubit.setColorsApplyToCalendar(false);
      expect(cubit.state.colors.applyToCalendar, isFalse);
      expect(cubit.state.colors.applyToTaskLists, isTrue);
      cubit.setColorsApplyToTaskLists(false);
      expect(cubit.state.colors.applyToTaskLists, isFalse);
    });

    test('reset clears overrides and re-enables both surfaces', () {
      final cubit = SettingsCubit();
      cubit.setHomeworkColor(0xFF6A8FB5);
      cubit.setClassColor('WRTG 150', 0xFF7A9E7E);
      cubit.setColorsApplyToCalendar(false);
      cubit.resetEventColors();
      expect(cubit.state.colors, const ColorPrefs());
    });

    test('round trips through JSON', () {
      final cubit = SettingsCubit();
      cubit.setHomeworkColor(0xFF6A8FB5);
      cubit.setClassColor('STAT 230', 0xFFB2706B);
      cubit.setColorsApplyToTaskLists(false);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.colors, cubit.state.colors);
    });

    test('old payloads without colors load automatic, not empty', () {
      final restored = SettingsCubit().fromJson({'snapMinutes': 20});
      expect(restored?.snapMinutes, 20);
      expect(restored?.colors, const ColorPrefs());
    });

    test('a corrupt colors blob keeps the rest of the settings', () {
      final restored = SettingsCubit().fromJson({
        'snapMinutes': 30,
        'colors': 'not-a-map',
      });
      expect(restored?.snapMinutes, 30);
      expect(restored?.colors, const ColorPrefs());
    });

    test('synced colors roam while device-local settings stay put', () {
      final cubit = SettingsCubit();
      cubit.setDefaultCalendarView(CalendarView.month);
      cubit.applySyncedJson({
        'defaultCalendarView': 'day',
        'colors': {
          'homework': 0xFF6A8FB5,
          'classes': {'STAT 230': 0xFFB2706B},
          'applyToCalendar': false,
        },
      });
      expect(cubit.state.defaultCalendarView, CalendarView.month);
      expect(cubit.state.colors.homework, 0xFF6A8FB5);
      expect(cubit.state.colors.classColorFor('STAT 230'), 0xFFB2706B);
      expect(cubit.state.colors.applyToCalendar, isFalse);
    });
  });
}
