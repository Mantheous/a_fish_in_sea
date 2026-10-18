import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });
  final old = Node(
    id: 'old',
    title: 'Recorded work',
    createdAt: DateTime(2026),
    actualStart: DateTime(2026, 10, 18, 6),
    actualEnd: DateTime.utc(2026, 10, 18, 13),
    notes: 'Keep these notes',
    status: NodeStatus.done,
  );

  test('calendar link and original records survive full cubit round trip', () {
    final cubit = NodeCubit();
    final node = old.copyWith(
      calendarLink: NodeCalendarLink(
        seriesKey: 'feed|series:scripture',
        records: {'original': old.toJson()},
        excludedEventIds: {'detached-event'},
        isEnabled: false,
      ),
    );
    final json = cubit.toJson([node]);
    final restored = cubit.fromJson(json)!;
    expect(restored, [node]);
    expect(
      Node.fromJson(restored.single.calendarLink!.records['original']!),
      old,
    );
    cubit.close();
  });

  test('old payloads and corrupt optional links keep every valid node', () {
    final cubit = NodeCubit();
    final payload = old.toJson()..remove('calendarLink');
    expect(Node.fromJson(payload).calendarLink, isNull);
    for (final invalid in [
      42,
      'bad',
      {},
      {'seriesKey': 42},
    ]) {
      final restored = cubit.fromJson({
        'nodes': [
          {...payload, 'calendarLink': invalid},
          {'id': 42},
        ],
      });
      expect(restored, [old]);
    }
    cubit.close();
  });

  test('a corrupt archived item does not discard other history', () {
    final restored = Node.fromJson({
      ...old.toJson(),
      'calendarLink': {
        'seriesKey': 'calendar|series:one',
        'excludedEventIds': [42, 'one'],
        'records': {'good': old.toJson(), 'bad': 42, 'other': 'bad'},
      },
    });
    expect(restored.calendarLink!.records.keys, ['good']);
    expect(restored.calendarLink!.excludedEventIds, {'one'});
    expect(restored.notes, old.notes);
    expect(restored.status, NodeStatus.done);
  });
}
