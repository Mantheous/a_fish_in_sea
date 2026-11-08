part of 'sync_engine_test.dart';

class _MoveGoogle extends Mock implements GoogleCalendarService {}

void registerCalendarMoveSyncTests() {
  for (final destination in [null, 'b']) {
    for (final dirty in [false, true]) {
      testWidgets(
        'uncertain Google → $destination move survives two-device sync '
        '(offline edit: $dirty)',
        (tester) async {
          await pumpGoldenPage(tester, const SizedBox());
          final context = tester.element(find.byType(Scaffold).first);
          final calendar = context.read<CalendarCubit>();
          final google = _MoveGoogle();
          final server = FakeSyncClient();
          late _Device a;
          late _Device b;

          await verifyCalendarMove(
            tester,
            context,
            source: 'a',
            destination: destination,
            deleteFails: true,
            deleteCheckFails: true,
            googleService: google,
            beforeMove: (feeds, original) async {
              a = _Device(
                server,
                calendar: calendar,
                nodeCubit: context.read<NodeCubit>(),
                feedCubit: feeds,
              );
              b = _Device(server, google: google);
              await a.signIn();
              await b.signIn();
              await a.engine.syncNow();
              await b.engine.syncNow();
              expect(b.events.byId(original.id), original);
              // Force the conservative session merge as well as timer merging.
              if (dirty) {
                b.events.updateEvent(
                  original.copyWith(subject: 'Offline edit'),
                );
              }
            },
            afterMove: (feeds, original) async {
              final moved = calendar.state.singleWhere(
                (event) => event.id != original.id,
              );
              List<(ReportBlockKind, String?, DateTime, DateTime)> intervals(
                List<PlannerEvent> events,
              ) =>
                  buildReportBlocks(
                        visibleEvents: events,
                        nodes: const [],
                        reportsByDay: const {},
                        now: original.end,
                      )
                      .map(
                        (block) => (
                          block.kind,
                          block.sessionId,
                          block.start,
                          block.end,
                        ),
                      )
                      .toList();

              void expectOwner(CalendarCubit events) {
                final owner = events.byId(moved.id)!;
                expect(owner.sessions, original.sessions);
                expect(owner.actualStart, original.actualStart);
                expect(owner.actualEnd, original.actualEnd);
                expect(owner.timerStartedAt, original.timerStartedAt);
                expect(
                  events.state.where((e) => e.isTracking).map((e) => e.id),
                  [moved.id],
                );
                expect(
                  intervals(events.eventsOnDay(original.start)),
                  intervals([original]),
                );
                final retired = events.byId(original.id)!;
                expect(retired.recordingsTransferredTo, moved.id);
                expect(retired.recordedSessions, isEmpty);
                expect(retired.timerStartedAt, isNull);
              }

              await a.engine.syncNow();
              // B still has the original live timer when it pulls the transfer.
              expect(b.events.byId(original.id)!.isTracking, isTrue);
              for (var round = 0; round < 3; round++) {
                await b.engine.syncNow();
                await a.engine.syncNow();
                for (final device in [a, b]) {
                  await device.feeds.syncFeed('a');
                  if (destination != null) {
                    await device.feeds.syncFeed(destination);
                  }
                  expectOwner(device.events);
                  expect(device.engine.status.value, EngineStatus.idle);
                }
              }
              final stored = server.store['events']!;
              expect(
                stored[original.id]!.data['recordingsTransferredTo'],
                moved.id,
              );
              expect(stored[original.id]!.data['timerStartedAt'], isNull);
              expect(
                stored[moved.id]!.data['sessions'],
                original.toJson()['sessions'],
              );
              expect(
                stored[moved.id]!.data['timerStartedAt'],
                original.toJson()['timerStartedAt'],
              );
            },
          );
        },
      );
    }
  }
}
