import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/quick_record.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node existingNode(String id) =>
    Node(id: id, title: 'Scripture study', createdAt: DateTime(2026, 10, 1));

PlannerEvent event(String id) => PlannerEvent(
  id: id,
  subject: 'Deep work',
  start: DateTime(2026, 10, 13, 7),
  end: DateTime(2026, 10, 13, 8),
  isTask: false,
);

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  test('creates a parentless task and starts its timer', () {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    final at = DateTime(2026, 10, 13, 12);

    final result = startQuickRecording(
      nodes,
      calendar,
      '  Lunch with Sam  ',
      now: at,
    );

    expect(result.error, isNull);
    final node = result.node!;
    expect(node.title, 'Lunch with Sam');
    expect(node.isTask, isTrue);
    expect(node.isTracking, isTrue);
    expect(node.timerStartedAt, at);
    expect(node.parentIds, isEmpty);
    expect(node.hasCalendarBlock, isFalse);
    expect(node.hasDue, isFalse);
    expect(nodes.byId(node.id)?.title, 'Lunch with Sam');
  });

  test('rejects an empty name without creating anything', () {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();

    final result = startQuickRecording(nodes, calendar, '   ');

    expect(result.error, isNotNull);
    expect(result.node, isNull);
    expect(nodes.state, isEmpty);
  });

  test('stops the node recording that was already running', () {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    nodes.addNode(existingNode('old'));
    nodes.startTracking('old', now: DateTime(2026, 10, 13, 7));

    final result = startQuickRecording(
      nodes,
      calendar,
      'Groceries',
      now: DateTime(2026, 10, 13, 7, 30),
    );

    expect(result.error, isNull);
    final old = nodes.byId('old')!;
    expect(old.isTracking, isFalse);
    expect(old.reportedDuration, const Duration(minutes: 30));
    expect(nodes.byId(result.node!.id)?.isTracking, isTrue);
  });

  test('stops a plain calendar event timer too', () {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    calendar.addEvent(event('e1'));
    calendar.startTracking('e1', now: DateTime(2026, 10, 13, 7));

    final result = startQuickRecording(
      nodes,
      calendar,
      'Train to Provo',
      now: DateTime(2026, 10, 13, 7, 15),
    );

    expect(result.error, isNull);
    final stopped = calendar.byId('e1')!;
    expect(stopped.isTracking, isFalse);
    expect(stopped.reportedDuration, const Duration(minutes: 15));
    expect(nodes.byId(result.node!.id)?.isTracking, isTrue);
  });

  test('falls back to timestamped ids when none is supplied', () {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    final at = DateTime(2026, 10, 13, 12);

    final first = startQuickRecording(nodes, calendar, 'Lunch', now: at);
    final second = startQuickRecording(
      nodes,
      calendar,
      'Errand',
      now: at.add(const Duration(seconds: 1)),
    );

    expect(first.node?.id, startsWith('node:'));
    expect(second.node?.id, startsWith('node:'));
    expect(first.node?.id, isNot(second.node?.id));
  });
}
