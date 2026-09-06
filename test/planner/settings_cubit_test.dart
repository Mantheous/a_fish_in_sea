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
}
