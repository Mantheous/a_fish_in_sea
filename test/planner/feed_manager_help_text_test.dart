import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/feed_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockClient extends Mock implements http.Client {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

void main() {
  late Storage storage;
  late FeedCubit feedCubit;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    UndoCubit();
    feedCubit = FeedCubit(
      calendarCubit: CalendarCubit(),
      nodeCubit: NodeCubit(),
      icalService: IcalService(client: MockClient()),
      googleService: MockGoogleService(),
      proxyBase: () => 'http://localhost:8000',
    );
  });

  tearDown(() async {
    await feedCubit.close();
  });

  testWidgets('feed manager help text uses ASCII arrows, not tofu glyphs',
      (tester) async {
    await tester.pumpWidget(
      BlocProvider<FeedCubit>.value(
        value: feedCubit,
        child: const MaterialApp(
          home: Scaffold(body: FeedManagerBody()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');

    expect(texts, isNot(contains('\u2192')));
    expect(texts, contains('>'));
  });
}
