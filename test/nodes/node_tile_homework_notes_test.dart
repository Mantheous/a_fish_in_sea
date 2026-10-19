import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_tile.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// Homework descriptions (refs #9): iCal DESCRIPTION arrives via imports
/// as node notes — the tile surfaces it, and Learning Suite homework
/// without notes gets a link-out instead (only the link is shipped).
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> pumpTile(
    WidgetTester tester,
    Node node, {
    bool showClass = false,
    Map<String, Feed> feedById = const {},
  }) async {
    final nodes = NodeCubit();
    nodes.addNode(node);
    addTearDown(nodes.close);
    await tester.pumpWidget(
      BlocProvider.value(
        value: nodes,
        child: MaterialApp(
          home: Scaffold(
            body: NodeTile(
              node: node,
              showClass: showClass,
              feedById: feedById,
              linkedEventIds: const {},
              linkedTaskIds: const {},
              upcomingEventCounts: const {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('homework tile renders imported notes', (tester) async {
    final node = Node(
      id: 'event-assignment-42',
      title: 'Essay 2',
      notes: 'Write 800 words on the prompt.',
      createdAt: DateTime(2026, 10, 1),
      sourceEventId: 'event-assignment-42',
      feedId: 'canvas-1',
      classId: 'canvas-1',
    );
    await pumpTile(tester, node);
    expect(find.text('Write 800 words on the prompt.'), findsOneWidget);
    expect(find.text('Open in Learning Suite'), findsNothing);
  });

  testWidgets('Learning Suite homework without notes links out',
      (tester) async {
    final node = Node(
      id: 'ls-1',
      title: 'Read chapter 4',
      createdAt: DateTime(2026, 10, 1),
      sourceEventId: 'ls-1',
      feedId: 'ls-feed',
      classId: 'ls-feed',
    );
    const feed = Feed(
      id: 'ls-feed',
      name: 'STAT 230',
      url: 'https://learningsuite.byu.edu',
      kind: FeedKind.learningSuite,
    );
    await pumpTile(tester, node,
        showClass: true, feedById: const {'ls-feed': feed});
    expect(find.text('Open in Learning Suite'), findsOneWidget);
  });

  testWidgets('plain task shows neither notes nor link-out', (tester) async {
    final node = Node(
      id: 't-1',
      title: 'Buy milk',
      createdAt: DateTime(2026, 10, 1),
    );
    await pumpTile(tester, node);
    expect(find.text('Open in Learning Suite'), findsNothing);
  });
}
