import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
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

  Widget harness(NodeCubit nodes) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: nodes),
        BlocProvider(create: (_) => UndoCubit()),
        BlocProvider(create: (_) => CalendarCubit()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNodeEditor(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('enter in title submits a new goal', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    await tester.pumpWidget(harness(nodes));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final title = find.widgetWithText(TextField, 'Title').first;
    await tester.enterText(title, 'Enter saves me');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(nodes.state.single.title, 'Enter saves me');
  });
}
