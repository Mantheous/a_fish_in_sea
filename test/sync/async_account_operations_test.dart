import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'dart:async';
import 'dart:convert';

import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:a_fish_in_sea/finances/view/bank_connection_card.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/canvas_service.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

import 'support/sync_test_device.dart';

class _CanvasService extends Mock implements CanvasService {}

class _GoogleService extends Mock implements GoogleCalendarService {}

const _privateIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:assignment-a
DTSTAMP:20260901T120000Z
DTSTART:20300101T090000Z
DTEND:20300101T091500Z
SUMMARY:A private assignment
END:VEVENT
END:VCALENDAR
''';

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  for (final beforeLogin in [true, false]) {
    final timing = beforeLogin ? 'before B signs in' : 'after B signs in';
    testWidgets('A bank transaction response $timing cannot enter B stores '
        'or cloud', (tester) async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final requests = <String>[];
      final server = FakeSyncClient();
      final d = SyncTestDevice(
        server,
        plaidService: PlaidService(
          baseUrl: 'https://plaid.test',
          userId: 'account-a',
          client: MockClient((request) {
            requests.add(request.url.path);
            if (request.url.path == '/api/transactions') {
              started.complete();
              return response.future;
            }
            return Future.value(http.Response('{"accounts":[]}', 200));
          }),
        ),
      );
      addTearDown(d.waterfall.close);
      await d.signIn();
      d.plaid.seedConnected('a-bank');
      late Future<void> fetch;
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<NodeCubit>.value(value: d.nodes),
            BlocProvider<PlaidCubit>.value(value: d.plaid),
            BlocProvider<TransactionsCubit>.value(value: d.transactions),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => fetch = syncPlaidTransactions(context),
                  child: const Text('Sync bank'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Sync bank'));
      await started.future;
      await d.engine.signOut(clearLocalData: true);
      if (!beforeLogin) {
        expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      }
      response.complete(
        http.Response(
          jsonEncode({
            'latest_transactions': [
              {
                'transaction_id': 'a-private',
                'account_id': 'a-bank',
                'amount': 42,
                'date': '2026-11-01',
                'name': 'A private purchase',
              },
            ],
          }),
          200,
        ),
      );
      await fetch;
      expect(d.transactions.state, isEmpty);
      if (beforeLogin) {
        expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      }
      await d.engine.syncNow();
      expect(d.transactions.state, isEmpty);
      expect(server.store['transactions'] ?? {}, isEmpty);
      expect(d.plaid.state.isConnected, isFalse);
      expect(requests, ['/api/transactions']);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Synced '), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('A feed response $timing cannot enter B stores or cloud', () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final server = FakeSyncClient();
      final d = SyncTestDevice(
        server,
        icalService: IcalService(
          client: MockClient((_) {
            started.complete();
            return response.future;
          }),
        ),
      );
      addTearDown(d.waterfall.close);
      await d.signIn();
      d.feeds.addFeed(
        const Feed(
          id: 'a-feed',
          name: 'A class',
          url: 'https://ical.test/private.ics',
        ),
      );
      final fetch = d.feeds.syncAll(force: true);
      await started.future;
      await d.engine.signOut(clearLocalData: true);
      if (!beforeLogin) {
        expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      }
      response.complete(http.Response(_privateIcs, 200));
      await fetch;
      expect(d.events.state, isEmpty);
      expect(d.nodes.state, isEmpty);
      if (beforeLogin) {
        expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      }
      await d.engine.syncNow();
      expect(d.events.state, isEmpty);
      expect(d.nodes.state, isEmpty);
      expect(server.store['events'] ?? {}, isEmpty);
      expect(server.store['nodes'] ?? {}, isEmpty);
    });
  }

  for (final operation in ['balance', 'accounts', 'info']) {
    test('A delayed bank $operation cannot change B after a direct account '
        'switch', () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final requests = <String>[];
      final server = FakeSyncClient();
      final d = SyncTestDevice(
        server,
        plaidService: PlaidService(
          baseUrl: 'https://plaid.test',
          userId: 'a-bank',
          client: MockClient((request) {
            requests.add(request.url.path);
            started.complete();
            return response.future;
          }),
        ),
      );
      addTearDown(d.waterfall.close);
      await d.signIn();
      d.plaid.seedConnected('a-bank');
      final fetch = switch (operation) {
        'balance' => d.plaid.fetchBalance(),
        'accounts' => d.plaid.fetchAccounts(),
        _ => d.plaid.checkExistingConnection(),
      };
      await started.future;
      expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      d.plaid.seedConnected('b-bank');
      response.complete(
        http.Response(
          jsonEncode({
            'connected': true,
            'item_id': 'a-bank',
            'accounts': [
              {
                'account_id': 'a-private',
                'type': 'depository',
                'balances': {'current': 1234},
              },
            ],
          }),
          200,
        ),
      );
      await fetch;
      expect(d.plaid.state.itemId, 'b-bank');
      expect(d.plaid.state.currentBalance, isNull);
      expect(d.plaid.state.accounts, isEmpty);
      expect(requests, ['/api/$operation']);
      await d.engine.syncNow();
      expect(server.store['plaid']!['singleton']!.data['itemId'], 'b-bank');
    });
  }

  test('an outgoing feed completion cannot release B active sync or import '
      'A content', () async {
    final aResponse = Completer<http.Response>();
    final bResponse = Completer<http.Response>();
    final aStarted = Completer<void>();
    final bStarted = Completer<void>();
    var requests = 0;
    final server = FakeSyncClient();
    final d = SyncTestDevice(
      server,
      icalService: IcalService(
        client: MockClient((_) {
          if (++requests == 1) {
            aStarted.complete();
            return aResponse.future;
          }
          bStarted.complete();
          return bResponse.future;
        }),
      ),
    );
    addTearDown(d.waterfall.close);
    await d.signIn();
    const feed = Feed(
      id: 'shared',
      name: 'Class',
      url: 'https://ical.test/class',
    );
    d.feeds.addFeed(feed);
    final aSync = d.feeds.syncAll(force: true);
    await aStarted.future;
    await d.engine.signOut(clearLocalData: true);
    expect(await d.auth.login('b@example.com', 'password123'), isTrue);
    d.feeds.addFeed(feed);
    final bSync = d.feeds.syncAll(force: true);
    await bStarted.future;

    aResponse.complete(http.Response(_privateIcs, 200));
    await aSync;
    expect(d.feeds.isSyncing.value, isTrue);
    expect(d.events.state, isEmpty);
    bResponse.complete(
      http.Response(
        _privateIcs.replaceAll('A private assignment', 'B assignment'),
        200,
      ),
    );
    await bSync;
    expect(d.feeds.isSyncing.value, isFalse);
    expect(d.events.state.single.subject, 'B assignment');
    await d.engine.syncNow();
    expect(
      server.store['events']!.values.single.data['subject'],
      'B assignment',
    );
  });

  test('A delayed Canvas completion cannot complete B homework', () async {
    final response = Completer<List<CanvasSubmission>>();
    final started = Completer<void>();
    final canvas = _CanvasService();
    when(canvas.fetchSubmissions).thenAnswer((_) {
      started.complete();
      return response.future;
    });
    final server = FakeSyncClient();
    final d = SyncTestDevice(
      server,
      canvasService: canvas,
      icalService: IcalService(
        client: MockClient(
          (_) async => http.Response(
            _privateIcs.replaceAll('assignment-a', 'event-assignment-42'),
            200,
          ),
        ),
      ),
    );
    addTearDown(d.waterfall.close);
    await d.signIn();
    d.feeds.addFeed(
      const Feed(
        id: 'shared',
        name: 'Class',
        url: 'https://ical.test/class',
        kind: FeedKind.canvas,
      ),
    );
    final fetch = d.feeds.syncAll(force: true);
    await started.future;
    await d.engine.signOut(clearLocalData: true);
    expect(await d.auth.login('b@example.com', 'password123'), isTrue);
    d.nodes.addNode(
      Node(
        id: 'b-homework',
        title: 'B assignment',
        createdAt: DateTime(2026),
        classId: 'shared',
        sourceEventId: 'hw:shared:event-assignment-42',
      ),
    );
    response.complete([
      const CanvasSubmission(assignmentId: 42, submitted: true),
    ]);
    await fetch;
    expect(d.nodes.state.single.isOpen, isTrue);
    await d.engine.syncNow();
    expect(server.store['nodes']!['b-homework']!.data['status'], 'open');
  });

  test(
    'A delayed Google write response cannot import an event into B',
    () async {
      final response = Completer<PlannerEvent>();
      final google = _GoogleService();
      final event = PlannerEvent(
        id: 'a-private',
        subject: 'A appointment',
        feedId: 'a-feed',
        sourceUid: 'a-private',
        start: DateTime(2030, 1, 1, 9),
        end: DateTime(2030, 1, 1, 10),
      );
      const feed = Feed(
        id: 'a-feed',
        name: 'A calendar',
        url: '',
        kind: FeedKind.google,
        calendarId: 'a-calendar',
      );
      when(
        () => google.createEvent(
          calendarId: 'a-calendar',
          feedId: 'a-feed',
          event: event,
        ),
      ).thenAnswer((_) => response.future);
      final server = FakeSyncClient();
      final d = SyncTestDevice(server, googleService: google);
      addTearDown(d.waterfall.close);
      await d.signIn();
      d.feeds.addFeed(feed);
      final write = d.feeds.pushEventCreate(feed: feed, event: event);
      await d.engine.signOut(clearLocalData: true);
      expect(await d.auth.login('b@example.com', 'password123'), isTrue);
      response.complete(event);
      final result = await write;
      expect(result.created, isNull);
      expect(result.error, isNotNull);
      expect(d.events.state, isEmpty);
      await d.engine.syncNow();
      expect(server.store['events'] ?? {}, isEmpty);
    },
  );
}
