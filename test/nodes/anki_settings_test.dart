import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('ankiConnectHost setting', () {
    test('defaults to local AnkiConnect', () {
      expect(SettingsCubit().state.ankiConnectHost,
          SettingsCubit.defaultAnkiConnectHost);
    });

    test('set trims, blank resets to default', () {
      final cubit = SettingsCubit();
      cubit.setAnkiConnectHost('  http://192.168.1.5:8765  ');
      expect(cubit.state.ankiConnectHost, 'http://192.168.1.5:8765');
      cubit.setAnkiConnectHost('   ');
      expect(cubit.state.ankiConnectHost,
          SettingsCubit.defaultAnkiConnectHost);
    });

    test('round-trips, pre-host payloads get the default', () {
      final cubit = SettingsCubit();
      cubit.setAnkiConnectHost('http://192.168.1.5:8765');
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.ankiConnectHost, 'http://192.168.1.5:8765');
      expect(cubit.fromJson(const {})?.ankiConnectHost,
          SettingsCubit.defaultAnkiConnectHost);
      expect(cubit.fromJson(const {'ankiConnectHost': ''})?.ankiConnectHost,
          SettingsCubit.defaultAnkiConnectHost);
    });

    test('applySyncedJson keeps the per-device host', () {
      final cubit = SettingsCubit();
      cubit.setAnkiConnectHost('http://phone-lan:8765');
      cubit.applySyncedJson(const {
        'ankiConnectHost': 'http://desktop:8765',
        'icalProxyBase': 'https://roamed.test',
      });
      // Like icalProxyBase, the host stays per-device on roam.
      expect(cubit.state.ankiConnectHost, 'http://phone-lan:8765');
      expect(cubit.state.icalProxyBase, isEmpty);
    });
  });
}
