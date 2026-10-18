import 'dart:io';

import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:a_fish_in_sea/reporting/service/location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakePathProvider extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  FakePathProvider(this.path);
  final String path;
}

TrackedPoint _pt(String id, DateTime at) =>
    TrackedPoint(id: id, timestamp: at, lat: 40.0, lng: -111.0);

void main() {
  late Directory dir;
  late PathProviderPlatform original;

  setUp(() async {
    original = PathProviderPlatform.instance;
    dir = await Directory.systemTemp.createTemp('pending-test');
    final fake = FakePathProvider(dir.path);
    when(() => fake.getApplicationDocumentsPath())
        .thenAnswer((_) async => dir.path);
    PathProviderPlatform.instance = fake;
  });

  tearDown(() async {
    PathProviderPlatform.instance = original;
    await dir.delete(recursive: true);
  });

  test('append then take returns points in order; second take is empty',
      () async {
    final now = DateTime.now();
    await appendPendingPoint(
        _pt('a', now.subtract(const Duration(minutes: 2))));
    await appendPendingPoint(
        _pt('b', now.subtract(const Duration(minutes: 1))));
    final first = await takePendingPoints();
    expect(first.map((p) => p.id), ['a', 'b']);
    expect(await takePendingPoints(), isEmpty);
  });

  test('take/requeue cycle loses nothing (unmounted merge)', () async {
    final now = DateTime.now();
    await appendPendingPoint(
        _pt('a', now.subtract(const Duration(minutes: 2))));
    await appendPendingPoint(
        _pt('b', now.subtract(const Duration(minutes: 1))));
    final taken = await takePendingPoints();
    expect(taken, hasLength(2));
    // The merging widget unmounted before merging: points go back.
    await requeuePendingPoints(taken);
    final again = await takePendingPoints();
    expect(again.map((p) => p.id), ['a', 'b']);
  });

  test('corrupt pending file is cleared without throwing', () async {
    final file = File('${dir.path}/tracking_pending_points.json');
    await file.writeAsString('not-json{');
    expect(await takePendingPoints(), isEmpty);
    expect(await file.exists(), isFalse);
  });

  test('orphaned claim from a crashed take is recovered', () async {
    final now = DateTime.now();
    await appendPendingPoint(_pt('a', now));
    final file = File('${dir.path}/tracking_pending_points.json');
    // Simulate a crash between the atomic rename and the post-read delete.
    await file.rename('${file.path}.123.taking');
    final taken = await takePendingPoints();
    expect(taken.map((p) => p.id), ['a']);
    expect(await takePendingPoints(), isEmpty);
  });
}
