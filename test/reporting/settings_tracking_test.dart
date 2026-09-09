import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
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

  group('SettingsCubit location tracking', () {
    test('tracking enabled by default, interval 5', () {
      final state = SettingsCubit().state;
      expect(state.trackingEnabled, isTrue);
      expect(state.trackingIntervalMinutes, 5);
    });

    test('setTrackingEnabled toggles', () {
      final cubit = SettingsCubit();
      cubit.setTrackingEnabled(false);
      expect(cubit.state.trackingEnabled, isFalse);
      cubit.setTrackingEnabled(true);
      expect(cubit.state.trackingEnabled, isTrue);
    });

    test('setTrackingIntervalMinutes clamps to 1..15', () {
      final cubit = SettingsCubit();
      cubit.setTrackingIntervalMinutes(0);
      expect(cubit.state.trackingIntervalMinutes, 1);
      cubit.setTrackingIntervalMinutes(99);
      expect(cubit.state.trackingIntervalMinutes, 15);
      cubit.setTrackingIntervalMinutes(10);
      expect(cubit.state.trackingIntervalMinutes, 10);
    });

    test('round trip preserves tracking settings', () {
      final cubit = SettingsCubit();
      cubit.setTrackingEnabled(false);
      cubit.setTrackingIntervalMinutes(10);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.trackingEnabled, isFalse);
      expect(restored?.trackingIntervalMinutes, 10);
    });

    test('fromJson defaults when missing', () {
      expect(SettingsCubit().fromJson({})?.trackingEnabled, isTrue);
      expect(
        SettingsCubit().fromJson({})?.trackingIntervalMinutes,
        5,
      );
    });
  });
}
