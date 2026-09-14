import 'dart:io';

import 'package:a_fish_in_sea/common/persistence/migration.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> findExpiredMarkers(Directory root, DateTime now) {
  final pattern =
      RegExp(r"""Migration\.removeAfter\('(\d{4}-\d{2}-\d{2})'\)""");
  final expired = <String>[];
  if (!root.existsSync()) return expired;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    String content;
    try {
      content = entity.readAsStringSync();
    } catch (_) {
      continue;
    }
    for (final match in pattern.allMatches(content)) {
      DateTime deadline;
      try {
        deadline = DateTime.parse(match.group(1)!);
      } catch (_) {
        continue;
      }
      if (!now.isBefore(deadline)) {
        expired.add('${entity.path}:${match.group(1)}');
      }
    }
  }
  return expired;
}

void main() {
  group('migration expiry', () {
    test('removeAfter gates on the deadline', () {
      expect(
        Migration.removeAfter('2000-01-01', DateTime(2026, 9, 6)),
        isFalse,
      );
      expect(
        Migration.removeAfter('2999-01-01', DateTime(2026, 9, 6)),
        isTrue,
      );
    });

    test('scanner flags expired markers in fixtures', () {
      final dir = Directory.systemTemp.createTempSync('migration_scan');
      try {
        File('${dir.path}/a.dart')
            .writeAsStringSync("x = Migration.removeAfter('2000-01-01');");
        File('${dir.path}/b.dart')
            .writeAsStringSync("x = Migration.removeAfter('2999-01-01');");
        final expired = findExpiredMarkers(dir, DateTime(2026, 9, 6));
        expect(expired.length, 1);
        expect(expired.single, contains('a.dart'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('no expired migration markers in lib', () {
      final expired = findExpiredMarkers(Directory('lib'), DateTime.now());
      expect(expired, isEmpty,
          reason: 'Delete expired migration code: $expired');
    });
  });
}
