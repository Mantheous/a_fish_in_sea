import 'dart:convert';
import 'dart:io';

import 'package:a_fish_in_sea/common/persistence/legacy_minified_keys.dart';
import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:a_fish_in_sea/planner/model/task_rule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

/// Fake JWT whose payload carries [exp]; signature is irrelevant here.
String _token(int exp) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
  final payload = base64Url.encode(utf8.encode('{"exp":$exp}'));
  return '$header.$payload.signature';
}

Map<String, dynamic> _taskViewPayload({
  required String filterId,
  required String ruleId,
  String activeFilterId = 'all',
}) =>
    {
      'version': 2,
      'filters': [
        TaskFilter(
          id: filterId,
          name: 'Saved $filterId',
          date: TaskFilterDate.thisWeek,
        ).toJson(),
      ],
      'activeFilterId': activeFilterId,
      'rules': [
        TaskRule(
          id: ruleId,
          selector: TaskFilter(
            id: ruleId,
            name: 'Saved $ruleId',
            date: TaskFilterDate.thisWeek,
          ),
        ).toJson(),
      ],
    };

void main() {
  late Directory dir;
  late Box<dynamic> box;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('legacy_hydrated_keys');
    Hive.init(dir.path);
    box = await Hive.openBox<dynamic>('hydrated_box');
    HydratedBloc.storage = HydratedStorage(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('hydrated_box');
    dir.deleteSync(recursive: true);
  });

  group('stable storage prefixes', () {
    test('constants are unique and cover every hydrated cubit', () {
      expect(StableStorageKeys.all, hasLength(17));
      expect(StableStorageKeys.all.length, StableStorageKeys.all.toSet().length);
    });

    test('every hydrated cubit overrides storagePrefix', () {
      final pattern =
          RegExp(r'class \w+ extends (?:Revertable)?Hydrated(?:Cubit|Bloc)<');
      final missing = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        if (!pattern.hasMatch(source)) continue;
        if (!source.contains('String get storagePrefix')) {
          missing.add(entity.path);
        }
      }
      expect(missing, isEmpty,
          reason: 'Pin these cubits to StableStorageKeys: $missing');
    });

    test('web-minified key shapes do not leak into the stable set', () {
      for (final key in StableStorageKeys.all) {
        expect(key.startsWith('minified:'), isFalse);
      }
    });
  });

  group('legacy minified-key recovery', () {
    test('copies views/rules onto the stable key and keeps the old one', () async {
      final payload = _taskViewPayload(
        filterId: 'custom:1700000000000000',
        ruleId: 'rule:1700000000000001',
        activeFilterId: 'custom:1700000000000000',
      );
      await box.put('minified:BR', payload);

      final recovered = await migrateLegacyHydratedKeys(box);

      expect(recovered, [StableStorageKeys.tasksViewOptions]);
      expect(box.get(StableStorageKeys.tasksViewOptions), equals(payload));
      expect(box.containsKey('minified:BR'), isTrue,
          reason: 'migration must never delete the source payload');
    });

    test('a real TasksViewOptionsCubit hydrates the recovered state', () async {
      await box.put(
        'minified:BR',
        _taskViewPayload(
          filterId: 'custom:1700000000000000',
          ruleId: 'rule:1700000000000001',
          activeFilterId: 'custom:1700000000000000',
        ),
      );
      await migrateLegacyHydratedKeys(box);

      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);

      expect(cubit.state.activeFilterId, 'custom:1700000000000000');
      expect(cubit.state.filters.map((f) => f.id),
          contains('custom:1700000000000000'));
      expect(cubit.state.rules.map((r) => r.id),
          contains('rule:1700000000000001'));
    });

    test('newest payload wins for stored views/rules', () async {
      await box.put(
        'minified:OLD',
        _taskViewPayload(
          filterId: 'custom:100',
          ruleId: 'rule:100',
        ),
      );
      final newest = _taskViewPayload(
        filterId: 'custom:200',
        ruleId: 'rule:200',
        activeFilterId: 'custom:200',
      );
      await box.put('minified:NEW', newest);

      await migrateLegacyHydratedKeys(box);

      expect(box.get(StableStorageKeys.tasksViewOptions), equals(newest));
    });

    test('task rules and assignment rules stay separate', () async {
      final taskRule = TaskRule(
        id: 'rule:1700000000000001',
        selector: TaskFilter(id: 'rule:1700000000000001', name: 'Tint'),
      ).toJson();
      await box.put('minified:TVO', {
        'version': 2,
        'filters': <dynamic>[],
        'activeFilterId': 'all',
        'rules': [taskRule],
      });
      final assignmentRule = AssignmentRule(
        id: 'ar:1',
        feedId: 'feed:1',
        templateKey: 'Week 1 quiz',
        displayName: 'Week 1 quiz',
        dueOffsetDays: -2,
        createdAt: DateTime(2026, 10, 1),
      ).toJson();
      await box.put('minified:AR', {
        'rules': [assignmentRule],
      });

      await migrateLegacyHydratedKeys(box);

      expect(box.get(StableStorageKeys.tasksViewOptions), isA<Map>());
      expect(box.get(StableStorageKeys.assignmentRules), isA<Map>());
      final recoveredTaskRules = box.get(StableStorageKeys.tasksViewOptions)!
          as Map<dynamic, dynamic>;
      expect(recoveredTaskRules['rules'], hasLength(1));
      final recoveredAssignmentRules =
          box.get(StableStorageKeys.assignmentRules) as Map<dynamic, dynamic>;
      expect(recoveredAssignmentRules['rules'], hasLength(1));
    });

    test('never overwrites a stable key that already has state', () async {
      final existing = _taskViewPayload(
        filterId: 'custom:900',
        ruleId: 'rule:900',
      );
      await box.put(StableStorageKeys.tasksViewOptions, existing);
      await box.put(
        'minified:BR',
        _taskViewPayload(filterId: 'custom:100', ruleId: 'rule:100'),
      );

      final recovered = await migrateLegacyHydratedKeys(box);

      expect(recovered, isEmpty);
      expect(
        box.get(StableStorageKeys.tasksViewOptions),
        equals(existing),
      );
    });

    test('restores the newest signed-in session, not signed-out noise',
        () async {
      await box.put('minified:OLDAUTH', {
        'status': 'signedIn',
        'email': 'old@example.com',
        'accessToken': _token(100),
        'refreshToken': 'old-refresh',
      });
      await box.put('minified:NEWAUTH', {
        'status': 'signedIn',
        'email': 'new@example.com',
        'accessToken': _token(200),
        'refreshToken': 'new-refresh',
      });
      await box.put('minified:SIGNEDOUT', {
        'status': 'signedOut',
        'email': '',
        'accessToken': null,
        'refreshToken': null,
      });

      await migrateLegacyHydratedKeys(box);

      final auth = box.get(StableStorageKeys.auth) as Map<dynamic, dynamic>;
      expect(auth['email'], 'new@example.com');
      expect(auth['refreshToken'], 'new-refresh');
    });

    test('leaves unknown shapes alone', () async {
      await box.put('minified:JUNK', {'something': 'else'});
      await box.put('minified:NOTAMAP', 'text');

      final recovered = await migrateLegacyHydratedKeys(box);

      expect(recovered, isEmpty);
      expect(box.get('minified:JUNK'), {'something': 'else'});
    });

    test('leaves synced collections for the sync engine to re-pull', () async {
      // Restoring one collection without its sync bookkeeping could look
      // like a mass deletion or resurrect items deleted since that payload.
      await box.put('minified:NODES', {
        'nodes': <dynamic>[],
      });
      await box.put('minified:TRACK', {
        'isRecording': true,
        'points': <dynamic>[],
      });

      final recovered = await migrateLegacyHydratedKeys(box);

      expect(recovered, isEmpty);
      expect(box.containsKey(StableStorageKeys.node), isFalse);
      expect(box.containsKey(StableStorageKeys.tracking), isFalse);
    });
  });
}
