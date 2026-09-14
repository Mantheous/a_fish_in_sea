import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/model/tracked_point.dart';
import 'package:a_fish_in_sea/reporting/reporting_logic.dart';
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

  group('TrackingCubit', () {
    test('start/stop recording', () {
      final cubit = TrackingCubit();
      expect(cubit.state.isRecording, isFalse);
      cubit.startRecording();
      expect(cubit.state.isRecording, isTrue);
      expect(cubit.state.startedAt, isNotNull);
      cubit.stopRecording();
      expect(cubit.state.isRecording, isFalse);
      expect(cubit.state.startedAt, isNull);
    });

    test('addPoint + pointsOnDay', () {
      final cubit = TrackingCubit();
      final day = DateTime(2026, 9, 5);
      cubit.addPoint(TrackedPoint(
        id: 'a',
        timestamp: DateTime(2026, 9, 5, 9),
        lat: 40,
        lng: -111,
      ));
      cubit.addPoint(TrackedPoint(
        id: 'b',
        timestamp: DateTime(2026, 9, 6, 9),
        lat: 40,
        lng: -111,
      ));
      expect(cubit.state.pointsOnDay(day), hasLength(1));
    });

    test('mergePoints dedupes by id', () {
      final cubit = TrackingCubit();
      final point = TrackedPoint(
        id: 'a',
        timestamp: DateTime(2026, 9, 5, 9),
        lat: 40,
        lng: -111,
      );
      cubit.addPoint(point);
      cubit.mergePoints([point]);
      expect(cubit.state.points, hasLength(1));
    });
  });

  group('PlacesCubit', () {
    test('add/update/delete round trip', () {
      final cubit = PlacesCubit();
      const place = Place(id: 'p1', name: 'Home', lat: 40, lng: -111);
      cubit.addPlace(place);
      expect(cubit.byId('p1')?.name, 'Home');
      cubit.updatePlace(place.copyWith(name: 'Sweet home'));
      expect(cubit.byId('p1')?.name, 'Sweet home');
      cubit.deletePlace('p1');
      expect(cubit.byId('p1'), isNull);
    });

    test('json round trip', () {
      final cubit = PlacesCubit();
      cubit.addPlace(const Place(id: 'p1', name: 'Home', lat: 40, lng: -111));
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, hasLength(1));
      expect(restored?.first.name, 'Home');
    });
  });

  group('ReportingCubit', () {
    test('runAutoReport keeps manual edits', () {
      final cubit = ReportingCubit();
      final day = DateTime(2026, 9, 5);
      final manual = ReportedEntry(
        id: 'rep:e1',
        eventId: 'e1',
        title: 'Study',
        start: DateTime(2026, 9, 5, 9),
        end: DateTime(2026, 9, 5, 10),
        status: ReportStatus.attended,
        auto: false,
      );
      cubit.upsertEntry(day, manual);
      cubit.runAutoReport(
        day: day,
        planned: [
          PlannedSlice(
            eventId: 'e1',
            title: 'Study',
            start: DateTime(2026, 9, 5, 9),
            end: DateTime(2026, 9, 5, 10),
          ),
        ],
        dwells: const [],
        placeNames: const {},
      );
      final entries = cubit.entriesForDay(day);
      expect(entries, hasLength(1));
      expect(entries.first.auto, isFalse);
      expect(entries.first.status, ReportStatus.attended);
    });

    test('upsert marks entry manual, delete removes', () {
      final cubit = ReportingCubit();
      final day = DateTime(2026, 9, 5);
      final entry = ReportedEntry(
        id: 'x',
        title: 'Nap',
        start: DateTime(2026, 9, 5, 14),
        end: DateTime(2026, 9, 5, 15),
        status: ReportStatus.extra,
      );
      cubit.upsertEntry(day, entry);
      expect(cubit.entriesForDay(day).first.auto, isFalse);
      cubit.deleteEntry(day, 'x');
      expect(cubit.entriesForDay(day), isEmpty);
    });

    test('json round trip', () {
      final cubit = ReportingCubit();
      final day = DateTime(2026, 9, 5);
      cubit.upsertEntry(
        day,
        ReportedEntry(
          id: 'x',
          title: 'Nap',
          start: DateTime(2026, 9, 5, 14),
          end: DateTime(2026, 9, 5, 15),
          status: ReportStatus.extra,
        ),
      );
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?[dayKey(day)], hasLength(1));
    });
  });
}
