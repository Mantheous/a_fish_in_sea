import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/settings/view/colors_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late SettingsCubit settings;
  late CalendarCubit calendar;
  late NodeCubit nodes;
  late FeedCubit feeds;

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    settings = SettingsCubit();
    calendar = CalendarCubit();
    nodes = NodeCubit();
    feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'test',
      ),
      proxyBase: () => '',
    );
  });

  tearDown(() {
    settings.close();
    calendar.close();
    nodes.close();
    feeds.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: settings),
          BlocProvider.value(value: calendar),
          BlocProvider.value(value: nodes),
          BlocProvider.value(value: feeds),
        ],
        child: const MaterialApp(home: ColorsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('lists classes from events and calendars from feeds', (
    tester,
  ) async {
    calendar.addEvent(
      PlannerEvent(
        id: 'e1',
        subject: 'Problem Set',
        start: DateTime(2026, 10, 24, 9),
        end: DateTime(2026, 10, 24, 10),
        classLabel: 'STAT 230-002',
      ),
    );
    nodes.addNode(
      Node(
        id: 'n1',
        title: 'Reading',
        createdAt: DateTime(2026, 10, 1),
        classLabel: 'WRTG 150',
      ),
    );
    feeds.addFeed(
      const Feed(
        id: 'f1',
        name: 'Canvas · Fall',
        url: 'https://example.com/feed.ics',
        kind: FeedKind.canvas,
      ),
    );
    await pumpPage(tester);

    expect(find.text('Colors'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Homework'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'STAT 230-002'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'WRTG 150'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Canvas · Fall'), 200);
    expect(find.widgetWithText(ListTile, 'Canvas · Fall'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Where colors apply'), 200);
    expect(find.text('Where colors apply'), findsOneWidget);
  });

  testWidgets('picking a swatch sets the homework color', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(ListTile, 'Homework'));
    await tester.pumpAndSettle();
    expect(find.text('Palette'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey(0xFF6A8FB5)));
    await tester.pumpAndSettle();

    expect(settings.state.colors.homework, 0xFF6A8FB5);
    expect(find.textContaining('Every imported assignment'), findsOneWidget);
  });

  testWidgets('automatic clears a homework color', (tester) async {
    settings.setHomeworkColor(0xFF6A8FB5);
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(ListTile, 'Homework'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Class or calendar color'));
    await tester.pumpAndSettle();

    expect(settings.state.colors.homework, isNull);
  });

  testWidgets('class rows assign and clear per-class colors', (tester) async {
    calendar.addEvent(
      PlannerEvent(
        id: 'e1',
        subject: 'Problem Set',
        start: DateTime(2026, 10, 24, 9),
        end: DateTime(2026, 10, 24, 10),
        classLabel: 'STAT 230-002',
      ),
    );
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(ListTile, 'STAT 230-002'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey(0xFF8E7AAE)));
    await tester.pumpAndSettle();

    expect(settings.state.colors.classColorFor('STAT 230-002'), 0xFF8E7AAE);
    expect(find.text('Custom color'), findsOneWidget);
  });

  testWidgets('surface switches update settings', (tester) async {
    await pumpPage(tester);
    await tester.scrollUntilVisible(find.text('Where colors apply'), 200);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Calendar'));
    await tester.pumpAndSettle();
    expect(settings.state.colors.applyToCalendar, isFalse);
  });
}
