import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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

  testWidgets('finish sheet assigns the recorded task to a goal', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    expect(
      nodes.addNode(
        Node(
          id: 'node:lunch',
          title: 'Lunch with Sam',
          createdAt: DateTime(2026, 10, 30),
          taskFlag: true,
        ),
      ),
      isNull,
    );
    expect(
      nodes.addNode(
        Node(
          id: 'node:health',
          title: 'Health',
          createdAt: DateTime(2026, 10, 30),
        ),
      ),
      isNull,
    );

    await tester.pumpWidget(
      BlocProvider<NodeCubit>.value(
        value: nodes,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showNodeFinishSheet(context, nodeId: 'node:lunch'),
                child: const Text('open finish'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open finish'));
    await tester.pumpAndSettle();
    expect(find.text('Work session saved'), findsOneWidget);

    await tester.tap(find.text('Assign to goal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();

    expect(nodes.byId('node:lunch')?.parentIds, ['node:health']);
    expect(find.text('Work session saved'), findsNothing);
    expect(find.text('Assigned to “Health”'), findsOneWidget);
  });
}
