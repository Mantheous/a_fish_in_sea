import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:a_fish_in_sea/planner/model/task_rule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node _node(
  String id, {
  DateTime? due,
  NodeStatus status = NodeStatus.open,
}) {
  final noon = due == null ? null : DateTime(due.year, due.month, due.day, 12);
  return Node(
    id: id,
    title: id,
    createdAt: DateTime(2026, 10, 1),
    status: status,
    schedule: due == null ? null : ScheduleFacet(due: noon),
  );
}

TaskRule _tint(String id, TaskFilterDate date,
        {bool enabled = true, int? color}) =>
    TaskRule(
      id: id,
      enabled: enabled,
      selector: TaskFilter(id: id, name: id, date: date),
      effect: TaskRuleEffect.highlight,
      colorValue: color,
    );

TaskRule _hide(String id, TaskFilterDate date, {bool enabled = true}) =>
    TaskRule(
      id: id,
      enabled: enabled,
      selector:
          TaskFilter(id: id, name: id, date: date, showCompleted: true),
      effect: TaskRuleEffect.hide,
    );

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  // Monday 2026-10-12, noon. Week runs through Sunday 2026-10-18.
  final monday = DateTime(2026, 10, 12, 12);
  final weekDue = DateTime(2026, 10, 14, 9);
  final farDue = DateTime(2026, 12, 1, 9);

  group('TaskRule matching', () {
    test('highlight is open-only, hide defers to the selector', () {
      final tint = _tint('t', TaskFilterDate.thisWeek);
      expect(tint.matches(_node('open', due: weekDue), monday), isTrue);
      expect(
          tint.matches(
              _node('done', due: weekDue, status: NodeStatus.done), monday),
          isFalse);
      final hide = _hide('h', TaskFilterDate.thisWeek);
      expect(
          hide.matches(
              _node('done', due: weekDue, status: NodeStatus.done), monday),
          isTrue);
      expect(tint.matches(_node('far', due: farDue), monday), isFalse);
    });

    test('disabled rules never match', () {
      final tint = _tint('t', TaskFilterDate.thisWeek, enabled: false);
      expect(tint.matches(_node('open', due: weekDue), monday), isFalse);
    });
  });

  group('evaluateTaskRules priority', () {
    test('empty rules leave the row visible and untinted', () {
      const outcome = TaskRuleOutcome(hidden: false, tint: null);
      final actual =
          evaluateTaskRules(const [], _node('a', due: weekDue), monday);
      expect(actual.hidden, outcome.hidden);
      expect(actual.tint, outcome.tint);
    });

    test('first highlight wins the tint', () {
      final rules = [
        _tint('red', TaskFilterDate.thisWeek, color: 0xFFFF0000),
        _tint('blue', TaskFilterDate.thisWeek, color: 0xFF0000FF),
      ];
      final outcome =
          evaluateTaskRules(rules, _node('a', due: weekDue), monday);
      expect(outcome.hidden, isFalse);
      expect(outcome.tint?.id, 'red');
      // Reversed order flips the winner.
      final flipped =
          evaluateTaskRules(rules.reversed.toList(), _node('a', due: weekDue), monday);
      expect(flipped.tint?.id, 'blue');
    });

    test('hiding always wins over tinting', () {
      final rules = [
        _tint('tint', TaskFilterDate.thisWeek, color: 0xFFFF0000),
        _hide('hide', TaskFilterDate.thisWeek),
      ];
      final outcome =
          evaluateTaskRules(rules, _node('a', due: weekDue), monday);
      expect(outcome.hidden, isTrue);
      expect(outcome.tint, isNull);
      expect(taskHiddenByRules(rules, _node('a', due: weekDue), monday),
          isTrue);
      expect(taskHiddenByRules(rules, _node('far', due: farDue), monday),
          isFalse);
    });

    test('non-matching hide rules change nothing', () {
      final rules = [
        _tint('tint', TaskFilterDate.thisWeek),
        _hide('hide', TaskFilterDate.today),
      ];
      final outcome =
          evaluateTaskRules(rules, _node('a', due: weekDue), monday);
      expect(outcome.hidden, isFalse);
      expect(outcome.tint?.id, 'tint');
    });
  });

  group('TaskRule JSON tolerance', () {
    test('round-trips', () {
      final rule = TaskRule(
        id: 'custom:1',
        enabled: true,
        selector: const TaskFilter(
          id: 'custom:1',
          name: 'Physics week',
          date: TaskFilterDate.thisWeek,
          kind: TaskFilterKind.homework,
          classKeys: ['Physics'],
        ),
        effect: TaskRuleEffect.highlight,
        colorValue: 0xFFFF9800,
      );
      expect(TaskRule.tryParse(rule.toJson()), rule);
      const hide = TaskRule(
        id: 'h',
        selector: TaskFilter(id: 'h', name: 'H', date: TaskFilterDate.today),
        effect: TaskRuleEffect.hide,
      );
      expect(TaskRule.tryParse(hide.toJson()), hide);
    });

    test('garbage parses to null, unsafe values fall back safe', () {
      expect(TaskRule.tryParse(null), isNull);
      expect(TaskRule.tryParse('nope'), isNull);
      expect(TaskRule.tryParse(const {'name': 'x'}), isNull);
      // Corrupt selector drops the rule (a permissive fallback could
      // hide everything).
      expect(
          TaskRule.tryParse(const {
            'id': 'x',
            'selector': {'name': 'no-id'},
          }),
          isNull);
      final unknownEffect = TaskRule.tryParse(const {
        'id': 'x',
        'effect': 'renamed-value',
        'selector': {'id': 'x', 'name': 'x'},
      });
      expect(unknownEffect?.effect, TaskRuleEffect.highlight);
      final wrongEnabled = TaskRule.tryParse(const {
        'id': 'x',
        'enabled': 'yes',
        'selector': {'id': 'x', 'name': 'x'},
      });
      // Wrong-typed flags switch the rule off rather than risk hiding.
      expect(wrongEnabled?.enabled, isFalse);
      expect(TaskRule.tryParse(const {
        'id': 'x',
        'colorValue': 'red',
        'selector': {'id': 'x', 'name': 'x'},
      })?.colorValue, isNull);
    });

    test('fromHighlight keeps window, color, and hide behavior', () {
      final tint = TaskRule.fromHighlight(const TaskHighlight(
        enabled: true,
        date: TaskHighlightDate.tomorrow,
        colorValue: 0xFFFF9800,
      ));
      expect(tint.enabled, isTrue);
      expect(tint.effect, TaskRuleEffect.highlight);
      expect(tint.colorValue, 0xFFFF9800);
      expect(tint.selector.date, TaskFilterDate.tomorrow);
      expect(
          tint.matches(_node('a', due: DateTime(2026, 10, 13, 9)), monday),
          isTrue);

      final hide = TaskRule.fromHighlight(const TaskHighlight(
        enabled: true,
        date: TaskHighlightDate.thisWeek,
        hideMatching: true,
      ));
      expect(hide.effect, TaskRuleEffect.hide);
      expect(hide.colorValue, isNull);
      expect(
          hide.matches(_node('a', due: weekDue), monday), isTrue);

      expect(describeTaskRule(tint), contains('highlighted'));
      expect(describeTaskRule(hide), contains('hidden'));
      expect(
        describeTaskRule(
          TaskRule(
            id: 'class',
            selector: const TaskFilter(
              id: 'class',
              name: 'Discrete only',
              classKeys: ['feed:1789249594268000'],
            ),
          ),
          className: (key) =>
              key == 'feed:1789249594268000' ? 'Discrete Structure' : key,
        ),
        contains('Discrete Structure'),
      );
    });
  });

  group('TasksViewOptionsCubit rules', () {
    test('add, update, enable, color, effect, delete', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final rule = _tint('r1', TaskFilterDate.today);
      cubit.addRule(rule);
      expect(cubit.state.rules.map((r) => r.id), contains('r1'));

      cubit.setRuleEnabled('r1', false);
      expect(
          cubit.state.rules.firstWhere((r) => r.id == 'r1').enabled, isFalse);
      cubit.setRuleColor('r1', 0xFF42A5F5);
      expect(
          cubit.state.rules.firstWhere((r) => r.id == 'r1').colorValue,
          0xFF42A5F5);
      cubit.setRuleEffect('r1', TaskRuleEffect.hide);
      final updated = cubit.state.rules.firstWhere((r) => r.id == 'r1');
      expect(updated.effect, TaskRuleEffect.hide);
      // Switching to hide drops the tint.
      expect(updated.colorValue, isNull);

      cubit.updateRule(rule.copyWith(enabled: true));
      expect(
          cubit.state.rules.firstWhere((r) => r.id == 'r1').enabled, isTrue);
      cubit.deleteRule('r1');
      expect(cubit.state.rules.any((r) => r.id == 'r1'), isFalse);
    });

    test('reorder changes which highlight wins', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      cubit.addRule(_tint('red', TaskFilterDate.thisWeek, color: 0xFFFF0000));
      cubit.addRule(_tint('blue', TaskFilterDate.thisWeek, color: 0xFF0000FF));
      final node = _node('a', due: weekDue);
      // Default disabled week rule + red + blue: red is the first enabled.
      expect(
          evaluateTaskRules(cubit.state.rules, node, monday).tint?.id, 'red');
      // Drag blue above red: red is at index 1, blue at 2 → move 2 → 1.
      cubit.moveRule(2, 1);
      expect(cubit.state.rules.map((r) => r.id).toList(),
          ['rule:week', 'blue', 'red']);
      expect(
          evaluateTaskRules(cubit.state.rules, node, monday).tint?.id,
          'blue');
      // Out-of-range moves are ignored.
      cubit.moveRule(-1, 0);
      cubit.moveRule(0, 99);
      expect(cubit.state.rules.map((r) => r.id).toList(),
          ['rule:week', 'blue', 'red']);
    });

    test('disableHidingRules keeps tints, Show-everywhere path', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      cubit.setRuleEnabled('rule:week', true);
      cubit.addRule(_hide('h', TaskFilterDate.thisWeek));
      expect(cubit.state.isFiltering, isTrue);
      cubit.disableHidingRules();
      expect(cubit.state.hasHidingRule, isFalse);
      expect(cubit.state.hasHighlightRule, isTrue);
      expect(cubit.state.isFiltering, isFalse);
    });

    test('rules cap at 20 and clear restores stock', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      for (var i = 0; i < 25; i++) {
        cubit.addRule(_tint('r$i', TaskFilterDate.all));
      }
      expect(cubit.state.rules.length, 20);
      expect(cubit.state.hasCustomRules, isTrue);
      cubit.clearAll();
      expect(cubit.state, const TasksViewOptionsState());
      expect(cubit.state.hasCustomRules, isFalse);
    });

    test('highlight payloads migrate onto rules', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final restored = cubit.fromJson(const {
        'filters': [
          {'id': 'all', 'name': 'All'},
        ],
        'activeFilterId': 'all',
        'highlight': {
          'enabled': true,
          'date': 'tomorrow',
          'colorValue': 0xFFFF9800,
          'hideMatching': false,
        },
      });
      expect(restored?.rules, hasLength(1));
      final rule = restored!.rules.single;
      expect(rule.enabled, isTrue);
      expect(rule.selector.date, TaskFilterDate.tomorrow);
      expect(rule.colorValue, 0xFFFF9800);
    });

    test('corrupt rules drop per-item', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      final restored = cubit.fromJson(const {
        'rules': [
          {
            'id': 'good',
            'enabled': true,
            'effect': 'highlight',
            'selector': {'id': 'good', 'name': 'Good'}
          },
          {'id': 42},
          'not-a-map',
          {
            'id': 'bad-selector',
            'selector': {'name': 'no-id'}
          },
          {
            'id': 'renamed-effect',
            'effect': 'renamed-value',
            'selector': {'id': 'renamed-effect', 'name': 'R'}
          },
        ],
      });
      expect(restored?.rules.map((r) => r.id), ['good', 'renamed-effect']);
      expect(
          restored?.rules
              .firstWhere((r) => r.id == 'renamed-effect')
              .effect,
          TaskRuleEffect.highlight);
    });
  });
}
