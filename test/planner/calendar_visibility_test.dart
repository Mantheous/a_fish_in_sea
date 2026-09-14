import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/model/calendar_source.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

PlannerEvent event({
  required String id,
  String? feedId,
  String? classLabel,
  DateTime? start,
}) {
  final s = start ?? DateTime(2026, 9, 10, 9);
  return PlannerEvent(
    id: id,
    subject: id,
    start: s,
    end: s.add(const Duration(hours: 1)),
    feedId: feedId,
    classLabel: classLabel,
  );
}

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('calendarLeafIdForEvent', () {
    test('personal events map to the personal leaf', () {
      expect(
        calendarLeafIdForEvent(event(id: 'e1'), null),
        personalCalendarId,
      );
    });

    test('google and LS events map to their feed', () {
      const google =
          Feed(id: 'gcal:a', name: 'G', url: '', kind: FeedKind.google);
      const ls = Feed(id: 'f-ls', name: 'LS', url: 'https://x');
      expect(
        calendarLeafIdForEvent(event(id: 'e', feedId: 'gcal:a'), google),
        'gcal:a',
      );
      expect(
        calendarLeafIdForEvent(event(id: 'e', feedId: 'f-ls'), ls),
        'f-ls',
      );
    });

    test('canvas events fan out per class label', () {
      const canvas = Feed(
        id: 'f-canvas',
        name: 'Canvas',
        url: 'https://x',
        kind: FeedKind.canvas,
      );
      expect(
        calendarLeafIdForEvent(
          event(id: 'e', feedId: 'f-canvas', classLabel: 'STAT 230-002'),
          canvas,
        ),
        'f-canvas::STAT 230-002',
      );
      expect(
        calendarLeafIdForEvent(event(id: 'e', feedId: 'f-canvas'), canvas),
        'f-canvas',
      );
    });

    test('unknown feed falls back to the raw feed id', () {
      expect(
        calendarLeafIdForEvent(
            event(id: 'e', feedId: 'missing'), null),
        'missing',
      );
    });
  });

  group('buildCalendarTree', () {
    test('all five groups always exist (finance empty but present)', () {
      final tree = buildCalendarTree(feeds: const [], events: const []);
      expect(tree.map((g) => g.id), calendarGroupOrder);
      final finance = tree.firstWhere((g) => g.id == calendarGroupFinance);
      expect(finance.leaves, isEmpty);
      expect(finance.title, 'Finance');
    });

    test('google feeds become google leaves; classes fan out under homework',
        () {
      const google = Feed(
        id: 'gcal:work',
        name: 'Work',
        url: '',
        kind: FeedKind.google,
      );
      const ls = Feed(
        id: 'f-ls',
        name: 'REL 225',
        url: 'https://x',
        kind: FeedKind.learningSuite,
      );
      const canvas = Feed(
        id: 'f-canvas',
        name: 'Canvas',
        url: 'https://x',
        kind: FeedKind.canvas,
      );
      final events = [
        event(id: 'g1', feedId: 'gcal:work'),
        event(id: 'h1', feedId: 'f-ls'),
        event(
            id: 'c1', feedId: 'f-canvas', classLabel: 'STAT 230-002'),
        event(id: 'c2', feedId: 'f-canvas', classLabel: 'STAT 230-002'),
        event(id: 'p1'),
      ];
      final tree = buildCalendarTree(
        feeds: const [google, ls, canvas],
        events: events,
      );
      final byId = {for (final g in tree) g.id: g};
      expect(byId[calendarGroupGoogle]!.leaves.map((l) => l.id), ['gcal:work']);
      expect(
        byId[calendarGroupHomework]!.leaves.map((l) => l.id),
        containsAll(['f-ls', 'f-canvas::STAT 230-002']),
      );
      // No unlabeled canvas events → no feed-level fallback leaf.
      expect(
        byId[calendarGroupHomework]!.leaves.map((l) => l.id),
        isNot(contains('f-canvas')),
      );
      final stat = byId[calendarGroupHomework]!
          .leaves
          .firstWhere((l) => l.id == 'f-canvas::STAT 230-002');
      expect(stat.eventCount, 2);
      expect(
        byId[calendarGroupPersonal]!.leaves.single.eventCount,
        1,
      );
    });

    test('unlabeled canvas events keep a feed-level fallback leaf', () {
      const canvas = Feed(
        id: 'f-canvas',
        name: 'Canvas',
        url: 'https://x',
        kind: FeedKind.canvas,
      );
      final tree = buildCalendarTree(
        feeds: const [canvas],
        events: [
          event(id: 'c1', feedId: 'f-canvas', classLabel: 'STAT 230'),
          event(id: 'c2', feedId: 'f-canvas'),
        ],
      );
      final homework =
          tree.firstWhere((g) => g.id == calendarGroupHomework);
      expect(
        homework.leaves.map((l) => l.id),
        containsAll(['f-canvas::STAT 230', 'f-canvas']),
      );
    });
  });

  group('CalendarVisibilityCubit', () {
    test('new calendars are visible by default', () {
      final cubit = CalendarVisibilityCubit();
      const google = Feed(
        id: 'gcal:work',
        name: 'Work',
        url: '',
        kind: FeedKind.google,
      );
      final feeds = {'gcal:work': google};
      expect(
        cubit.isEventVisible(event(id: 'e', feedId: 'gcal:work'), feeds),
        isTrue,
      );
      expect(cubit.isEventVisible(event(id: 'p'), const {}), isTrue);
    });

    test('toggling a leaf hides just that calendar', () {
      final cubit = CalendarVisibilityCubit();
      const google = Feed(
        id: 'gcal:work',
        name: 'Work',
        url: '',
        kind: FeedKind.google,
      );
      final feeds = {'gcal:work': google};
      final work = event(id: 'w', feedId: 'gcal:work');
      final personal = event(id: 'p');

      cubit.toggleLeaf('gcal:work');
      expect(cubit.isEventVisible(work, feeds), isFalse);
      expect(cubit.isEventVisible(personal, feeds), isTrue);

      cubit.toggleLeaf('gcal:work');
      expect(cubit.isEventVisible(work, feeds), isTrue);
    });

    test('toggling a canvas class leaf hides only that class', () {
      final cubit = CalendarVisibilityCubit();
      const canvas = Feed(
        id: 'f-canvas',
        name: 'Canvas',
        url: 'https://x',
        kind: FeedKind.canvas,
      );
      final feeds = {'f-canvas': canvas};
      final stat =
          event(id: 'a', feedId: 'f-canvas', classLabel: 'STAT 230');
      final rel = event(id: 'b', feedId: 'f-canvas', classLabel: 'REL 225');

      cubit.setLeafVisible('f-canvas::STAT 230', false);
      expect(cubit.isEventVisible(stat, feeds), isFalse);
      expect(cubit.isEventVisible(rel, feeds), isTrue);
    });

    test('toggling a group hides everything under it, re-toggle shows all',
        () {
      final cubit = CalendarVisibilityCubit();
      cubit.toggleGroup(calendarGroupGoogle, ['gcal:a', 'gcal:b']);
      expect(cubit.state.hiddenIds, contains(calendarGroupGoogle));

      const a = Feed(
        id: 'gcal:a',
        name: 'A',
        url: '',
        kind: FeedKind.google,
      );
      expect(
        cubit.isEventVisible(event(id: 'e', feedId: 'gcal:a'), {'gcal:a': a}),
        isFalse,
      );

      cubit.toggleGroup(calendarGroupGoogle, ['gcal:a', 'gcal:b']);
      expect(cubit.state.hiddenIds, isEmpty);
      expect(
        cubit.isEventVisible(event(id: 'e', feedId: 'gcal:a'), {'gcal:a': a}),
        isTrue,
      );
    });

    test('group state reports all/none/some for tri-state checkboxes', () {
      final cubit = CalendarVisibilityCubit();
      expect(
        cubit.groupState('group:google', ['gcal:a', 'gcal:b']),
        CalendarGroupVisibility.all,
      );
      cubit.setLeafVisible('gcal:a', false);
      expect(
        cubit.groupState('group:google', ['gcal:a', 'gcal:b']),
        CalendarGroupVisibility.some,
      );
      cubit.setLeafVisible('gcal:b', false);
      expect(
        cubit.groupState('group:google', ['gcal:a', 'gcal:b']),
        CalendarGroupVisibility.none,
      );
    });

    test('filterVisible keeps feed-visible events in visible calendars', () {
      final cubit = CalendarVisibilityCubit();
      const google = Feed(
        id: 'gcal:work',
        name: 'Work',
        url: '',
        kind: FeedKind.google,
      );
      final feeds = {'gcal:work': google};
      final events = [
        event(id: 'w', feedId: 'gcal:work'),
        event(id: 'p'),
      ];
      expect(cubit.filterVisible(events, feeds).length, 2);
      cubit.setLeafVisible('gcal:work', false);
      expect(cubit.filterVisible(events, feeds).map((e) => e.id), ['p']);
    });

    test('round-trips through JSON', () {
      final cubit = CalendarVisibilityCubit();
      cubit.setLeafVisible('gcal:a', false);
      cubit.setLeafVisible('f-canvas::STAT 230', false);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(
        restored?.hiddenIds,
        containsAll(['gcal:a', 'f-canvas::STAT 230']),
      );
    });

    test('restore tolerates garbage instead of wiping prefs', () {
      final cubit = CalendarVisibilityCubit();
      expect(cubit.fromJson({})?.hiddenIds, isEmpty);
      expect(cubit.fromJson(const {'hiddenIds': null})?.hiddenIds, isEmpty);
      expect(
        cubit.fromJson(const {'hiddenIds': 'not-a-list'})?.hiddenIds,
        isEmpty,
      );
      final mixed = cubit.fromJson(const {
        'hiddenIds': ['gcal:a', 42, '', null, 'group:google'],
      });
      expect(mixed?.hiddenIds, {'gcal:a', 'group:google'});
    });
  });
}
