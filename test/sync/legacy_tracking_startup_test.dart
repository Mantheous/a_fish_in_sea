import 'dart:io';

import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:a_fish_in_sea/reporting/service/account_tracking.dart';
import 'package:a_fish_in_sea/reporting/service/location_service.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/delayed_storage.dart';
import 'support/sync_test_device.dart';

class _PathProvider extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform original;
  late DelayedStorage storage;

  setUp(() async {
    original = PathProviderPlatform.instance;
    directory = await Directory.systemTemp.createTemp('legacy-recording-145');
    final paths = _PathProvider();
    when(
      () => paths.getApplicationDocumentsPath(),
    ).thenAnswer((_) async => directory.path);
    PathProviderPlatform.instance = paths;
    storage = DelayedStorage();
    HydratedBloc.storage = storage;
  });

  tearDown(() async {
    LocationService.stopForegroundSampling();
    PathProviderPlatform.instance = original;
    await directory.delete(recursive: true);
  });

  File getConfigFile() => File('${directory.path}/tracking_config.json');

  SyncTestDevice restoredDevice({
    String? owner = 'a@example.com',
    String? signedInAs = 'a@example.com',
    bool recording = true,
    required Future<bool> Function(int, {String? account}) startBackground,
  }) {
    storage.data[StableStorageKeys.auth] = {
      'status': signedInAs == null ? 'signedOut' : 'signedIn',
      'email': signedInAs ?? '',
      if (signedInAs != null) 'accessToken': 'a',
      if (signedInAs != null) 'refreshToken': 'r',
    };
    storage.data[StableStorageKeys.syncMeta] = {
      if (owner != null) 'lastEmail': owner,
    };
    storage.data[StableStorageKeys.tracking] = {
      'isRecording': recording,
      'startedAt': DateTime.now().toIso8601String(),
      'points': <dynamic>[],
    };
    final device = SyncTestDevice(
      FakeSyncClient(),
      mobileTrackingAvailable: true,
      startBackgroundTracking: startBackground,
    );
    addTearDown(device.waterfall.close);
    return device;
  }

  for (final owner in ['a@example.com', null]) {
    test('boot resumes a legacy recording under A '
        '${owner == null ? 'using retained authentication' : 'using retained ownership'}; '
        'B cannot drain its points', () async {
      await getConfigFile().writeAsString('{"intervalMinutes":5}');
      var starts = 0;
      final device = restoredDevice(
        owner: owner,
        startBackground: (interval, {account}) async {
          starts++;
          expect(interval, 5);
          expect(account, 'a@example.com');
          // Stand in for the native service launch; its ticks still use the
          // real session checks and account-scoped queue on disk.
          await writeTrackingConfig(
            interval,
            account: account,
            session: 'resumed',
          );
          return true;
        },
      );
      expect(device.tracking.state.isRecording, isTrue);

      await device.engine.boot();
      expect(starts, 1);
      expect(device.tracking.state.isRecording, isTrue);
      var samples = 0;
      await samplePendingPoint('resumed', () async {
        samples++;
        return TrackedPoint(
          id: 'a-resumed',
          timestamp: DateTime.now(),
          lat: 40,
          lng: -111,
        );
      });
      expect(samples, 1);
      await device.engine.boot();
      expect(starts, 1, reason: 'An initialized session must not restart');

      expect(await device.auth.login('b@example.com', 'password123'), isTrue);
      expect(device.tracking.state.isRecording, isFalse);
      await mergePendingTrackingPoints(device.tracking);
      expect(device.tracking.state.points, isEmpty);
      expect(await takePendingPoints(account: 'b@example.com'), isEmpty);
      await device.engine.syncNow();
      expect(device.server.store['tracked_points'], isNull);
      expect(
        (await readPendingPoints(account: 'a@example.com')).single.id,
        'a-resumed',
      );
      await samplePendingPoint('resumed', () async {
        fail('The outgoing service session must remain invalid');
      });
    });
  }

  test('signed-out boot resumes only the retained owner recording', () async {
    await getConfigFile().writeAsString('{"intervalMinutes":5}');
    var starts = 0;
    final device = restoredDevice(
      signedInAs: null,
      startBackground: (interval, {account}) async {
        starts++;
        expect(account, 'a@example.com');
        await writeTrackingConfig(
          interval,
          account: account,
          session: 'retained',
        );
        return true;
      },
    );
    await device.engine.boot();
    expect(starts, 1);
    expect(device.server.pullCursors, isEmpty);
    expect(device.tracking.state.isRecording, isTrue);
    await device.engine.signOut();
    await device.engine.boot();
    expect(starts, 1, reason: 'Explicit sign-out must keep sampling stopped');
    expect((await readTrackingConfig())['session'], isNull);
  });

  for (final config in [
    '{"intervalMinutes":5,"account":"a@example.com","session":null}',
    '{"intervalMinutes":5,"session":null}',
    '{"intervalMinutes":5,"account":"a@example.com","session":"active"}',
    '{"intervalMinutes":"invalid"}',
    '{"intervalMinutes":1e999}',
  ]) {
    test(
      'boot leaves initialized, invalidated or malformed config alone: $config',
      () async {
        await getConfigFile().writeAsString(config);
        final device = restoredDevice(
          startBackground: (_, {account}) async {
            fail('Only an active legacy recording may be resumed');
          },
        );
        await device.engine.boot();
        expect(await getConfigFile().readAsString(), config);
      },
    );
  }

  for (final recording in [true, false]) {
    test('boot cannot resume legacy recording without '
        '${recording ? 'an owner' : 'a persisted recording'}', () async {
      await getConfigFile().writeAsString('{"intervalMinutes":5}');
      final device = restoredDevice(
        owner: recording ? null : 'a@example.com',
        signedInAs: recording ? null : 'a@example.com',
        recording: recording,
        startBackground: (_, {account}) async {
          fail('No active owned recording exists');
        },
      );
      await device.engine.boot();
      expect(await getConfigFile().readAsString(), '{"intervalMinutes":5}');
    });
  }
}
