import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor_side_sheet.dart';
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

  Future<void> pumpAtSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('wide screens open the editor as a right-hand side sheet', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    await pumpAtSize(tester, const Size(1200, 800));
    await tester.pumpWidget(harness(nodes));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheet = find.byKey(nodeEditorSideSheetKey);
    expect(sheet, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('New node'), findsOneWidget);

    // Flush right, full height — the calendar side-panel shape.
    final rect = tester.getRect(sheet);
    expect(rect.right, 1200);
    expect(rect.top, 0);
    expect(rect.bottom, 800);
    expect(rect.width, lessThan(1200));

    // The footer is pinned outside the scroll view, so Save is reachable.
    expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Title').first,
      'Side panel goal',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.byKey(nodeEditorSideSheetKey), findsNothing);
    expect(nodes.state.single.title, 'Side panel goal');
  });

  testWidgets('narrow screens keep the centered dialog', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    await pumpAtSize(tester, const Size(500, 800));
    await tester.pumpWidget(harness(nodes));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(nodeEditorSideSheetKey), findsNothing);
    expect(find.text('New node'), findsOneWidget);
  });
}
