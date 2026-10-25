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

  test('an aggregate pair that already matches the runs is not duplicated', () {
    final local = _payload([a, b]);
    final merged = _payload([b]);
    preserveRecordedSessions('nodes', local, merged);

    final sessions = TimeSession.listFromJson(merged['sessions']);
    expect(sessions.map((s) => s.id), ['ts:a', 'ts:b']);
  });

  test('other collections are untouched', () {
    final local = _payload([a]);
    final merged = _payload([b]);
    preserveRecordedSessions('reports', local, merged);
    expect(TimeSession.listFromJson(merged['sessions']), hasLength(1));
  });
}
