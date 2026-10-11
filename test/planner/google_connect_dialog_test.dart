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

/// Regression test: with a stale (dead-grant) connection the dialog used
/// to sit on the checking spinner forever, because _loadCalendars failures
/// never left the checking step.
void main() {
  late Storage storage;
  late MockGoogleService googleService;
  late FeedCubit feedCubit;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    UndoCubit();
    googleService = MockGoogleService();
    feedCubit = FeedCubit(
      calendarCubit: CalendarCubit(),
      nodeCubit: NodeCubit(),
      icalService: IcalService(client: MockClient()),
      googleService: googleService,
      proxyBase: () => 'http://localhost:8000',
    );
  });

  Future<void> openGoogleDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      BlocProvider<FeedCubit>.value(
        value: feedCubit,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showFeedManager(context),
                child: const Text('open feeds'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open feeds'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
  }

  testWidgets('dead grant falls back to sign-in instead of spinning',
      (tester) async {
    when(() => googleService.isConnected()).thenAnswer((_) async => true);
    when(() => googleService.listCalendars()).thenThrow(
      const GoogleCalendarException(
        'Token refresh failed (400)',
        statusCode: 401,
        needsReconnect: true,
      ),
    );

    await openGoogleDialog(tester);

    expect(find.text('Open Google sign-in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('non-auth calendar failure shows retry, not a dead spinner',
      (tester) async {
    when(() => googleService.isConnected()).thenAnswer((_) async => true);
    when(() => googleService.listCalendars()).thenThrow(
      const GoogleCalendarException('unreachable', statusCode: 502),
    );

    await openGoogleDialog(tester);

    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Retry re-checks the connection instead of hanging.
    when(() => googleService.listCalendars()).thenAnswer((_) async => []);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No calendars found on this account.'), findsOneWidget);
  });
}
