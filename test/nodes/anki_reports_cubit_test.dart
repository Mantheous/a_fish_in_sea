import 'dart:async';

import 'package:a_fish_in_sea/anki/anki_reports.dart';
import 'package:a_fish_in_sea/anki/anki_reports_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

AnkiReportData _report(String deck, int cards, {String day = '2026-11-03'}) =>
    AnkiReportData(
      days: [
        AnkiReviewDay(
          day: DateTime.parse(day),
          deck: deck,
          cards: cards,
          reviews: cards,
        ),
      ],
    );

Node _goal(
  String id, {
  String? deck,
  TimeScale? period,
  int? actual,
  DateTime? createdAt,
}) => Node(
  id: id,
  title: id,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
  anki: AnkiFacet(
    deckName: deck,
    targetReviews: 10,
    period: period,
    reviewsActual: actual,
  ),
);

void main() {
  final now = DateTime(2026, 11, 4, 12);

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  test('refresh writes the current-period count, not yesterday\'s', () async {
    final nodes = NodeCubit();
    nodes.addNode(
      _goal('daily', deck: 'Japanese', period: TimeScale.daily, actual: 99),
    );
    var calls = 0;
    final cubit = AnkiReportsCubit(
      fetch: () async {
        calls++;
        return _report('Japanese', 3);
      },
      nodes: nodes,
      isSignedIn: () => true,
      firstDayOfWeek: () => 1,
      now: () => now,
      refreshEvery: const Duration(days: 1),
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    expect(calls, 1);
    final goal = nodes.byId('daily')!;
    // Yesterday's 3 reviews are real data for this deck, so the daily
    // cache resets to 0 instead of keeping a stale 99.
    expect(goal.anki!.reviewsActual, 0);
    expect(goal.anki!.lastSyncedAt, now);
  });

  test('a deck the add-on has not seen keeps its manual count', () async {
    final nodes = NodeCubit();
    nodes.addNode(
      _goal('manual', deck: 'Japanese', period: TimeScale.daily, actual: 17),
    );
    final cubit = AnkiReportsCubit(
      fetch: () async => _report('Math', 4),
      nodes: nodes,
      isSignedIn: () => true,
      firstDayOfWeek: () => 1,
      now: () => now,
      refreshEvery: const Duration(days: 1),
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    expect(nodes.byId('manual')!.anki!.reviewsActual, 17);
  });

  test('weekly goals sum the whole week', () async {
    final nodes = NodeCubit();
    nodes.addNode(
      _goal('weekly', deck: 'Japanese', period: TimeScale.weekly, actual: 0),
    );
    final cubit = AnkiReportsCubit(
      fetch: () async => AnkiReportData(
        days: [
          AnkiReviewDay(
            day: DateTime(2026, 11, 2),
            deck: 'Japanese',
            cards: 4,
            reviews: 4,
          ),
          AnkiReviewDay(
            day: DateTime(2026, 11, 3),
            deck: 'Japanese::Vocab',
            cards: 5,
            reviews: 7,
          ),
          AnkiReviewDay(
            day: DateTime(2026, 10, 30),
            deck: 'Japanese',
            cards: 100,
            reviews: 100,
          ),
        ],
      ),
      nodes: nodes,
      isSignedIn: () => true,
      firstDayOfWeek: () => 1,
      now: () => now,
      refreshEvery: const Duration(days: 1),
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    expect(nodes.byId('weekly')!.anki!.reviewsActual, 9);
    expect(nodes.byId('weekly')!.anki!.reviewsActual, isNot(109));
  });

  test('signed-out cubits neither fetch nor write', () async {
    var calls = 0;
    final cubit = AnkiReportsCubit(
      fetch: () async {
        calls++;
        return _report('Japanese', 3);
      },
      nodes: NodeCubit(),
      isSignedIn: () => false,
      firstDayOfWeek: () => 1,
      now: () => now,
      refreshEvery: const Duration(days: 1),
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    expect(calls, 0);
    expect(cubit.state.data.isEmpty, isTrue);
  });

  test('an auth transition starts a refresh', () async {
    var calls = 0;
    var signedIn = false;
    final auth = StreamController<bool>.broadcast();
    addTearDown(auth.close);
    final cubit = AnkiReportsCubit(
      fetch: () async {
        calls++;
        return _report('Japanese', 3);
      },
      nodes: NodeCubit(),
      isSignedIn: () => signedIn,
      firstDayOfWeek: () => 1,
      authChanges: auth.stream,
      now: () => now,
      refreshEvery: const Duration(days: 1),
    );
    addTearDown(cubit.close);
    signedIn = true;
    auth.add(true);
    await pumpEventQueue();
    expect(calls, 1);
    expect(cubit.state.status, AnkiReportsStatus.ready);
  });

  test('countFor previews an unsaved form and hides unknown decks', () async {
    final cubit = AnkiReportsCubit(
      fetch: () async => AnkiReportData(
        days: [
          AnkiReviewDay(
            day: DateTime(2026, 11, 3),
            deck: 'Japanese',
            cards: 6,
            reviews: 8,
          ),
        ],
      ),
      nodes: NodeCubit(),
      isSignedIn: () => true,
      firstDayOfWeek: () => 1,
      now: () => now,
      refreshEvery: const Duration(days: 1),
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    final count = cubit.countFor(
      deckName: 'Japanese',
      period: TimeScale.monthly,
    );
    expect(count, isNotNull);
    expect(count!.cards, 6);
    expect(count.reviews, 8);
    expect(
      cubit.countFor(deckName: 'History', period: TimeScale.monthly),
      isNull,
    );
  });
}
