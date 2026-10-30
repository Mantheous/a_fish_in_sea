import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/sync/sync_timer_merge.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _payload(
  List<({String id, DateTime start, DateTime end})> runs,
) => {
  'sessions': [
    for (final run in runs)
      {
        'id': run.id,
        'start': run.start.toUtc().toIso8601String(),
        'end': run.end.toUtc().toIso8601String(),
      },
  ],
  if (runs.isNotEmpty) ...{
    'actualStart': runs.first.start.toUtc().toIso8601String(),
    'actualEnd': runs.last.end.toUtc().toIso8601String(),
  },
};

void main() {
  final a = (
    id: 'ts:a',
    start: DateTime(2026, 9, 12, 9),
    end: DateTime(2026, 9, 12, 9, 20),
  );
  final b = (
    id: 'ts:b',
    start: DateTime(2026, 9, 12, 10),
    end: DateTime(2026, 9, 12, 10, 30),
  );
  final c = (
    id: 'ts:c',
    start: DateTime(2026, 9, 12, 11),
    end: DateTime(2026, 9, 12, 11, 30),
  );

  test('a newer remote run still keeps the local run', () {
    final local = _payload([a]);
    final merged = _payload([b, c]); // C is newer than anything local
    preserveRecordedSessions('nodes', local, merged);

    final sessions = TimeSession.listFromJson(merged['sessions']);
    expect(sessions.map((s) => s.id), ['ts:a', 'ts:b', 'ts:c']);
    expect(merged['actualStart'], a.start.toUtc().toIso8601String());
    expect(merged['actualEnd'], c.end.toUtc().toIso8601String());
  });

  test('a remote legacy-only payload keeps the local sessions', () {
    final local = _payload([a, b]);
    final merged = <String, dynamic>{
      'actualStart': c.start.toUtc().toIso8601String(),
      'actualEnd': c.end.toUtc().toIso8601String(),
    };
    preserveRecordedSessions('events', local, merged);

    final sessions = TimeSession.listFromJson(merged['sessions']);
    expect(sessions.map((s) => s.id), containsAll(['ts:a', 'ts:b']));
    expect(sessions, hasLength(3));
    expect(merged['actualStart'], a.start.toUtc().toIso8601String());
    expect(merged['actualEnd'], c.end.toUtc().toIso8601String());
  });

  test('a remote aggregate that spans local runs is not counted again', () {
    final local = _payload([a, b]); // 09:00–09:20 and 10:00–10:30
    final merged = <String, dynamic>{
      // A pre-sessions client writes only the aggregate span.
      'actualStart': a.start.toUtc().toIso8601String(),
      'actualEnd': b.end.toUtc().toIso8601String(),
    };
    preserveRecordedSessions('nodes', local, merged);

    final sessions = TimeSession.listFromJson(merged['sessions']);
    expect(sessions.map((s) => s.id), ['ts:a', 'ts:b']);
    expect(merged['actualStart'], a.start.toUtc().toIso8601String());
    expect(merged['actualEnd'], b.end.toUtc().toIso8601String());
  });

  test('the remote copy wins when both devices edited one run', () {
    final local = _payload([a]);
    final edited = (
      id: 'ts:a',
      start: DateTime(2026, 9, 12, 9, 5),
      end: DateTime(2026, 9, 12, 9, 25),
    );
    final merged = _payload([edited]);
    preserveRecordedSessions('nodes', local, merged);

    final sessions = TimeSession.listFromJson(merged['sessions']);
    expect(sessions, hasLength(1));
    expect(sessions.single.start, edited.start);
    expect(sessions.single.end, edited.end);
  });

  test(
    'a remote aggregate pair that already matches the runs is not duplicated',
    () {
      final local = _payload([a, b]);
      final merged = _payload([b]);
      preserveRecordedSessions('nodes', local, merged);

      final sessions = TimeSession.listFromJson(merged['sessions']);
      expect(sessions.map((s) => s.id), ['ts:a', 'ts:b']);
    },
  );

  for (final collection in ['nodes', 'events']) {
    for (final remaining in [
      <({String id, DateTime start, DateTime end})>[],
      [b],
    ]) {
      test('$collection accepts remote deletion from an unchanged item '
          '(${remaining.length} remaining)', () {
        final local = _payload([a, b]);
        final merged = _payload(remaining);
        final remote = Map<String, dynamic>.from(merged);
        preserveRunningTimer(
          collection,
          local,
          merged,
          preserveLocalSessions: false,
        );
        expect(merged, remote);
      });
    }

    test(
      '$collection keeps a synced live timer without restoring deleted runs',
      () {
        final local = _payload([a])
          ..['timerStartedAt'] = b.start.toUtc().toIso8601String();
        final merged = _payload([]);
        preserveRunningTimer(
          collection,
          local,
          merged,
          preserveLocalSessions: false,
        );
        expect(merged['sessions'], isEmpty);
        expect(merged['timerStartedAt'], local['timerStartedAt']);
      },
    );

    test(
      '$collection keeps unsent runs and a live timer without a baseline',
      () {
        final local = _payload([a])
          ..['timerStartedAt'] = b.start.toUtc().toIso8601String();
        final merged = _payload([]);
        preserveRunningTimer(
          collection,
          local,
          merged,
          preserveLocalSessions: true,
        );
        expect(TimeSession.listFromJson(merged['sessions']).single.id, a.id);
        expect(merged['timerStartedAt'], local['timerStartedAt']);
      },
    );
  }

  test('other collections are untouched', () {
    final local = _payload([a]);
    final merged = _payload([b]);
    preserveRecordedSessions('reports', local, merged);
    expect(TimeSession.listFromJson(merged['sessions']), hasLength(1));
  });
}
