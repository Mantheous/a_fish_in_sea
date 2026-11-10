import 'dart:async';
import 'dart:io';

import 'package:a_fish_in_sea/navigation/view/home_tracking_card.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:a_fish_in_sea/reporting/service/account_tracking.dart';
import 'package:a_fish_in_sea/reporting/service/location_service.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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

int _pointIndex = 0;

TrackedPoint _point(String id) => TrackedPoint(
  id: id,
  timestamp: DateTime.now(),
  lat: 40 + (++_pointIndex) / 1000,
  lng: -111,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform original;
  late _PathProvider paths;

  setUp(() async {
    original = PathProviderPlatform.instance;
    directory = await Directory.systemTemp.createTemp('account-gps-145');
    paths = _PathProvider();
    when(
      () => paths.getApplicationDocumentsPath(),
    ).thenAnswer((_) async => directory.path);
    PathProviderPlatform.instance = paths;
    HydratedBloc.storage = DelayedStorage();
  });

  tearDown(() async {
    LocationService.stopForegroundSampling();
    PathProviderPlatform.instance = original;
    await directory.delete(recursive: true);
  });

  for (final beforeLogin in [true, false]) {
    testWidgets('Remove keeps queued GPS under A; Home and sync for B reject '
        'sampling completed ${beforeLogin ? 'before' : 'after'} B signs in', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final server = FakeSyncClient();
        final d = SyncTestDevice(server, mobileTrackingAvailable: true);
        addTearDown(d.waterfall.close);
        await d.signIn();
        d.tracking.startRecording();
        await appendPendingPoint(_point('a-queued'), account: 'a@example.com');
        // Include both the pre-upgrade queue and an orphaned drain claim.
        await appendPendingPoint(_point('a-legacy'));
        final legacy = File('${directory.path}/tracking_pending_points.json');
        await legacy.rename('${legacy.path}.123.taking');

        final foreground = Completer<TrackedPoint?>();
        final background = Completer<TrackedPoint?>();
        final backgroundStarted = Completer<void>();
        final foregroundWork = sampleTrackingPoint(
          d.tracking,
          d.tracking.accountGeneration,
          () => foreground.future,
        );
        await writeTrackingConfig(
          1,
          account: 'a@example.com',
          session: 'a-run',
        );
        final backgroundWork = samplePendingPoint('a-run', () {
          backgroundStarted.complete();
          return background.future;
        });
        await backgroundStarted.future;

        await d.engine.signOut(clearLocalData: true);
        expect(d.tracking.state.isRecording, isFalse);
        expect((await readTrackingConfig())['session'], isNull);
        final saved = d.meta.state.accountSnapshots['a@example.com']!;
        expect(
          saved.collections['tracked_points']!.keys,
          containsAll(['a-queued', 'a-legacy']),
        );
        expect(d.tracking.state.points, isEmpty);
        if (!beforeLogin) {
          expect(await d.auth.login('b@example.com', 'password123'), isTrue);
          await writeTrackingConfig(
            1,
            account: 'b@example.com',
            session: 'b-run',
          );
        }
        foreground.complete(_point('a-foreground'));
        background.complete(_point('a-background'));
        await Future.wait([foregroundWork, backgroundWork]);
        if (beforeLogin) {
          expect(await d.auth.login('b@example.com', 'password123'), isTrue);
        }
        expect(d.tracking.state.points, isEmpty);
        // Even a write that raced the final token check stays under A.
        await appendPendingPoint(_point('a-late'), account: 'a@example.com');
        await appendPendingPoint(_point('b-queued'), account: 'b@example.com');
        await tester.pumpWidget(
          MultiBlocProvider(
            providers: [
              BlocProvider<TrackingCubit>.value(value: d.tracking),
              BlocProvider<SettingsCubit>.value(value: d.settings),
            ],
            child: const MaterialApp(home: Scaffold(body: HomeTrackingCard())),
          ),
        );
        // Home's initial drain uses actual file IO, outside the fake clock.
        for (var i = 0; i < 100 && d.tracking.state.points.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(d.tracking.state.points.map((p) => p.id), ['b-queued']);
        await d.engine.syncNow();
        expect(server.store['tracked_points']!.keys, ['b-queued']);
        expect(
          (await readPendingPoints(account: 'a@example.com')).map((p) => p.id),
          containsAll(['a-queued', 'a-legacy', 'a-late']),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await d.engine.signOut(clearLocalData: true);
        await d.signIn();
        await mergePendingTrackingPoints(d.tracking);
        expect(
          d.tracking.state.points.map((p) => p.id),
          containsAll(['a-queued', 'a-legacy', 'a-late']),
        );
        expect(
          d.tracking.state.points.map((p) => p.id),
          isNot(
            anyOf(
              contains('a-foreground'),
              contains('a-background'),
              contains('b-queued'),
            ),
          ),
        );
      });
    });
  }

  test(
    'an interrupted Home drain returns points to the outgoing account',
    () async {
      final d = SyncTestDevice(FakeSyncClient(), mobileTrackingAvailable: true);
      addTearDown(d.waterfall.close);
      await d.signIn();
      await appendPendingPoint(_point('a-queued'), account: 'a@example.com');
      final drainPaused = Completer<void>();
      var pauseNextRead = true;
      when(() => paths.getApplicationDocumentsPath()).thenAnswer((_) async {
        if (pauseNextRead) {
          pauseNextRead = false;
          await drainPaused.future;
        }
        return directory.path;
      });
      final drain = mergePendingTrackingPoints(d.tracking);
      await d.engine.signOut(clearLocalData: true);
      expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      drainPaused.complete();
      await drain;
      expect(d.tracking.state.points, isEmpty);
      expect(
        (await takePendingPoints(account: 'a@example.com')).single.id,
        'a-queued',
      );
      expect(await takePendingPoints(account: 'b@example.com'), isEmpty);
    },
  );

  test('the active service session can still queue a GPS point', () async {
    await writeTrackingConfig(5, account: 'a@example.com', session: 'active');
    await samplePendingPoint('active', () async => _point('current'));
    expect(
      (await takePendingPoints(account: 'a@example.com')).single.id,
      'current',
    );
  });

  test(
    'legacy and malformed GPS records restore per item under one owner',
    () async {
      final file = File('${directory.path}/tracking_pending_points.json');
      await file.writeAsString(
        '[{"id":"invalid"},'
        '{"id":"valid","timestamp":"${DateTime.now().toIso8601String()}",'
        '"lat":40.0,"lng":-111.0},null]',
      );
      await claimLegacyPendingPoints('a@example.com');
      expect(await takePendingPoints(account: 'b@example.com'), isEmpty);
      expect(
        (await takePendingPoints(account: 'a@example.com')).single.id,
        'valid',
      );
    },
  );

  test(
    'malformed sampling config can be invalidated without blocking sign-out',
    () async {
      final file = File('${directory.path}/tracking_config.json');
      await file.writeAsString(
        '{"intervalMinutes":"bad","account":[],"session":123}',
      );
      await invalidateTrackingSampling();
      expect(await readTrackingInterval(), 5);
      expect((await readTrackingConfig())['session'], isNull);
      await samplePendingPoint('123', () async => _point('stale'));
      expect(await takePendingPoints(), isEmpty);
    },
  );
}
